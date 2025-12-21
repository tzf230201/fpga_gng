import processing.serial.*;
import java.util.ArrayList;

// ===============================
// Serial config
// ===============================
Serial myPort;
final String PORT_NAME = "COM1";   // <-- GANTI sesuai Serial.list()
final int    BAUD      = 1000000;

// ===============================
// Two-moons dataset options
// ===============================
final int     MOONS_N            = 100;
final boolean MOONS_RANDOM_ANGLE = false;
final int     MOONS_SEED         = 1234;
final float   MOONS_NOISE_STD    = 0.06;
final boolean MOONS_SHUFFLE      = true;
final boolean MOONS_NORMALIZE01  = true;

// ===============================
// Dataset upload state
// ===============================
float[][] data;
int idx = 0;
boolean uploaded = false;
boolean running  = false;

// debug strings
String lastTX   = "";
String lastRX   = "";
String lastTXT  = "";   // last ASCII line from NEORV32

// counts from payload
int gngNodeCount = 0;
int gngEdgeCount = 0;
int lastFrameNodes = -1;
int lastFrameEdges = -1;

// ===============================
// UART Binary protocol (match main.c)
// Frame: FF FF CMD LEN PAYLOAD CHK, CHK = ~(CMD + LEN + sum(payload))
// ===============================
final int UART_HDR       = 0xFF;

final int CMD_DATA_BATCH = 0x01;
final int CMD_DONE       = 0x02;
final int CMD_RUN        = 0x03;

final int CMD_GNG_NODES  = 0x10;
final int CMD_GNG_EDGES  = 0x11;

// RX state machine
final int RX_WAIT_H1      = 0;
final int RX_WAIT_H2      = 1;
final int RX_WAIT_CMD     = 2;
final int RX_WAIT_LEN     = 3;
final int RX_WAIT_PAYLOAD = 4;
final int RX_WAIT_CHK     = 5;

int    rxState    = RX_WAIT_H1;
int    rxCmd      = 0;
int    rxLen      = 0;
int    rxIndex    = 0;
int    rxChecksum = 0;
byte[] rxPayload  = new byte[512];

// ===============================
// ASCII capture (for printf/puts)
// ===============================
StringBuilder asciiBuf = new StringBuilder(256);

// ===============================
// HW GNG structures (from NEORV32 frames)
// ===============================
class NodeHW {
  float x, y;
  boolean active = false;
}
class EdgeHW {
  int a, b;
  boolean active = false;
}
ArrayList<NodeHW> gngNodes = new ArrayList<NodeHW>();
ArrayList<EdgeHW> gngEdges = new ArrayList<EdgeHW>();

// =====================================================================
// ========================== PC GNG (Processing) =======================
// =====================================================================

// ---- match your firmware parameters ----
final int   MAX_NODES = 40;
final int   MAX_EDGES = 80;

final int   GNG_LAMBDA      = 100;
final float GNG_EPSILON_B   = 0.3f;
final float GNG_EPSILON_N   = 0.001f;
final float GNG_ALPHA       = 0.5f;
final int   GNG_A_MAX       = 50;
final float GNG_D           = 0.995f;

// how many training steps per frame (PC)
final int   PC_STEPS_PER_DRAW = 2000;   // naikkan kalau PC kuat
final int   PC_DRAW_EVERY_N   = 5;      // redraw overlay tiap N step

boolean pcEnabled = true;   // overlay PC GNG
boolean pcRunning = false;  // mulai setelah RUN dikirim
int     pcStepCount = 0;
int     pcDataIndex = 0;

// perf measurement
float pcStepsPerSec = 0;
int   pcLastStepPerf = 0;
int   pcLastMsPerf   = 0;

// PC nodes/edges
class NodePC {
  float x, y;
  float error;
  boolean active;
}
class EdgePC {
  int a, b;
  int age;
  boolean active;
}
NodePC[] pcNodes = new NodePC[MAX_NODES];
EdgePC[] pcEdges = new EdgePC[MAX_EDGES];

float dist2(float x1, float y1, float x2, float y2) {
  float dx = x1 - x2;
  float dy = y1 - y2;
  return dx*dx + dy*dy;
}

