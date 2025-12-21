// ================================================================================ //
// The NEORV32 RISC-V Processor - https://github.com/stnolting/neorv32              //
// BSD-3-Clause license                                                            //
// ================================================================================ //

#include <neorv32.h>
#include <stdbool.h>
#include <stdint.h>

/**********************************************************************//**
 * HW configuration
 **************************************************************************/
#define BAUD_RATE 1000000

/**********************************************************************//**
 * ---------------- GNG TUNABLE PARAMETERS (EDIT HERE) ----------------
 * Sesuai paper Fritzke (contoh caption Figure):
 *   λ = 100, εb = 0.2, εn = 0.006, α = 0.5, a_max = 50, d = 0.995
 **************************************************************************/
#define GNG_LAMBDA      100     // λ: insert node every λ steps
#define GNG_EPSILON_B   0.3f    // εb: winner learning rate
#define GNG_EPSILON_N   0.001f   // εn: neighbor learning rate
#define GNG_ALPHA       0.5f    // α: error reduction for q and f at insertion
#define GNG_A_MAX       50      // a_max: max edge age, delete if age > a_max
#define GNG_D           0.995f  // d: global error decay each step

/**********************************************************************//**
 * Limits
 **************************************************************************/
#define MAXPTS     100
#define MAX_NODES   40
#define MAX_EDGES   80

/**********************************************************************//**
 * UART protocol (split frames)
 * Frame: FF FF CMD LEN PAYLOAD CHK, CHK = ~(CMD+LEN+sum(payload))
 **************************************************************************/
#define UART_HDR        0xFFu
#define CMD_DATA_BATCH  0x01u
#define CMD_DONE        0x02u
#define CMD_RUN         0x03u
#define CMD_GNG_NODES   0x10u
#define CMD_GNG_EDGES   0x11u

// RX state machine
enum {
  RX_WAIT_H1 = 0,
  RX_WAIT_H2,
  RX_WAIT_CMD,
  RX_WAIT_LEN,
  RX_WAIT_PAYLOAD,
  RX_WAIT_CHK
};

static uint8_t  rx_state = RX_WAIT_H1;
static uint8_t  rx_cmd   = 0;
static uint8_t  rx_len   = 0;
static uint8_t  rx_index = 0;
static uint8_t  rx_sum   = 0;
static uint8_t  rx_payload[256];

// Dataset
static float dataX[MAXPTS];
static float dataY[MAXPTS];
static int   dataCount = 0;
static bool  dataDone  = false;
static bool  running   = false;

// GNG structures
typedef struct {
  float x, y;
  float error;
  bool  active;
} Node;

typedef struct {
  int  a, b;
  int  age;
  bool active;
} Edge;

static Node nodes[MAX_NODES];
static Edge edges[MAX_EDGES];

static int stepCount = 0;
static int dataIndex = 0;
static uint8_t frame_id = 0;

// ---------------- Utility ----------------
static float dist2(float x1, float y1, float x2, float y2) {
  float dx = x1 - x2;
  float dy = y1 - y2;
  return dx*dx + dy*dy;
}

static int findFreeNode(void) {
  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) return i;
  }
  return -1;
}

// return edge index if exists else -1
static int findEdge(int a, int b) {
  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) continue;
    if ((edges[i].a == a && edges[i].b == b) ||
        (edges[i].a == b && edges[i].b == a)) {
      return i;
    }
  }
  return -1;
}

// Fritzke step: "create edge s1-s2 (or reset its age)"
static void connectOrResetEdge(int a, int b) {
  int ei = findEdge(a, b);
  if (ei >= 0) {
    edges[ei].age = 0;
    return;
  }

  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) {
      edges[i].a = a;
      edges[i].b = b;
      edges[i].age = 0;
      edges[i].active = true;
      return;
    }
  }
}

static void removeEdgePair(int a, int b) {
  int ei = findEdge(a, b);
  if (ei >= 0) edges[ei].active = false;
}

// Fritzke step: "increment age of all edges emanating from winner"
static void ageEdgesFromWinner(int winner) {
  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) continue;
    if (edges[i].a == winner || edges[i].b == winner) {
      edges[i].age++;
    }
  }
}

// Fritzke step: "remove edges with age > a_max"
static void deleteOldEdges(void) {
  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) continue;
    if (edges[i].age > GNG_A_MAX) {
      edges[i].active = false;
    }
  }
}

// Fritzke step: "remove nodes with no incident edges"
static void pruneIsolatedNodes(void) {
  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) continue;

    bool has_edge = false;
    for (int e = 0; e < MAX_EDGES; e++) {
      if (!edges[e].active) continue;
      if (edges[e].a == i || edges[e].b == i) {
        has_edge = true;
        break;
      }
    }
    if (!has_edge) nodes[i].active = false;
  }
}

