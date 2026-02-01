// ================================================================================
// NEORV32 main.c - GNG Fritzke (CPU does full GNG)
// CFS ONLY does: winner finder (s1,s2,min1,min2) using active mask + node_mem
// Edges stored as HALF adjacency matrix (upper-triangle) with 1 byte per pair:
//   bit7 = connected flag, bit6..0 = age (0..127)
// Optimized:
//   (1) ageEdgesFromWinner: scan only row/col of winner in half-matrix (2 loops)
//   (4) move neighbors:     scan only row/col of winner in half-matrix (2 loops)
//   pruneIsolatedNodes:     per node scan row/col in half-matrix (2 loops)
// ================================================================================

#include <neorv32.h>
#include <neorv32_cfs.h>
#include <stdbool.h>
#include <stdint.h>

#define BAUD_RATE 1000000

// ---------------- GNG parameters (Fritzke) ----------------
#define GNG_LAMBDA      100
#define GNG_EPSILON_B   0.3f
#define GNG_EPSILON_N   0.001f
#define GNG_ALPHA       0.5f
#define GNG_A_MAX       50
#define GNG_D           0.995f

// ---------------- Limits ----------------
#define MAXPTS      100
#define MAX_NODES    40

// Half adjacency matrix size (upper triangle, i<j)
#define MAX_EDGES_FULL ((MAX_NODES * (MAX_NODES - 1)) / 2)

// UART payload limit: len is uint8_t (<=255)
// sendGNGEdges payload: [frame_id][count][a0][b0]...[aN][bN]
// => 2 + 2*count <= 255 => count <= 126
#define MAX_EDGE_PAIRS_PER_FRAME 126

// ---------------- UART protocol ----------------
#define UART_HDR        0xFFu
#define CMD_DATA_BATCH  0x01u
#define CMD_DONE        0x02u
#define CMD_RUN         0x03u
#define CMD_GNG_NODES   0x10u
#define CMD_GNG_EDGES   0x11u

#define STREAM_EVERY_N  10  // stream every N steps

enum { RX_WAIT_H1=0, RX_WAIT_H2, RX_WAIT_CMD, RX_WAIT_LEN, RX_WAIT_PAYLOAD, RX_WAIT_CHK };

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

// Node CPU struct (full CPU GNG)
typedef struct {
  float x, y;
  float error;
  bool  active;
} Node;

static Node nodes[MAX_NODES];

static int stepCount = 0;
static int dataIndex = 0;
static uint8_t frame_id = 0;
static bool g_has_cfs = false;

// ============================ CFS REG MAP (match VHDL) ============================
#define CFS_REG_CTRL       0
#define CFS_REG_XIN        8
#define CFS_REG_YIN        9
#define CFS_REG_NODE_COUNT 10
#define CFS_REG_ACT_LO     11
#define CFS_REG_ACT_HI     12
#define CFS_REG_OUT_S12    13
#define CFS_REG_OUT_MIN1   14
#define CFS_REG_OUT_MIN2   15

#define CFS_NODE_BASE      128

#define CFS_CTRL_CLEAR     (1u << 0)
#define CFS_CTRL_START     (1u << 1)
#define CFS_STATUS_BUSY    (1u << 16)
#define CFS_STATUS_DONE    (1u << 17)

// ============================ EDGE storage (Half adjacency matrix) ================
#define EDGE_CONN_MASK 0x80u
#define EDGE_AGE_MASK  0x7Fu

// edge_cell[edge_index(i,j)] = (connected<<7) | age(7-bit), for i<j
static uint8_t edge_cell[MAX_EDGES_FULL];

// ============================ Utility ===========================================
static inline float dist2(float x1, float y1, float x2, float y2) {
  float dx = x1 - x2;
  float dy = y1 - y2;
  return dx*dx + dy*dy;
}

static inline uint16_t float_to_q15_pos(float v) {
  if (v <= 0.0f) return 0;
  if (v >= 0.9999694824f) return 0x7FFF;
  int32_t q = (int32_t)(v * 32768.0f + 0.5f);
  if (q > 0x7FFF) q = 0x7FFF;
  return (uint16_t)q;
}