void initPCGNG() {
  for (int i = 0; i < MAX_NODES; i++) {
    pcNodes[i] = new NodePC();
    pcNodes[i].x = 0;
    pcNodes[i].y = 0;
    pcNodes[i].error = 0;
    pcNodes[i].active = false;
  }
  for (int i = 0; i < MAX_EDGES; i++) {
    pcEdges[i] = new EdgePC();
    pcEdges[i].a = 0;
    pcEdges[i].b = 0;
    pcEdges[i].age = 0;
    pcEdges[i].active = false;
  }

  // same init as firmware
  pcNodes[0].x = 0.2f; pcNodes[0].y = 0.2f; pcNodes[0].active = true;
  pcNodes[1].x = 0.8f; pcNodes[1].y = 0.8f; pcNodes[1].active = true;

  pcStepCount = 0;
  pcDataIndex = 0;

  pcLastStepPerf = 0;
  pcLastMsPerf   = millis();
  pcStepsPerSec  = 0;
}

int findFreeNodePC() {
  for (int i = 0; i < MAX_NODES; i++) {
    if (!pcNodes[i].active) return i;
  }
  return -1;
}

// returns edge index if exists else -1
int findEdgePC(int a, int b) {
  int aa = min(a, b);
  int bb = max(a, b);
  for (int i = 0; i < MAX_EDGES; i++) {
    EdgePC e = pcEdges[i];
    if (!e.active) continue;
    int ea = min(e.a, e.b);
    int eb = max(e.a, e.b);
    if (ea == aa && eb == bb) return i;
  }
  return -1;
}

void connectOrResetEdgePC(int a, int b) {
  int ei = findEdgePC(a, b);
  if (ei >= 0) {
    pcEdges[ei].a = a;
    pcEdges[ei].b = b;
    pcEdges[ei].age = 0;
    pcEdges[ei].active = true;
    return;
  }
  for (int i = 0; i < MAX_EDGES; i++) {
    if (!pcEdges[i].active) {
      pcEdges[i].a = a;
      pcEdges[i].b = b;
      pcEdges[i].age = 0;
      pcEdges[i].active = true;
      return;
    }
  }
}

void removeEdgePairPC(int a, int b) {
  int ei = findEdgePC(a, b);
  if (ei >= 0) pcEdges[ei].active = false;
}

void ageEdgesFromWinnerPC(int w) {
  for (int i = 0; i < MAX_EDGES; i++) {
    EdgePC e = pcEdges[i];
    if (!e.active) continue;
    if (e.a == w || e.b == w) e.age++;
  }
}

void deleteOldEdgesPC() {
  for (int i = 0; i < MAX_EDGES; i++) {
    EdgePC e = pcEdges[i];
    if (!e.active) continue;
    if (e.age > GNG_A_MAX) e.active = false;
  }
}

void pruneIsolatedNodesPC() {
  for (int i = 0; i < MAX_NODES; i++) {
    if (!pcNodes[i].active) continue;
    boolean hasEdge = false;
    for (int e = 0; e < MAX_EDGES; e++) {
      EdgePC ed = pcEdges[e];
      if (!ed.active) continue;
      if (ed.a == i || ed.b == i) { hasEdge = true; break; }
    }
    if (!hasEdge) pcNodes[i].active = false;
  }
}

// Fritzke insertion rule (match your firmware FIX)
int insertNodePC() {
  int q = -1;
  float maxErr = -1;
  for (int i = 0; i < MAX_NODES; i++) {
    if (pcNodes[i].active && pcNodes[i].error > maxErr) {
      maxErr = pcNodes[i].error;
      q = i;
    }
  }
  if (q < 0) return -1;

  int f = -1;
  maxErr = -1;
  for (int i = 0; i < MAX_EDGES; i++) {
    EdgePC e = pcEdges[i];
    if (!e.active) continue;

    int nb = -1;
    if (e.a == q) nb = e.b;
    else if (e.b == q) nb = e.a;

    if (nb >= 0 && nb < MAX_NODES && pcNodes[nb].active && pcNodes[nb].error > maxErr) {
      maxErr = pcNodes[nb].error;
      f = nb;
    }
  }
  if (f < 0) return -1;

  int r = findFreeNodePC();
  if (r < 0) return -1;

  pcNodes[r].x = 0.5f * (pcNodes[q].x + pcNodes[f].x);
  pcNodes[r].y = 0.5f * (pcNodes[q].y + pcNodes[f].y);
  pcNodes[r].active = true;

  removeEdgePairPC(q, f);
  connectOrResetEdgePC(q, r);
  connectOrResetEdgePC(r, f);

  // IMPORTANT: order matches your firmware
  pcNodes[q].error *= GNG_ALPHA;
  pcNodes[f].error *= GNG_ALPHA;
  pcNodes[r].error  = pcNodes[q].error;

  return r;
}

