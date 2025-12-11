// ================================================================================ //
// The NEORV32 RISC-V Processor - https://github.com/stnolting/neorv32              //
// Copyright (c) NEORV32 contributors.                                              //
// Copyright (c) 2020 - 2025 Stephan Nolting. All rights reserved.                  //
// Licensed under the BSD-3-Clause license, see LICENSE for details.                //
// SPDX-License-Identifier: BSD-3-Clause                                            //
// ================================================================================ //


/**
 * @file gng/main.c
 * @brief Growing Neural Gas demo using NEORV32 UART
 *
 * Protocol (same as Arduino version):
 *  - Host sends lines terminated by '\n':
 *      "DATA:x,y;"  -> append training sample (floats)
 *      "DONE;"      -> dataset complete, reply "OK_DONE\n"
 *      "RUN;"       -> start training, reply "OK_RUN\n"
 *  - After RUN and DONE, firmware runs one GNG step per sample and
 *    sends current graph as one line:
 *      "GNG:" "N:index,x.xxx,y.yyy;"... "E:a,b;"... "\n"
 */

#include <neorv32.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>

/**********************************************************************//**
 * @name User configuration
 **************************************************************************/
/**@{*/
/** UART BAUD rate */
#define BAUD_RATE 1000000

/**@}*/

// --------------------------------------------------------------------------
// GNG configuration (match Arduino sketch)
// --------------------------------------------------------------------------
#define MAXPTS     100
#define MAX_NODES   20
#define MAX_EDGES   40

// serial line buffer
#define LINE_BUF_LEN 64

// --------------------------------------------------------------------------
// Data buffers & state
// --------------------------------------------------------------------------
static float dataX[MAXPTS];
static float dataY[MAXPTS];
static int   dataCount = 0;

static bool dataDone = false;
static bool running  = false;

// GNG parameters (disamakan dengan Arduino "two_moon" sketch)
static const float epsilon_b = 0.08f;   // winner learning rate
static const float epsilon_n = 0.02f;   // neighbor learning rate
static const float alpha     = 0.5f;    // error reduction factor
static const float beta      = 0.995f;  // global error decay
static const int   lambda_it = 20;      // insert node every 20 steps

// --------------------------------------------------------------------------
// GNG structures
// --------------------------------------------------------------------------
typedef struct {
  float x;
  float y;
  float error;
  bool  active;
} Node;

typedef struct {
  int  a;
  int  b;
  int  age;
  bool active;
} Edge;

static Node nodes[MAX_NODES];
static Edge edges[MAX_EDGES];

static int nodeCount = 0;
static int stepCount = 0;
static int dataIndex = 0; // current index into dataset

// serial parsing buffer
static char line_buf[LINE_BUF_LEN];
static int  line_pos = 0;

// --------------------------------------------------------------------------
// Utility: squared distance
// --------------------------------------------------------------------------
static float dist2(float x1, float y1, float x2, float y2) {
  float dx = x1 - x2;
  float dy = y1 - y2;
  return dx*dx + dy*dy;
}

// find index of a free node slot
static int findFreeNode(void) {
  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) {
      return i;
    }
  }
  return -1;
}

// connect two nodes, or reset age if edge already exists
static void connectNodes(int a, int b) {
  for (int i = 0; i < MAX_EDGES; i++) {
    if (edges[i].active &&
        ((edges[i].a == a && edges[i].b == b) ||
         (edges[i].a == b && edges[i].b == a))) {
      edges[i].age = 0;
      return;
    }
  }

  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) {
      edges[i].a    = a;
      edges[i].b    = b;
      edges[i].age  = 0;
      edges[i].active = true;
      return;
    }
  }
}

// remove edge between two nodes (if it exists)
static void removeEdgePair(int a, int b) {
  for (int i = 0; i < MAX_EDGES; i++) {
    if (edges[i].active &&
        ((edges[i].a == a && edges[i].b == b) ||
         (edges[i].a == b && edges[i].b == a))) {
      edges[i].active = false;
    }
  }
}

// remove nodes that have lost all incident edges (Fritzke-style cleanup)
static void pruneIsolatedNodes(void) {
  nodeCount = 0;

  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) {
      continue;
    }

    bool has_edge = false;
    for (int e = 0; e < MAX_EDGES; e++) {
      if (edges[e].active &&
          (edges[e].a == i || edges[e].b == i)) {
        has_edge = true;
        break;
      }
    }

    if (!has_edge) {
      nodes[i].active = false;
    }
    else {
      nodeCount++;
    }
  }
}

// age all edges incident to winner and delete very old ones (a_max = 50)
static void ageEdgesOfWinner(int winner) {
  for (int i = 0; i < MAX_EDGES; i++) {
    if (edges[i].active &&
        (edges[i].a == winner || edges[i].b == winner)) {
      edges[i].age++;
      if (edges[i].age > 50) {
        edges[i].active = false;
      }
    }
  }

  // remove units without any incident edge as in Fritzke's algorithm
  pruneIsolatedNodes();
}

