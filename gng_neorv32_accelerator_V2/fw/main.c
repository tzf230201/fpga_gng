// ================================================================================ //
// The NEORV32 RISC-V Processor - https://github.com/stnolting/neorv32              //
// BSD-3-Clause license                                                            //
// ================================================================================ //

#include <neorv32.h>
#include <neorv32_cfs.h>
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

#define STREAM_EVERY_N  5

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

// Dataset in CPU (stream points)
static float dataX[MAXPTS];
static float dataY[MAXPTS];
static int   dataCount = 0;
static bool  dataDone  = false;
static bool  running   = false;

// Node CPU struct (edges stored in CFS BRAM)
typedef struct {
  float x, y;
  float error;
  bool  active;
} Node;

static Node nodes[MAX_NODES];

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

// ============================================================================
// ======================  CFS REG MAP (must match VHDL)  ======================
// ============================================================================
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
#define CFS_EDGE_BASE      168  // NEW: must match VHDL EDGE_BASE

#define CFS_CTRL_CLEAR     (1u << 0)
#define CFS_CTRL_START     (1u << 1)
#define CFS_STATUS_BUSY    (1u << 16)
#define CFS_STATUS_DONE    (1u << 17)

static bool g_has_cfs = false;

// ===================== Fixed-point helpers =====================
static inline uint16_t float_to_q16(float v) {
  if (v <= 0.0f) return 0;
  if (v >= 0.9999847412f) return 0xFFFF;
  uint32_t q = (uint32_t)(v * 65536.0f + 0.5f);
  if (q > 0xFFFF) q = 0xFFFF;
  return (uint16_t)q;
}

static inline int16_t float_to_q15_pos(float v) {
  if (v <= 0.0f) return 0;
  if (v >= 0.9999694824f) return (int16_t)0x7FFF;
  int32_t q = (int32_t)(v * 32768.0f + 0.5f);
  if (q > 0x7FFF) q = 0x7FFF;
  return (int16_t)q;
}

static inline uint32_t pack_node_q15(float x, float y) {
  int16_t xq = float_to_q15_pos(x);
  int16_t yq = float_to_q15_pos(y);
  return ((uint32_t)(uint16_t)xq) | (((uint32_t)(uint16_t)yq) << 16);
}

static inline float q30_to_float(uint32_t q30) {
  return (float)q30 / 1073741824.0f;
}

// ===================== EDGE BRAM packing =====================
// [7:0]=a, [15:8]=b, [23:16]=age, [24]=active
static inline uint32_t pack_edge(uint8_t a, uint8_t b, uint8_t age, bool active) {
  uint32_t v = (uint32_t)a | ((uint32_t)b << 8) | ((uint32_t)age << 16);
  if (active) v |= (1u << 24);
  return v;
}

static inline void unpack_edge(uint32_t v, uint8_t *a, uint8_t *b, uint8_t *age, bool *active) {
  *a = (uint8_t)(v & 0xFFu);
  *b = (uint8_t)((v >> 8) & 0xFFu);
  *age = (uint8_t)((v >> 16) & 0xFFu);
  *active = ((v >> 24) & 0x1u) ? true : false;
}

static inline uint32_t edge_read_word(int i) {
  return NEORV32_CFS->REG[CFS_EDGE_BASE + i];
}

static inline void edge_write_word(int i, uint32_t w) {
  NEORV32_CFS->REG[CFS_EDGE_BASE + i] = w;
}

static inline void edges_clear_all(void) {
  for (int i = 0; i < MAX_EDGES; i++) edge_write_word(i, 0u);
}

// return edge index if exists else -1 (EDGE in BRAM)
static int findEdge(int a, int b) {
  for (int i = 0; i < MAX_EDGES; i++) {
    uint8_t ea, eb, age;
    bool active;
    unpack_edge(edge_read_word(i), &ea, &eb, &age, &active);
    if (!active) continue;
    if ((ea == (uint8_t)a && eb == (uint8_t)b) ||
        (ea == (uint8_t)b && eb == (uint8_t)a)) {
      return i;
    }
  }
  return -1;
}