static inline uint32_t pack_node_q15(float x, float y) {
  uint16_t xq = float_to_q15_pos(x);
  uint16_t yq = float_to_q15_pos(y);
  return ((uint32_t)xq) | (((uint32_t)yq) << 16);
}

static inline float q30_to_float(uint32_t q30) {
  return (float)q30 / 1073741824.0f; // 2^30
}

static int findFreeNode(void) {
  for (int i = 0; i < MAX_NODES; i++) if (!nodes[i].active) return i;
  return -1;
}

// Faster variant when you ALREADY guarantee i<j (no swap)
static inline int edge_index_ij(int i, int j) {
  // ASSUME i < j
  return (i * (2*MAX_NODES - i - 1)) / 2 + (j - i - 1);
}

// General mapping with swap (only used where convenient)
static inline int edge_index(int i, int j) {
  if (i == j) return -1;
  if (i > j) { int t = i; i = j; j = t; }
  return edge_index_ij(i, j);
}

static inline void edge_set(int a, int b, bool connected, uint8_t age) {
  int ei = edge_index(a, b);
  if (ei < 0) return;
  edge_cell[ei] = (connected ? EDGE_CONN_MASK : 0u) | (age & EDGE_AGE_MASK);
}

static inline bool edge_is_connected(int a, int b) {
  int ei = edge_index(a, b);
  if (ei < 0) return false;
  return (edge_cell[ei] & EDGE_CONN_MASK) != 0;
}

static void edges_init_full(void) {
  for (int i = 0; i < MAX_EDGES_FULL; i++) edge_cell[i] = 0;
}

static inline void connectOrResetEdge(int a, int b) {
  edge_set(a, b, true, 0);
}

static inline void removeEdgePair(int a, int b) {
  edge_set(a, b, false, 0);
}

// ============================ OPTIMIZED ageEdgesFromWinner =======================
static void ageEdgesFromWinner(int w) {
  // i < w -> cell(i, w)
  for (int i = 0; i < w; i++) {
    int ei = edge_index_ij(i, w);
    uint8_t v = edge_cell[ei];
    if ((v & EDGE_CONN_MASK) == 0) continue;

    uint8_t age = (uint8_t)(v & EDGE_AGE_MASK);
    if (age < 127u) age++;
    edge_cell[ei] = EDGE_CONN_MASK | age;
  }

  // i > w -> cell(w, i)
  for (int i = w + 1; i < MAX_NODES; i++) {
    int ei = edge_index_ij(w, i);
    uint8_t v = edge_cell[ei];
    if ((v & EDGE_CONN_MASK) == 0) continue;

    uint8_t age = (uint8_t)(v & EDGE_AGE_MASK);
    if (age < 127u) age++;
    edge_cell[ei] = EDGE_CONN_MASK | age;
  }
}

static void deleteOldEdges(void) {
  for (int ei = 0; ei < MAX_EDGES_FULL; ei++) {
    uint8_t v = edge_cell[ei];
    if ((v & EDGE_CONN_MASK) == 0) continue;
    uint8_t age = (uint8_t)(v & EDGE_AGE_MASK);
    if (age > (uint8_t)GNG_A_MAX) edge_cell[ei] = 0;
  }
}

// ============================ OPTIMIZED pruneIsolatedNodes (two-loop) ============
static void pruneIsolatedNodes(void) {
  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) continue;

    bool has_edge = false;

    // j < i -> cell(j, i)
    for (int j = 0; j < i; j++) {
      int ei = edge_index_ij(j, i);
      if (edge_cell[ei] & EDGE_CONN_MASK) { has_edge = true; break; }
    }

    // j > i -> cell(i, j)
    if (!has_edge) {
      for (int j = i + 1; j < MAX_NODES; j++) {
        int ei = edge_index_ij(i, j);
        if (edge_cell[ei] & EDGE_CONN_MASK) { has_edge = true; break; }
      }
    }

    if (!has_edge) nodes[i].active = false;
  }
}