// --------------------------------------------------------------------------
// UART helpers (no printf with floats to keep code size small)
// --------------------------------------------------------------------------
static void uart_put_int(int32_t v) {
  char buf[16];
  int  pos = 0;

  if (v == 0) {
    neorv32_uart0_putc('0');
    return;
  }

  if (v < 0) {
    neorv32_uart0_putc('-');
    v = -v;
  }

  while ((v > 0) && (pos < (int)sizeof(buf))) {
    buf[pos++] = (char)('0' + (v % 10));
    v /= 10;
  }

  for (int i = pos - 1; i >= 0; i--) {
    neorv32_uart0_putc(buf[i]);
  }
}

// print float with 3 decimal places, similar to Serial.print(x,3)
static void uart_put_float3(float v) {
  if (v < 0.0f) {
    neorv32_uart0_putc('-');
    v = -v;
  }

  int32_t iv = (int32_t)v;
  float frac = v - (float)iv;
  if (frac < 0.0f) {
    frac = 0.0f;
  }

  int32_t scaled = (int32_t)(frac * 1000.0f + 0.5f); // round to 3 decimals

  uart_put_int(iv);
  neorv32_uart0_putc('.');

  // ensure 3 digits with leading zeros
  int32_t d1 = scaled / 100;
  int32_t d2 = (scaled / 10) % 10;
  int32_t d3 = scaled % 10;
  neorv32_uart0_putc((char)('0' + d1));
  neorv32_uart0_putc((char)('0' + d2));
  neorv32_uart0_putc((char)('0' + d3));
}

// --------------------------------------------------------------------------
// Insert new node (GNG rule)
// --------------------------------------------------------------------------
static void insertNode(void) {
  // q = node with highest error
  int   q = -1;
  float maxErr = -1.0f;
  for (int i = 0; i < MAX_NODES; i++) {
    if (nodes[i].active && nodes[i].error > maxErr) {
      q = i;
      maxErr = nodes[i].error;
    }
  }
  if (q < 0) {
    return;
  }

  // f = neighbor of q with highest error
  int   f = -1;
  maxErr = -1.0f;
  for (int i = 0; i < MAX_EDGES; i++) {
    if (edges[i].active && edges[i].a == q) {
      int b = edges[i].b;
      if (nodes[b].error > maxErr) {
        maxErr = nodes[b].error;
        f = b;
      }
    }
    else if (edges[i].active && edges[i].b == q) {
      int b = edges[i].a;
      if (nodes[b].error > maxErr) {
        maxErr = nodes[b].error;
        f = b;
      }
    }
  }
  if (f < 0) {
    return;
  }

  int r = findFreeNode();
  if (r < 0) {
    return;
  }

  // new node at midpoint (Fritzke): error_r = error_q (before scaling)
  nodes[r].x      = 0.5f * (nodes[q].x + nodes[f].x);
  nodes[r].y      = 0.5f * (nodes[q].y + nodes[f].y);
  nodes[r].error  = nodes[q].error;
  nodes[r].active = true;
  nodeCount++;

  // decrease error of q and f
  nodes[q].error *= alpha;
  nodes[f].error *= alpha;

  // remove old edge between q and f and connect via new node r
  removeEdgePair(q, f);
  connectNodes(r, q);
  connectNodes(r, f);
}

// --------------------------------------------------------------------------
// Send current GNG state (nodes + edges) to host
// --------------------------------------------------------------------------
static void sendGNG(void) {
  neorv32_uart0_puts("GNG:");

  // nodes
  for (int i = 0; i < MAX_NODES; i++) {
    if (nodes[i].active) {
      neorv32_uart0_puts("N:");
      uart_put_int(i);
      neorv32_uart0_putc(',');
      uart_put_float3(nodes[i].x);
      neorv32_uart0_putc(',');
      uart_put_float3(nodes[i].y);
      neorv32_uart0_putc(';');
    }
  }

  // edges
  for (int i = 0; i < MAX_EDGES; i++) {
    if (edges[i].active) {
      neorv32_uart0_puts("E:");
      uart_put_int(edges[i].a);
      neorv32_uart0_putc(',');
      uart_put_int(edges[i].b);
      neorv32_uart0_putc(';');
    }
  }

  neorv32_uart0_putc('\n');
}

// --------------------------------------------------------------------------
// Process one complete command line from host
// --------------------------------------------------------------------------
static void process_line(char *s) {
  // trim trailing CR/LF
  size_t len = strlen(s);
  while (len > 0 && (s[len - 1] == '\r' || s[len - 1] == '\n')) {
    s[--len] = '\0';
  }

  if (len == 0) {
    return;
  }

  if (strcmp(s, "DONE;") == 0) {
    dataDone = true;
    neorv32_uart0_puts("OK_DONE\n");
  }
  else if (strcmp(s, "RUN;") == 0) {
    running = true;
    neorv32_uart0_puts("OK_RUN\n");
  }
  else if (strncmp(s, "DATA:", 5) == 0) {
    char *p  = s + 5;
    char *c1 = strchr(p, ',');
    char *c2 = strchr(p, ';');

    if ((c1 != NULL) && (c2 != NULL) && (c1 < c2)) {
      *c1 = '\0';
      *c2 = '\0';

      float x = strtof(p, NULL);
      float y = strtof(c1 + 1, NULL);

      if (dataCount < MAXPTS) {
        dataX[dataCount] = x;
        dataY[dataCount] = y;
        dataCount++;
      }
    }
  }
}