static void connectOrResetEdge(int a, int b) {
  int ei = findEdge(a, b);
  if (ei >= 0) {
    edge_write_word(ei, pack_edge((uint8_t)a, (uint8_t)b, 0, true));
    return;
  }

  for (int i = 0; i < MAX_EDGES; i++) {
    uint8_t ea, eb, age;
    bool active;
    unpack_edge(edge_read_word(i), &ea, &eb, &age, &active);
    if (!active) {
      edge_write_word(i, pack_edge((uint8_t)a, (uint8_t)b, 0, true));
      return;
    }
  }
}

static void removeEdgePair(int a, int b) {
  int ei = findEdge(a, b);
  if (ei >= 0) {
    uint8_t ea, eb, age;
    bool active;
    unpack_edge(edge_read_word(ei), &ea, &eb, &age, &active);
    (void)active;
    edge_write_word(ei, pack_edge(ea, eb, age, false));
  }
}

static void ageEdgesFromWinner(int w) {
  for (int i = 0; i < MAX_EDGES; i++) {
    uint8_t a, b, age;
    bool active;
    unpack_edge(edge_read_word(i), &a, &b, &age, &active);
    if (!active) continue;
    if ((int)a == w || (int)b == w) {
      edge_write_word(i, pack_edge(a, b, (uint8_t)(age + 1u), true));
    }
  }
}

static void deleteOldEdges(void) {
  for (int i = 0; i < MAX_EDGES; i++) {
    uint8_t a, b, age;
    bool active;
    unpack_edge(edge_read_word(i), &a, &b, &age, &active);
    if (!active) continue;
    if (age > (uint8_t)GNG_A_MAX) {
      edge_write_word(i, pack_edge(a, b, age, false));
    }
  }
}

static void pruneIsolatedNodes(void) {
  for (int i = 0; i < MAX_NODES; i++) {
    if (!nodes[i].active) continue;

    bool has_edge = false;
    for (int e = 0; e < MAX_EDGES; e++) {
      uint8_t a, b, age;
      bool active;
      unpack_edge(edge_read_word(e), &a, &b, &age, &active);
      if (!active) continue;
      if ((int)a == i || (int)b == i) { has_edge = true; break; }
    }
    if (!has_edge) nodes[i].active = false;
  }
}

// Fritzke insertion rule
// Fritzke insertion rule (FIXED to match Fritzke 1995)
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
    uint8_t a, b, age; bool active;
    unpack_edge(edge_read_word(i), &a, &b, &age, &active);
    if (!active) continue;

    int nb = -1;
    if ((int)a == q) nb = (int)b;
    else if ((int)b == q) nb = (int)a;

    if (nb >= 0 && nb < MAX_NODES && nodes[nb].active && nodes[nb].error > maxErr) {
      maxErr = nodes[nb].error;
      f = nb;
    }
  }
  if (f < 0) return -1;

  int r = findFreeNode();
  if (r < 0) return -1;

  // new unit position
  nodes[r].x = 0.5f * (nodes[q].x + nodes[f].x);
  nodes[r].y = 0.5f * (nodes[q].y + nodes[f].y);
  nodes[r].active = true;

  // topology update
  removeEdgePair(q, f);
  connectOrResetEdge(q, r);
  connectOrResetEdge(r, f);

  // ---- FIX: error update order (Fritzke 1995) ----
  nodes[q].error *= GNG_ALPHA;
  nodes[f].error *= GNG_ALPHA;
  nodes[r].error  = nodes[q].error;   // r gets the NEW value of q

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
    uint8_t a, b, age;
    bool active;
    unpack_edge(edge_read_word(i), &a, &b, &age, &active);
    if (!active) continue;
    payload[p++] = a;
    payload[p++] = b;
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

// ===================== CFS helpers =====================
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

  const uint32_t TIMEOUT = 20000u;
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

// dataset upload optional (kalau VHDL masih punya DATA_BASE)
static inline uint32_t pack_xy_i16(int16_t xi, int16_t yi) {
  return ((uint32_t)(uint16_t)xi) | (((uint32_t)(uint16_t)yi) << 16);
}