// Fritzke insertion rule
static void insertNode(void) {
  // q: node with maximum accumulated error
  int q = -1;
  float maxErr = -1.0f;
  for (int i = 0; i < MAX_NODES; i++) {
    if (nodes[i].active && nodes[i].error > maxErr) {
      maxErr = nodes[i].error;
      q = i;
    }
  }
  if (q < 0) return;

  // f: neighbor of q with maximum error
  int f = -1;
  maxErr = -1.0f;
  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) continue;

    int nb = -1;
    if (edges[i].a == q) nb = edges[i].b;
    else if (edges[i].b == q) nb = edges[i].a;

    if (nb >= 0 && nodes[nb].active && nodes[nb].error > maxErr) {
      maxErr = nodes[nb].error;
      f = nb;
    }
  }
  if (f < 0) return;

  int r = findFreeNode();
  if (r < 0) return;

  // r at midpoint
  nodes[r].x = 0.5f * (nodes[q].x + nodes[f].x);
  nodes[r].y = 0.5f * (nodes[q].y + nodes[f].y);
  
  nodes[r].active = true;

  // decrease error of q and f
  nodes[q].error *= GNG_ALPHA;
  nodes[f].error *= GNG_ALPHA;

  nodes[r].error = nodes[q].error; // common Fritzke choice

  // remove edge q-f and add q-r, r-f
  removeEdgePair(q, f);
  connectOrResetEdge(q, r);
  connectOrResetEdge(r, f);
}

// ---------------- UART frame TX ----------------
static void uart_send_frame(uint8_t cmd, const uint8_t *payload, uint8_t len) {
  uint8_t sum = (uint8_t)(cmd + len);
  for (uint8_t i = 0; i < len; i++) sum = (uint8_t)(sum + payload[i]);
  uint8_t chk = (uint8_t)(~sum);

  neorv32_uart0_putc((char)UART_HDR);
  neorv32_uart0_putc((char)UART_HDR);
  neorv32_uart0_putc((char)cmd);
  neorv32_uart0_putc((char)len);
  for (uint8_t i = 0; i < len; i++) neorv32_uart0_putc((char)payload[i]);
  neorv32_uart0_putc((char)chk);
}

static void sendGNGNodes(void) {
  // payload: [frame_id][node_count] + node_count * { idx, x16, y16 }
  uint8_t payload[2 + MAX_NODES * 5];
  uint8_t p = 0;

  payload[p++] = frame_id;
  payload[p++] = 0; // node_count placeholder

  uint8_t node_count = 0;
  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) continue;

    int16_t xi = (int16_t)(nodes[i].x * 1000.0f);
    int16_t yi = (int16_t)(nodes[i].y * 1000.0f);

    payload[p++] = (uint8_t)i;
    payload[p++] = (uint8_t)(xi & 0xFF);
    payload[p++] = (uint8_t)((xi >> 8) & 0xFF);
    payload[p++] = (uint8_t)(yi & 0xFF);
    payload[p++] = (uint8_t)((yi >> 8) & 0xFF);

    node_count++;
  }
  payload[1] = node_count;

  uart_send_frame(CMD_GNG_NODES, payload, p);
}

static void sendGNGEdges(void) {
  // payload: [frame_id][edge_count] + edge_count * { a, b }
  uint8_t payload[2 + MAX_EDGES * 2];
  uint8_t p = 0;

  payload[p++] = frame_id;
  payload[p++] = 0; // edge_count placeholder

  uint8_t edge_count = 0;
  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) continue;
    payload[p++] = (uint8_t)edges[i].a;
    payload[p++] = (uint8_t)edges[i].b;
    edge_count++;
  }
  payload[1] = edge_count;

  uart_send_frame(CMD_GNG_EDGES, payload, p);
}

// ---------------- UART RX ----------------
static void handleCommand(uint8_t cmd, const uint8_t *payload, uint8_t len) {
  if (cmd == CMD_DATA_BATCH) {
    if (len < 1) return;

    uint8_t count = payload[0];
    if (len < (uint8_t)(1 + count * 4u)) return;

    uint8_t pos = 1;
    for (uint8_t i = 0; i < count; i++) {
      int16_t xi = (int16_t)((uint16_t)payload[pos] | ((uint16_t)payload[pos + 1] << 8));
      int16_t yi = (int16_t)((uint16_t)payload[pos + 2] | ((uint16_t)payload[pos + 3] << 8));
      pos += 4;

      if (dataCount < MAXPTS) {
        dataX[dataCount] = (float)xi / 1000.0f;
        dataY[dataCount] = (float)yi / 1000.0f;
        dataCount++;
      }
    }
  }
  else if (cmd == CMD_DONE) {
    dataDone = true;
  }
  else if (cmd == CMD_RUN) {
    running = true;
  }
}