void trainOneStepPC(float x, float y) {
  int s1 = -1, s2 = -1;
  float d1 = 1e30f;
  float d2 = 1e30f;

  for (int i = 0; i < MAX_NODES; i++) {
    if (!pcNodes[i].active) continue;
    float d = dist2(x, y, pcNodes[i].x, pcNodes[i].y);
    if (d < d1) { d2 = d1; s2 = s1; d1 = d; s1 = i; }
    else if (d < d2) { d2 = d; s2 = i; }
  }
  if (s1 < 0 || s2 < 0) return;

  ageEdgesFromWinnerPC(s1);

  pcNodes[s1].error += d1;

  // move winner
  pcNodes[s1].x += GNG_EPSILON_B * (x - pcNodes[s1].x);
  pcNodes[s1].y += GNG_EPSILON_B * (y - pcNodes[s1].y);

  // move neighbors (scan edges)
  for (int i = 0; i < MAX_EDGES; i++) {
    EdgePC e = pcEdges[i];
    if (!e.active) continue;
    if (e.a == s1 || e.b == s1) {
      int nb = (e.a == s1) ? e.b : e.a;
      if (nb >= 0 && nb < MAX_NODES && pcNodes[nb].active) {
        pcNodes[nb].x += GNG_EPSILON_N * (x - pcNodes[nb].x);
        pcNodes[nb].y += GNG_EPSILON_N * (y - pcNodes[nb].y);
      }
    }
  }

  connectOrResetEdgePC(s1, s2);

  deleteOldEdgesPC();
  pruneIsolatedNodesPC();

  pcStepCount++;

  if ((pcStepCount % GNG_LAMBDA) == 0) {
    insertNodePC();
    pruneIsolatedNodesPC();
  }

  for (int i = 0; i < MAX_NODES; i++) {
    if (pcNodes[i].active) pcNodes[i].error *= GNG_D;
  }
}

int countActiveNodesPC() {
  int c = 0;
  for (int i = 0; i < MAX_NODES; i++) if (pcNodes[i].active) c++;
  return c;
}
int countActiveEdgesPC() {
  int c = 0;
  for (int i = 0; i < MAX_EDGES; i++) if (pcEdges[i].active) c++;
  return c;
}

void runPCGNGSteps() {
  if (!pcEnabled || !pcRunning) return;
  if (data == null || data.length == 0) return;

  for (int k = 0; k < PC_STEPS_PER_DRAW; k++) {
    float x = data[pcDataIndex][0];
    float y = data[pcDataIndex][1];
    pcDataIndex++;
    if (pcDataIndex >= data.length) pcDataIndex = 0;
    trainOneStepPC(x, y);
  }

  // update perf roughly 4x per second
  int now = millis();
  int dt = now - pcLastMsPerf;
  if (dt >= 250) {
    int ds = pcStepCount - pcLastStepPerf;
    pcStepsPerSec = (dt > 0) ? (1000.0f * ds / dt) : 0;
    pcLastMsPerf = now;
    pcLastStepPerf = pcStepCount;
  }
}

// =====================================================================
// =============================== Setup / Draw ==========================
// =====================================================================

void setup() {
  size(1000, 600);
  surface.setTitle("Two Moons → NEORV32 GNG + PC GNG (overlay)");

  println("Available serial ports:");
  println(Serial.list());

  myPort = new Serial(this, PORT_NAME, BAUD);
  myPort.clear();
  delay(1200);

  data = generateMoons(
    MOONS_N,
    MOONS_RANDOM_ANGLE,
    MOONS_NOISE_STD,
    MOONS_SEED,
    MOONS_SHUFFLE,
    MOONS_NORMALIZE01
  );

  // init PC GNG now; we start running after RUN
  initPCGNG();

  println("Uploading dataset...");
}