// Fritzke insertion (original order)
static int insertNode_fritzke(void) {
  int q = -1;
  float maxErr = -1.0f;

  for (int i = 0; i < MAX_NODES; i++) {
    if (nodes[i].active && nodes[i].error > maxErr) { maxErr = nodes[i].error; q = i; }
  }
  if (q < 0) return -1;

  int f = -1;
  maxErr = -1.0f;

  // scan neighbors of q (still simple; can be optimized later similarly)
  for (int j = 0; j < MAX_NODES; j++) {
    if (j == q) continue;
    if (!nodes[j].active) continue;
    if (!edge_is_connected(q, j)) continue;
    if (nodes[j].error > maxErr) { maxErr = nodes[j].error; f = j; }
  }
  if (f < 0) return -1;

  int r = findFreeNode();
  if (r < 0) return -1;

  nodes[r].x = 0.5f * (nodes[q].x + nodes[f].x);
  nodes[r].y = 0.5f * (nodes[q].y + nodes[f].y);
  nodes[r].active = true;

  removeEdgePair(q, f);
  connectOrResetEdge(q, r);
  connectOrResetEdge(r, f);

  nodes[q].error *= GNG_ALPHA;
  nodes[f].error *= GNG_ALPHA;
  nodes[r].error  = nodes[q].error;

  return r;
}

// ============================ UART TX ===========================================
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
  uint8_t payload[2 + MAX_EDGE_PAIRS_PER_FRAME * 2];
  uint8_t p = 0;
  payload[p++] = frame_id;
  payload[p++] = 0;

  uint8_t edge_count = 0;

  // enumerate upper triangle pairs (i<j)
  for (int i = 0; i < MAX_NODES; i++) {
    for (int j = i + 1; j < MAX_NODES; j++) {
      int ei = edge_index_ij(i, j);
      if ((edge_cell[ei] & EDGE_CONN_MASK) == 0) continue;

      payload[p++] = (uint8_t)i;
      payload[p++] = (uint8_t)j;
      edge_count++;

      if (edge_count >= MAX_EDGE_PAIRS_PER_FRAME) {
        i = MAX_NODES; // break outer
        break;
      }
    }
  }

  payload[1] = edge_count;
  uart_send_frame(CMD_GNG_EDGES, payload, p);
}

// ============================ UART RX ===========================================
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