static void readSerial(void) {
  while (neorv32_uart0_char_received()) {
    uint8_t b = (uint8_t)neorv32_uart0_getc();

    switch (rx_state) {
      case RX_WAIT_H1:
        if (b == UART_HDR) rx_state = RX_WAIT_H2;
        break;

      case RX_WAIT_H2:
        if (b == UART_HDR) rx_state = RX_WAIT_CMD;
        else rx_state = RX_WAIT_H1;
        break;

      case RX_WAIT_CMD:
        rx_cmd = b;
        rx_sum = b;
        rx_state = RX_WAIT_LEN;
        break;

      case RX_WAIT_LEN:
        rx_len = b;
        rx_sum = (uint8_t)(rx_sum + b);
        rx_index = 0;
        if (rx_len == 0) rx_state = RX_WAIT_CHK;
        else if (rx_len > sizeof(rx_payload)) rx_state = RX_WAIT_H1;
        else rx_state = RX_WAIT_PAYLOAD;
        break;

      case RX_WAIT_PAYLOAD:
        rx_payload[rx_index++] = b;
        rx_sum = (uint8_t)(rx_sum + b);
        if (rx_index >= rx_len) rx_state = RX_WAIT_CHK;
        break;

      case RX_WAIT_CHK: {
        uint8_t expected = (uint8_t)(~rx_sum);
        if (b == expected) handleCommand(rx_cmd, rx_payload, rx_len);
        rx_state = RX_WAIT_H1;
        break;
      }

      default:
        rx_state = RX_WAIT_H1;
        break;
    }
  }
}

// ---------------- GNG step (Fritzke order) ----------------
static void trainOneStep(float x, float y) {
  int   s1 = -1, s2 = -1;
  float d1 = 1e30f, d2 = 1e30f;

  // 1) find nearest and second nearest
  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) continue;

    float d = dist2(x, y, nodes[i].x, nodes[i].y);
    if (d < d1) {
      d2 = d1; s2 = s1;
      d1 = d;  s1 = i;
    } else if (d < d2) {
      d2 = d;  s2 = i;
    }
  }
  if (s1 < 0 || s2 < 0) return;

  // 2) increment age of edges from winner
  ageEdgesFromWinner(s1);

  // 3) add error to winner (use squared distance is OK)
  nodes[s1].error += d1;

  // 4) move winner and its neighbors
  nodes[s1].x += GNG_EPSILON_B * (x - nodes[s1].x);
  nodes[s1].y += GNG_EPSILON_B * (y - nodes[s1].y);

  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) continue;
    if (edges[i].a == s1 || edges[i].b == s1) {
      int nb = (edges[i].a == s1) ? edges[i].b : edges[i].a;
      if (nodes[nb].active) {
        nodes[nb].x += GNG_EPSILON_N * (x - nodes[nb].x);
        nodes[nb].y += GNG_EPSILON_N * (y - nodes[nb].y);
      }
    }
  }

  // 5) connect s1-s2 (reset age to 0)
  connectOrResetEdge(s1, s2);

  // 6) remove old edges
  deleteOldEdges();

  // 7) remove isolated nodes
  pruneIsolatedNodes();

  // bookkeeping
  stepCount++;

  // 8) every λ steps insert a new node
  if ((stepCount % GNG_LAMBDA) == 0) {
    insertNode();
    // after insertion, cleanup isolated (safe)
    pruneIsolatedNodes();
  }

  // 9) decrease all errors by factor d
  for (int i = 0; i < MAX_NODES; i++) {
    if (nodes[i].active) nodes[i].error *= GNG_D;
  }
}

// ---------------- Init ----------------
static void initGNG(void) {
  for (int i = 0; i < MAX_NODES; i++) {
    nodes[i].x = 0.0f; nodes[i].y = 0.0f;
    nodes[i].error = 0.0f;
    nodes[i].active = false;
  }
  for (int i = 0; i < MAX_EDGES; i++) {
    edges[i].a = 0; edges[i].b = 0;
    edges[i].age = 0;
    edges[i].active = false;
  }

  dataCount = 0;
  dataDone  = false;
  running   = false;
  stepCount = 0;
  dataIndex = 0;
  frame_id  = 0;

  // initial 2 nodes
  nodes[0].x = 0.2f; nodes[0].y = 0.2f; nodes[0].active = true;
  nodes[1].x = 0.8f; nodes[1].y = 0.8f; nodes[1].active = true;
}

int main(void) {
  neorv32_rte_setup();
  neorv32_uart0_setup(BAUD_RATE, 0);

  initGNG();
  neorv32_uart0_puts("READY\n");

  while (1) {
    readSerial();

    if (!dataDone || !running || (dataCount <= 0)) continue;

    float x = dataX[dataIndex];
    float y = dataY[dataIndex];

    dataIndex++;
    if (dataIndex >= dataCount) dataIndex = 0;

    trainOneStep(x, y);

    frame_id++;
    sendGNGNodes();
    sendGNGEdges();
  }

  return 0;
}