// --------------------------------------------------------------------------
// Poll UART and assemble lines
// --------------------------------------------------------------------------
static void readSerial(void) {
  while (neorv32_uart0_char_received()) {
    char c = (char)neorv32_uart0_getc();

    if (c == '\n') {
      line_buf[line_pos] = '\0';
      if (line_pos > 0) {
        process_line(line_buf);
      }
      line_pos = 0;
    }
    else if (c != '\r') {
      if (line_pos < (LINE_BUF_LEN - 1)) {
        line_buf[line_pos++] = c;
      }
      else {
        // overflow, reset line
        line_pos = 0;
      }
    }
  }
}

// --------------------------------------------------------------------------
// One GNG training step
// --------------------------------------------------------------------------
static void trainOneStep(float x, float y) {
  int   s1 = -1, s2 = -1;
  float d1 = 1e30f, d2 = 1e30f;

  // find nearest and 2nd nearest
  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) {
      continue;
    }

    float d = dist2(x, y, nodes[i].x, nodes[i].y);

    if (d < d1) {
      d2 = d1;
      s2 = s1;
      d1 = d;
      s1 = i;
    }
    else if (d < d2) {
      d2 = d;
      s2 = i;
    }
  }

  if (s1 < 0 || s2 < 0) {
    return; // need at least two active nodes
  }

  // move winner
  nodes[s1].x += epsilon_b * (x - nodes[s1].x);
  nodes[s1].y += epsilon_b * (y - nodes[s1].y);

  // move neighbors
  for (int i = 0; i < MAX_EDGES; i++) {
    if (edges[i].active &&
        (edges[i].a == s1 || edges[i].b == s1)) {
      int nb = (edges[i].a == s1) ? edges[i].b : edges[i].a;
      nodes[nb].x += epsilon_n * (x - nodes[nb].x);
      nodes[nb].y += epsilon_n * (y - nodes[nb].y);
    }
  }

  // increase error
  nodes[s1].error += d1;

  // connect s1-s2
  connectNodes(s1, s2);

  // age edges
  ageEdgesOfWinner(s1);

  stepCount++;

  // insert new node every lambda_it iterations (Fritzke-style)
  // insertNode() sendiri akan gagal diam-diam jika tidak ada slot kosong
  if ((stepCount % lambda_it) == 0) {
    insertNode();
  }

  // decrease all errors
  for (int i = 0; i < MAX_NODES; i++) {
    if (nodes[i].active) {
      nodes[i].error *= beta;
    }
  }
}

// --------------------------------------------------------------------------
// Initialize GNG state (similar to Arduino setup())
// --------------------------------------------------------------------------
static void initGNG(void) {
  // clear nodes and edges
  for (int i = 0; i < MAX_NODES; i++) {
    nodes[i].x = 0.0f;
    nodes[i].y = 0.0f;
    nodes[i].error = 0.0f;
    nodes[i].active = false;
  }
  for (int i = 0; i < MAX_EDGES; i++) {
    edges[i].a = 0;
    edges[i].b = 0;
    edges[i].age = 0;
    edges[i].active = false;
  }

  dataCount = 0;
  dataDone  = false;
  running   = false;
  stepCount = 0;
  dataIndex = 0;

  // two initial nodes
  nodes[0].x = 0.2f;
  nodes[0].y = 0.2f;
  nodes[0].error = 0.0f;
  nodes[0].active = true;

  nodes[1].x = 0.8f;
  nodes[1].y = 0.8f;
  nodes[1].error = 0.0f;
  nodes[1].active = true;

  nodeCount = 2;
}

/**********************************************************************//**
 * Main function.
 *
 * @note This program requires the UART interface to be synthesized.
 **************************************************************************/
int main(void) {

  // capture all exceptions and give debug info via UART
  neorv32_rte_setup();

  // setup UART at default baud rate, no interrupts
  neorv32_uart0_setup(BAUD_RATE, 0);

  // init GNG
  initGNG();

  // indicate readiness (like Arduino "READY")
  neorv32_uart0_puts("READY\n");

  // main loop
  while (1) {
    readSerial();

    if (!dataDone) {
      continue;
    }
    if (!running) {
      continue;
    }
    if (dataCount == 0) {
      continue;
    }

    float x = dataX[dataIndex];
    float y = dataY[dataIndex];

    dataIndex++;
    if (dataIndex >= dataCount) {
      dataIndex = 0;
    }

    trainOneStep(x, y);
    sendGNG();
  }

  return 0;
}