// ============================ CFS helpers =======================================
static void cfs_sync_nodes_full(void) {
  for (int i = 0; i < MAX_NODES; i++) {
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

  NEORV32_CFS->REG[CFS_REG_XIN]        = (uint32_t)float_to_q15_pos(x);
  NEORV32_CFS->REG[CFS_REG_YIN]        = (uint32_t)float_to_q15_pos(y);
  NEORV32_CFS->REG[CFS_REG_NODE_COUNT] = (uint32_t)MAX_NODES;
  NEORV32_CFS->REG[CFS_REG_ACT_LO]     = act_lo;
  NEORV32_CFS->REG[CFS_REG_ACT_HI]     = act_hi8;

  NEORV32_CFS->REG[CFS_REG_CTRL] = CFS_CTRL_START;

  const uint32_t TIMEOUT = 200000u;
  for (uint32_t t = 0; t < TIMEOUT; t++) {
    uint32_t st = NEORV32_CFS->REG[CFS_REG_CTRL];
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

// ============================ GNG Step (CPU Fritzke) =============================
static void trainOneStep(float x, float y) {
  int s1=-1, s2=-1;
  float d1 = 1e30f;

  if (!cfs_find_winners(x, y, &s1, &s2, &d1)) {
    float best1=1e30f, best2=1e30f;
    for (int i=0;i<MAX_NODES;i++){
      if(!nodes[i].active) continue;
      float d = dist2(x,y,nodes[i].x,nodes[i].y);
      if (d < best1) { best2=best1; s2=s1; best1=d; s1=i; }
      else if (d < best2) { best2=d; s2=i; }
    }
    d1 = best1;
  }

  if (s1 < 0 || s2 < 0) return;

  // (1) age edges from winner (two-loop)
  ageEdgesFromWinner(s1);

  // (2) error accumulate
  nodes[s1].error += d1;

  // (3) move winner
  nodes[s1].x += GNG_EPSILON_B * (x - nodes[s1].x);
  nodes[s1].y += GNG_EPSILON_B * (y - nodes[s1].y);
  cfs_write_one_node(s1);

  // (4) move neighbors (two-loop)
  for (int i = 0; i < s1; i++) {
    if (!nodes[i].active) continue;
    int ei = edge_index_ij(i, s1);
    if ((edge_cell[ei] & EDGE_CONN_MASK) == 0) continue;

    nodes[i].x += GNG_EPSILON_N * (x - nodes[i].x);
    nodes[i].y += GNG_EPSILON_N * (y - nodes[i].y);
    cfs_write_one_node(i);
  }

  for (int i = s1 + 1; i < MAX_NODES; i++) {
    if (!nodes[i].active) continue;
    int ei = edge_index_ij(s1, i);
    if ((edge_cell[ei] & EDGE_CONN_MASK) == 0) continue;

    nodes[i].x += GNG_EPSILON_N * (x - nodes[i].x);
    nodes[i].y += GNG_EPSILON_N * (y - nodes[i].y);
    cfs_write_one_node(i);
  }

  // (5) connect winners (reset age=0)
  connectOrResetEdge(s1, s2);

  // (6) remove old edges + prune
  deleteOldEdges();
  pruneIsolatedNodes();

  stepCount++;

  // (7) insert every lambda
  if ((stepCount % GNG_LAMBDA) == 0) {
    (void)insertNode_fritzke();
    pruneIsolatedNodes();
    cfs_sync_nodes_full();
  }

  // (8) decay errors
  for (int i=0;i<MAX_NODES;i++){
    if(nodes[i].active) nodes[i].error *= GNG_D;
  }
}

// ============================ Init ===============================================
static void initGNG(void) {
  for (int i=0;i<MAX_NODES;i++){
    nodes[i].x=0.0f; nodes[i].y=0.0f;
    nodes[i].error=0.0f;
    nodes[i].active=false;
  }

  edges_init_full();

  dataCount=0; dataDone=false; running=false;
  stepCount=0; dataIndex=0; frame_id=0;

  nodes[0].x=0.2f; nodes[0].y=0.2f; nodes[0].active=true;
  nodes[1].x=0.8f; nodes[1].y=0.8f; nodes[1].active=true;
}

int main(void) {
  neorv32_rte_setup();
  neorv32_uart0_setup(BAUD_RATE, 0);

  initGNG();
  neorv32_uart0_puts("READY\n");

  g_has_cfs = (neorv32_cfs_available() != 0);
  neorv32_uart0_puts(g_has_cfs ? "CFS=1\n" : "CFS=0\n");
  if (!g_has_cfs) {
    neorv32_uart0_puts("ERROR: CFS missing\n");
    while (1) { }
  }

  // Clear CFS flags
  NEORV32_CFS->REG[CFS_REG_CTRL] = CFS_CTRL_CLEAR;
  cfs_sync_nodes_full();

  bool preprocessed = false;

  while (1) {
    readSerial();

    if (dataDone && !preprocessed) {
      neorv32_uart0_puts("DATA OK\n");
      preprocessed = true;
      running = true; // auto-run
    }

    if (!dataDone || !running || (dataCount <= 0)) continue;

    float x = dataX[dataIndex];
    float y = dataY[dataIndex];
    dataIndex++;
    if (dataIndex >= dataCount) dataIndex = 0;

    trainOneStep(x, y);

    if ((stepCount % STREAM_EVERY_N) == 0) {
      frame_id++;
      sendGNGNodes();
      sendGNGEdges();
    }
  }

  return 0;
}