void draw() {
  background(30);

  // ALWAYS read serial (for READY, frames, etc.)
  processSerial();

  // PC GNG runs in parallel after RUN
  if (uploaded && running) {
    pcRunning = true;
    runPCGNGSteps();
  }

  drawDataset();
  drawGNG();    // draws HW + overlay PC
  drawDebug();

  if (!uploaded) {
    uploadDataset();
  } else if (!running) {
    sendRunCommand();
  }
}

void keyPressed() {
  if (key == 'p' || key == 'P') {
    pcEnabled = !pcEnabled;
  }
  if (key == 'r' || key == 'R') {
    // reset PC side only (NEORV32 reset perlu command khusus kalau mau)
    initPCGNG();
  }
}

// ===============================
// Upload dataset in batches
// ===============================
void uploadDataset() {
  final int BATCH_POINTS = 20;

  if (idx >= data.length) {
    sendFrame((byte)CMD_DONE, new byte[0]);
    lastTX = "DONE";
    uploaded = true;
    println("[TX] DONE");
    return;
  }

  int remaining = data.length - idx;
  int count = min(BATCH_POINTS, remaining);

  // payload: [count] + count*(xi,yi) where xi,yi are int16 LE scaled 1000
  byte[] payload = new byte[1 + count * 4];
  payload[0] = (byte)count;

  int p = 1;
  for (int i = 0; i < count; i++) {
    float x = data[idx + i][0];
    float y = data[idx + i][1];

    short xi = (short)(x * 1000.0);
    short yi = (short)(y * 1000.0);

    payload[p++] = (byte)(xi & 0xFF);
    payload[p++] = (byte)((xi >> 8) & 0xFF);
    payload[p++] = (byte)(yi & 0xFF);
    payload[p++] = (byte)((yi >> 8) & 0xFF);
  }

  sendFrame((byte)CMD_DATA_BATCH, payload);
  lastTX = "DATA_BATCH count=" + count + " idx=" + idx;
  println("[TX] " + lastTX);

  idx += count;
}

void sendRunCommand() {
  sendFrame((byte)CMD_RUN, new byte[0]);
  lastTX = "RUN";
  running = true;
  println("[TX] RUN");
}

// ===============================
// Unified serial processing:
// - parse binary frames FF FF ...
// - also capture ASCII lines from printf/puts
// ===============================
void processSerial() {
  while (myPort.available() > 0) {
    int bi = myPort.read();
    if (bi == -1) return;
    int b = bi & 0xFF;

    // If we're idle and this isn't a frame header, treat as ASCII text
    if (rxState == RX_WAIT_H1 && b != UART_HDR) {
      handleAsciiByte(b);
      continue;
    }

    // Otherwise continue binary frame parser
    switch (rxState) {
      case RX_WAIT_H1:
        if (b == UART_HDR) rxState = RX_WAIT_H2;
        break;

      case RX_WAIT_H2:
        if (b == UART_HDR) rxState = RX_WAIT_CMD;
        else rxState = RX_WAIT_H1;
        break;

      case RX_WAIT_CMD:
        rxCmd = b;
        rxChecksum = b & 0xFF;
        rxState = RX_WAIT_LEN;
        break;

      case RX_WAIT_LEN:
        rxLen = b;
        rxChecksum = (rxChecksum + (b & 0xFF)) & 0xFF;
        rxIndex = 0;
        if (rxLen == 0) rxState = RX_WAIT_CHK;
        else if (rxLen > rxPayload.length) rxState = RX_WAIT_H1;
        else rxState = RX_WAIT_PAYLOAD;
        break;

      case RX_WAIT_PAYLOAD:
        rxPayload[rxIndex++] = (byte)b;
        rxChecksum = (rxChecksum + (b & 0xFF)) & 0xFF;
        if (rxIndex >= rxLen) rxState = RX_WAIT_CHK;
        break;

      case RX_WAIT_CHK: {
        int expected = (~rxChecksum) & 0xFF;
        if (b == expected) {
          handleFrame(rxCmd, rxPayload, rxLen);
        }
        rxState = RX_WAIT_H1;
        break;
      }

      default:
        rxState = RX_WAIT_H1;
        break;
    }
  }
}

void handleAsciiByte(int b) {
  if (b == '\r') return;

  if (b == '\n') {
    if (asciiBuf.length() > 0) {
      String line = asciiBuf.toString();
      asciiBuf.setLength(0);
      lastTXT = line;
      println("[NEORV32] " + line);
    }
    return;
  }

  if ((b >= 32 && b <= 126) || b == '\t') {
    if (asciiBuf.length() < 400) asciiBuf.append((char)b);
  }
}

