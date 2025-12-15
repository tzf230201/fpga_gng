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
 **************************************************************************/
#define GNG_LAMBDA      100
#define GNG_EPSILON_B   0.3f
#define GNG_EPSILON_N   0.001f
#define GNG_ALPHA       0.5f
#define GNG_A_MAX       50
#define GNG_D           0.995f

/**********************************************************************//**
 * Limits
 **************************************************************************/
#define MAXPTS      100
#define MAX_NODES    40
#define MAX_EDGES    80

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

// send visualization not every step (biar Processing gak kewalahan)
#define STREAM_EVERY_N  5

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

static void connectOrResetEdge(int a, int b) {
  int ei = findEdge(a, b);
  if (ei >= 0) { edges[ei].age = 0; return; }

  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) {
      edges[i].a = a; edges[i].b = b;
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

static void ageEdgesFromWinner(int winner) {
  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) continue;
    if (edges[i].a == winner || edges[i].b == winner) edges[i].age++;
  }
}

static void deleteOldEdges(void) {
  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) continue;
    if (edges[i].age > GNG_A_MAX) edges[i].active = false;
  }
}

static void pruneIsolatedNodes(void) {
  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) continue;

    bool has_edge = false;
    for (int e = 0; e < MAX_EDGES; e++) {
      if (!edges[e].active) continue;
      if (edges[e].a == i || edges[e].b == i) { has_edge = true; break; }
    }
    if (!has_edge) nodes[i].active = false;
  }
}

// Fritzke insertion rule (return index r or -1)
static int insertNode(void) {
  int q = -1;
  float maxErr = -1.0f;
  for (int i = 0; i < MAX_NODES; i++) {
    if (nodes[i].active && nodes[i].error > maxErr) { maxErr = nodes[i].error; q = i; }
  }
  if (q < 0) return -1;

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
  if (f < 0) return -1;

  int r = findFreeNode();
  if (r < 0) return -1;

  nodes[r].x = 0.5f * (nodes[q].x + nodes[f].x);
  nodes[r].y = 0.5f * (nodes[q].y + nodes[f].y);
  nodes[r].error  = nodes[q].error;
  nodes[r].active = true;

  nodes[q].error *= GNG_ALPHA;
  nodes[f].error *= GNG_ALPHA;

  removeEdgePair(q, f);
  connectOrResetEdge(q, r);
  connectOrResetEdge(r, f);

  return r;
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
  uint8_t payload[2 + MAX_NODES * 5];
  uint8_t p = 0;

  payload[p++] = frame_id;
  payload[p++] = 0;

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
  uint8_t payload[2 + MAX_EDGES * 2];
  uint8_t p = 0;

  payload[p++] = frame_id;
  payload[p++] = 0;

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
  } else if (cmd == CMD_DONE) {
    dataDone = true;
  } else if (cmd == CMD_RUN) {
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
        rx_cmd = b; rx_sum = b; rx_state = RX_WAIT_LEN;
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

// ============================================================================
// ======================  CFS WINNER-FINDER INTEGRATION  ======================
// ============================================================================
#include <neorv32_cfs.h>

// register map must match VHDL
#define CFS_REG_CTRL       0
#define CFS_REG_COUNT      1

#define CFS_REG_LAMBDA     2
#define CFS_REG_A_MAX      3
#define CFS_REG_EPS_B      4
#define CFS_REG_EPS_N      5
#define CFS_REG_ALPHA      6
#define CFS_REG_D          7

#define CFS_REG_XIN        8
#define CFS_REG_YIN        9
#define CFS_REG_NODE_COUNT 10
#define CFS_REG_ACT_LO     11
#define CFS_REG_ACT_HI     12

#define CFS_REG_OUT_S12    13
#define CFS_REG_OUT_MIN1   14
#define CFS_REG_OUT_MIN2   15

#define CFS_DATA_BASE      16
#define CFS_NODE_BASE      128

#define CFS_CTRL_CLEAR     (1u << 0)
#define CFS_CTRL_START     (1u << 1)

#define CFS_STATUS_BUSY    (1u << 16)
#define CFS_STATUS_DONE    (1u << 17)

static bool g_has_cfs = false;

// float [0..1] -> Q0.16
static inline uint16_t float_to_q16(float v) {
  if (v <= 0.0f) return 0;
  if (v >= 0.9999847412f) return 0xFFFF;
  uint32_t q = (uint32_t)(v * 65536.0f + 0.5f);
  if (q > 0xFFFF) q = 0xFFFF;
  return (uint16_t)q;
}

// float [0..1] -> Q1.15 signed positive (0..0x7FFF)
static inline int16_t float_to_q15_pos(float v) {
  if (v <= 0.0f) return 0;
  if (v >= 0.9999694824f) return (int16_t)0x7FFF; // (32767/32768)
  int32_t q = (int32_t)(v * 32768.0f + 0.5f);
  if (q > 0x7FFF) q = 0x7FFF;
  return (int16_t)q;
}

// pack node xy: [15:0]=x_q15, [31:16]=y_q15
static inline uint32_t pack_node_q15(float x, float y) {
  int16_t xq = float_to_q15_pos(x);
  int16_t yq = float_to_q15_pos(y);
  return ((uint32_t)(uint16_t)xq) | (((uint32_t)(uint16_t)yq) << 16);
}

static inline float q30_to_float(uint32_t q30) {
  // dist returned by CFS is Q2.30 (dx^2 + dy^2)
  return (float)q30 / 1073741824.0f; // 2^30
}

static void cfs_write_settings(void) {
  NEORV32_CFS->REG[CFS_REG_LAMBDA] = (uint32_t)GNG_LAMBDA;
  NEORV32_CFS->REG[CFS_REG_A_MAX]  = (uint32_t)GNG_A_MAX;

  NEORV32_CFS->REG[CFS_REG_EPS_B]  = (uint32_t)float_to_q16(GNG_EPSILON_B);
  NEORV32_CFS->REG[CFS_REG_EPS_N]  = (uint32_t)float_to_q16(GNG_EPSILON_N);
  NEORV32_CFS->REG[CFS_REG_ALPHA]  = (uint32_t)float_to_q16(GNG_ALPHA);
  NEORV32_CFS->REG[CFS_REG_D]      = (uint32_t)float_to_q16(GNG_D);
}

static void cfs_sync_nodes_full(void) {
  for (int i = 0; i < MAX_NODES; i++) {
    // write even if inactive (aman). active mask will filter.
    NEORV32_CFS->REG[CFS_NODE_BASE + i] = pack_node_q15(nodes[i].x, nodes[i].y);
  }
}

static inline void cfs_write_one_node(int i) {
  NEORV32_CFS->REG[CFS_NODE_BASE + i] = pack_node_q15(nodes[i].x, nodes[i].y);
}

static void cfs_build_active_mask(uint32_t *lo, uint32_t *hi8) {
  uint32_t mlo = 0;
  uint32_t mhi = 0;
  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) continue;
    if (i < 32) mlo |= (1u << i);
    else mhi |= (1u << (i - 32));
  }
  *lo = mlo;
  *hi8 = (mhi & 0xFFu);
}