static bool cfs_edge_sanity_check(void) {
  // write test to EDGE[0], read back
  uint32_t w = pack_edge(7, 9, 3, true);
  edge_write_word(0, w);
  uint32_t r = edge_read_word(0);
  return (r == w);
}

static void cfs_upload_dataset_and_settings_once(void) {
  const int n = (dataCount < MAXPTS) ? dataCount : MAXPTS;

  NEORV32_CFS->REG[CFS_REG_CTRL]  = CFS_CTRL_CLEAR;
  NEORV32_CFS->REG[CFS_REG_COUNT] = (uint32_t)n;

  for (int i = 0; i < n; i++) {
    int16_t xi = (int16_t)(dataX[i] * 1000.0f);
    int16_t yi = (int16_t)(dataY[i] * 1000.0f);
    NEORV32_CFS->REG[CFS_DATA_BASE + i] = pack_xy_i16(xi, yi);
  }

  cfs_write_settings();
  cfs_sync_nodes_full();

  edges_clear_all();

  // IMPORTANT: create initial edge 0-1 (prevent prune on first step if desired)
  // connectOrResetEdge(0, 1);
}

// ---------------- GNG step ----------------
static void trainOneStep(float x, float y) {
  int   s1 = -1, s2 = -1;
  float d1 = 1e30f;

  if (!cfs_find_winners(x, y, &s1, &s2, &d1)) {
    // fallback SW search (still ok)
    s1 = -1; s2 = -1; d1 = 1e30f;
    float d2 = 1e30f;
    for (int i = 0; i < MAX_NODES; i++) {
      if (!nodes[i].active) continue;
      float d = dist2(x, y, nodes[i].x, nodes[i].y);
      if (d < d1) { d2 = d1; s2 = s1; d1 = d; s1 = i; }
      else if (d < d2) { d2 = d; s2 = i; }
    }
  }

  if (s1 < 0 || s2 < 0) return;

  ageEdgesFromWinner(s1);

  nodes[s1].error += d1;

  nodes[s1].x += GNG_EPSILON_B * (x - nodes[s1].x);
  nodes[s1].y += GNG_EPSILON_B * (y - nodes[s1].y);
  cfs_write_one_node(s1);

  // move neighbors: scan edges in BRAM
  for (int i = 0; i < MAX_EDGES; i++) {
    uint8_t a, b, age;
    bool active;
    unpack_edge(edge_read_word(i), &a, &b, &age, &active);
    if (!active) continue;

    if ((int)a == s1 || (int)b == s1) {
      int nb = ((int)a == s1) ? (int)b : (int)a;
      if (nb >= 0 && nb < MAX_NODES && nodes[nb].active) {
        nodes[nb].x += GNG_EPSILON_N * (x - nodes[nb].x);
        nodes[nb].y += GNG_EPSILON_N * (y - nodes[nb].y);
        cfs_write_one_node(nb);
      }
    }
  }

  connectOrResetEdge(s1, s2);

  deleteOldEdges();
  pruneIsolatedNodes();

  stepCount++;

  if ((stepCount % GNG_LAMBDA) == 0) {
    (void)insertNode();
    pruneIsolatedNodes();
    cfs_sync_nodes_full();
  }

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

  dataCount = 0;
  dataDone  = false;
  running   = false;
  stepCount = 0;
  dataIndex = 0;
  frame_id  = 0;

  nodes[0].x = 0.2f; nodes[0].y = 0.2f; nodes[0].active = true;
  nodes[1].x = 0.8f; nodes[1].y = 0.8f; nodes[1].active = true;
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

  bool preprocessed = false;

  while (1) {
    readSerial();

    if (dataDone && !preprocessed) {
      cfs_upload_dataset_and_settings_once();

      if (!cfs_edge_sanity_check()) {
        neorv32_uart0_puts("ERROR: EDGE BRAM not working (check VHDL EDGE_BASE/edge_mem)\n");
        while (1) { }
      }

      neorv32_uart0_puts("CFS init done\n");
      preprocessed = true;

      // AUTO-RUN so you don't depend on Processing CMD_RUN
      running = true;
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