// ===============================
// Handle frames from NEORV32
// ===============================
void handleFrame(int cmd, byte[] payload, int len) {

  if (cmd == CMD_GNG_NODES) {
    if (len < 2) return;

    int frameId   = payload[0] & 0xFF;
    int nodeCount = payload[1] & 0xFF;
    gngNodeCount  = nodeCount;

    int pos = 2;
    gngNodes.clear();

    for (int i = 0; i < nodeCount; i++) {
      if (pos + 5 > len) break;

      int idxNode = payload[pos++] & 0xFF;

      int xi = (payload[pos++] & 0xFF) | ((payload[pos++] & 0xFF) << 8);
      int yi = (payload[pos++] & 0xFF) | ((payload[pos++] & 0xFF) << 8);

      if (xi >= 32768) xi -= 65536;
      if (yi >= 32768) yi -= 65536;

      while (gngNodes.size() <= idxNode) gngNodes.add(new NodeHW());
      NodeHW n = gngNodes.get(idxNode);
      n.x = xi / 1000.0;
      n.y = yi / 1000.0;
      n.active = true;
    }

    lastFrameNodes = frameId;
    lastRX = "NODES frame=" + frameId + " n=" + nodeCount;
  }

  else if (cmd == CMD_GNG_EDGES) {
    if (len < 2) return;

    int frameId   = payload[0] & 0xFF;
    int edgeCount = payload[1] & 0xFF;
    gngEdgeCount  = edgeCount;

    int pos = 2;
    gngEdges.clear();

    for (int i = 0; i < edgeCount; i++) {
      if (pos + 2 > len) break;
      EdgeHW e = new EdgeHW();
      e.a = payload[pos++] & 0xFF;
      e.b = payload[pos++] & 0xFF;
      e.active = true;
      gngEdges.add(e);
    }

    lastFrameEdges = frameId;
    lastRX = "EDGES frame=" + frameId + " e=" + edgeCount;
  }
}

// ===============================
// Send frame helper
// ===============================
void sendFrame(byte cmd, byte[] payload) {
  int len = (payload == null) ? 0 : payload.length;
  int sum = (cmd & 0xFF) + (len & 0xFF);
  if (payload != null) {
    for (int i = 0; i < payload.length; i++) sum += payload[i] & 0xFF;
  }
  int chk = (~sum) & 0xFF;

  myPort.write(UART_HDR);
  myPort.write(UART_HDR);
  myPort.write(cmd & 0xFF);
  myPort.write(len & 0xFF);
  if (payload != null) myPort.write(payload);
  myPort.write(chk);
}

// ===============================
// Draw routines
// ===============================
void drawDataset() {
  fill(255);
  noStroke();

  for (int i = 0; i < data.length; i++) {
    float x = data[i][0] * 400 + 50;
    float y = data[i][1] * 400 + 50;
    ellipse(x, y, 6, 6);
  }

  fill(200);
  textSize(16);
  text("Two Moons (" + MOONS_N + " pts)  noise=" + nf(MOONS_NOISE_STD, 1, 3) +
       "  seed=" + MOONS_SEED +
       "  randomAngle=" + MOONS_RANDOM_ANGLE, 50, 30);
}