static bool cfs_find_winners(float x, float y, int *s1, int *s2, float *d1_out) {
  uint32_t act_lo, act_hi8;
  cfs_build_active_mask(&act_lo, &act_hi8);

  NEORV32_CFS->REG[CFS_REG_XIN]        = (uint32_t)(uint16_t)float_to_q15_pos(x);
  NEORV32_CFS->REG[CFS_REG_YIN]        = (uint32_t)(uint16_t)float_to_q15_pos(y);
  NEORV32_CFS->REG[CFS_REG_NODE_COUNT] = (uint32_t)MAX_NODES;
  NEORV32_CFS->REG[CFS_REG_ACT_LO]     = act_lo;
  NEORV32_CFS->REG[CFS_REG_ACT_HI]     = act_hi8;

  NEORV32_CFS->REG[CFS_REG_CTRL] = CFS_CTRL_START;

  // wait done (timeout)
  const uint32_t TIMEOUT = 20000u;
  for (uint32_t t = 0; t < TIMEOUT; t++) {
    uint32_t st = NEORV32_CFS->REG[CFS_REG_CTRL]; // status bits in readback
    if (st & CFS_STATUS_DONE) break;
    if (t == TIMEOUT - 1) return false;
  }

  uint32_t s12  = NEORV32_CFS->REG[CFS_REG_OUT_S12];
  uint32_t min1 = NEORV32_CFS->REG[CFS_REG_OUT_MIN1];

  *s1 = (int)(s12 & 0xFFu);
  *s2 = (int)((s12 >> 8) & 0xFFu);
  *d1_out = q30_to_float(min1);
  return true;
}

// dataset upload optional (kalau VHDL kamu masih punya DATA_BASE)
static inline uint32_t pack_xy_i16(int16_t xi, int16_t yi) {
  return ((uint32_t)(uint16_t)xi) | (((uint32_t)(uint16_t)yi) << 16);
}