void drawGNG() {
  pushMatrix();
  translate(500, 0);

  // ---------------- HW (NEORV32) ----------------
  stroke(255);
  strokeWeight(2);
  for (EdgeHW e : gngEdges) {
    if (!e.active) continue;
    if (e.a < 0 || e.a >= gngNodes.size()) continue;
    if (e.b < 0 || e.b >= gngNodes.size()) continue;
    NodeHW a = gngNodes.get(e.a);
    NodeHW b = gngNodes.get(e.b);
    if (!a.active || !b.active) continue;

    line(a.x * 400 + 50, a.y * 400 + 50,
         b.x * 400 + 50, b.y * 400 + 50);
  }

  fill(0, 180, 255);
  noStroke();
  for (NodeHW n : gngNodes) {
    if (n.active) ellipse(n.x * 400 + 50, n.y * 400 + 50, 12, 12);
  }

  // ---------------- PC (Processing) overlay ----------------
  if (pcEnabled) {
    // edges PC
    stroke(255, 80, 200);
    strokeWeight(2);
    for (int i = 0; i < MAX_EDGES; i++) {
      EdgePC e = pcEdges[i];
      if (!e.active) continue;
      if (e.a < 0 || e.a >= MAX_NODES) continue;
      if (e.b < 0 || e.b >= MAX_NODES) continue;
      if (!pcNodes[e.a].active || !pcNodes[e.b].active) continue;

      line(pcNodes[e.a].x * 400 + 50, pcNodes[e.a].y * 400 + 50,
           pcNodes[e.b].x * 400 + 50, pcNodes[e.b].y * 400 + 50);
    }

    // nodes PC
    noStroke();
    fill(255, 80, 200);
    for (int i = 0; i < MAX_NODES; i++) {
      if (!pcNodes[i].active) continue;
      ellipse(pcNodes[i].x * 400 + 50, pcNodes[i].y * 400 + 50, 9, 9);
    }
  }

  // legend
  fill(200);
  text("Right panel overlay:", 50, 30);
  fill(0,180,255); text("HW (NEORV32)", 50, 50);
  fill(255,80,200); text("PC (Processing)  [P toggle]", 50, 70);

  popMatrix();
}

void drawDebug() {
  fill(0, 0, 0, 180);
  noStroke();
  rect(0, height - 120, width, 120);

  fill(0,255,0);
  text("TX: " + lastTX, 10, height - 90);

  fill(255,200,0);
  text("RX: " + lastRX, 10, height - 70);

  fill(180,180,255);
  text("TXT: " + lastTXT, 10, height - 50);

  fill(200);
  text("HW Nodes=" + gngNodeCount + "  HW Edges=" + gngEdgeCount +
       "  FrameN=" + lastFrameNodes + "  FrameE=" + lastFrameEdges,
       10, height - 30);

  fill(255,80,200);
  text("PC steps=" + pcStepCount +
       "  PC steps/sec≈" + nf(pcStepsPerSec, 1, 1) +
       "  PC active nodes=" + countActiveNodesPC() +
       "  PC active edges=" + countActiveEdgesPC() +
       "  (R=reset PC)",
       10, height - 10);
}

// ===============================
// Two-moons generator
// ===============================
float[][] generateMoons(int N, boolean randomAngle, float noiseStd, int seed,
                        boolean shuffle, boolean normalize01) {
  float[][] arr = new float[N][2];

  if (seed >= 0) randomSeed(seed);
  else randomSeed((int)millis());

  for (int i = 0; i < N/2; i++) {
    float t = randomAngle ? random(PI) : map(i, 0, (N/2) - 1, 0, PI);
    arr[i][0] = cos(t);
    arr[i][1] = sin(t);
  }

  for (int i = N/2; i < N; i++) {
    int j = i - N/2;
    float t = randomAngle ? random(PI) : map(j, 0, (N/2) - 1, 0, PI);
    arr[i][0] = 1 - cos(t);
    arr[i][1] = -sin(t) + 0.5;
  }

  if (noiseStd > 0.0) {
    for (int i = 0; i < N; i++) {
      arr[i][0] += (float)randomGaussian() * noiseStd;
      arr[i][1] += (float)randomGaussian() * noiseStd;
    }
  }

  if (normalize01) {
    float minx=999, maxx=-999, miny=999, maxy=-999;
    for (int i = 0; i < N; i++) {
      float x = arr[i][0], y = arr[i][1];
      if (x < minx) minx = x;
      if (x > maxx) maxx = x;
      if (y < miny) miny = y;
      if (y > maxy) maxy = y;
    }
    float dx = maxx - minx; if (dx < 1e-9) dx = 1.0;
    float dy = maxy - miny; if (dy < 1e-9) dy = 1.0;

    for (int i = 0; i < N; i++) {
      arr[i][0] = (arr[i][0] - minx) / dx;
      arr[i][1] = (arr[i][1] - miny) / dy;
    }
  }

  if (shuffle) {
    for (int i = N - 1; i > 0; i--) {
      int j = (int)random(i + 1);
      float tx = arr[i][0], ty = arr[i][1];
      arr[i][0] = arr[j][0]; arr[i][1] = arr[j][1];
      arr[j][0] = tx;        arr[j][1] = ty;
    }
  }

  return arr;
}