static void cfs_upload_dataset_and_settings_once(void) {
  const int n = (dataCount < MAXPTS) ? dataCount : MAXPTS;

  NEORV32_CFS->REG[CFS_REG_CTRL]  = CFS_CTRL_CLEAR;
  NEORV32_CFS->REG[CFS_REG_COUNT] = (uint32_t)n;

  // dataset (optional, boleh kamu comment kalau mau hemat resource VHDL)
  for (int i = 0; i < n; i++) {
    int16_t xi = (int16_t)(dataX[i] * 1000.0f);
    int16_t yi = (int16_t)(dataY[i] * 1000.0f);
    NEORV32_CFS->REG[CFS_DATA_BASE + i] = pack_xy_i16(xi, yi);
  }

  cfs_write_settings();
  cfs_sync_nodes_full();
}

// ---------------- GNG step (Fritzke order) ----------------
static void trainOneStep(float x, float y) {
  int   s1 = -1, s2 = -1;
  float d1 = 1e30f;

  // ========== winner search ==========
  if (g_has_cfs) {
    // keep HW node_mem up-to-date enough:
    // (at least winner + neighbors will be updated after movement; full sync on init/insert)
    if (!cfs_find_winners(x, y, &s1, &s2, &d1)) {
      // fallback SW if HW timeout
      s1 = -1; s2 = -1; d1 = 1e30f;
      float d2 = 1e30f;
      for (int i = 0; i < MAX_NODES; i++) {
        if (!nodes[i].active) continue;
        float d = dist2(x, y, nodes[i].x, nodes[i].y);
        if (d < d1) { d2 = d1; s2 = s1; d1 = d; s1 = i; }
        else if (d < d2) { d2 = d; s2 = i; }
      }
    }
  } else {
    float d2 = 1e30f;
    for (int i = 0; i < MAX_NODES; i++) {
      if (!nodes[i].active) continue;
      float d = dist2(x, y, nodes[i].x, nodes[i].y);
      if (d < d1) { d2 = d1; s2 = s1; d1 = d; s1 = i; }
      else if (d < d2) { d2 = d; s2 = i; }
    }
  }

  if (s1 < 0 || s2 < 0) return;

  // 2) increment age of edges from winner
  ageEdgesFromWinner(s1);

  // 3) add error to winner
  nodes[s1].error += d1;

  // 4) move winner
  nodes[s1].x += GNG_EPSILON_B * (x - nodes[s1].x);
  nodes[s1].y += GNG_EPSILON_B * (y - nodes[s1].y);
  if (g_has_cfs) cfs_write_one_node(s1);

  // move neighbors
  for (int i = 0; i < MAX_EDGES; i++) {
    if (!edges[i].active) continue;
    if (edges[i].a == s1 || edges[i].b == s1) {
      int nb = (edges[i].a == s1) ? edges[i].b : edges[i].a;
      if (nodes[nb].active) {
        nodes[nb].x += GNG_EPSILON_N * (x - nodes[nb].x);
        nodes[nb].y += GNG_EPSILON_N * (y - nodes[nb].y);
        if (g_has_cfs) cfs_write_one_node(nb);
      }
    }
  }

  // 5) connect s1-s2
  connectOrResetEdge(s1, s2);

  // 6) remove old edges
  deleteOldEdges();

  // 7) remove isolated nodes
  pruneIsolatedNodes();

  // bookkeeping
  stepCount++;

  // 8) every λ steps insert
  if ((stepCount % GNG_LAMBDA) == 0) {
    int r = insertNode();
    pruneIsolatedNodes();
    if (g_has_cfs) {
      // insertion rare -> full sync is OK & safe
      cfs_sync_nodes_full();
      (void)r;
    }
  }

  // 9) decay errors
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

  // detect CFS
  g_has_cfs = (neorv32_cfs_available() != 0);
  neorv32_uart0_puts(g_has_cfs ? "CFS=1\n" : "CFS=0\n");

  bool preprocessed = false;

  while (1) {
    readSerial();

    // setelah dataset selesai diterima, lakukan init CFS sekali
    if (dataDone && !preprocessed) {
      if (g_has_cfs) {
        cfs_upload_dataset_and_settings_once();
        neorv32_uart0_puts("CFS available\n");
      } else {
        neorv32_uart0_puts("CFS not available\n");
      }
      preprocessed = true;

      // aman: boleh tunggu CMD_RUN dari Processing, tapi kalau kamu mau auto-run:
      running = true;
    }

    if (!dataDone || !running || (dataCount <= 0)) continue;

    float x = dataX[dataIndex];
    float y = dataY[dataIndex];
    dataIndex++;
    if (dataIndex >= dataCount) dataIndex = 0;

    trainOneStep(x, y);

    // throttle UART streaming
    if ((stepCount % STREAM_EVERY_N) == 0) {
      frame_id++;
      sendGNGNodes();
      sendGNGEdges();
    }
  }

  return 0;
}
