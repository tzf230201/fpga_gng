import java.util.Arrays;
import java.io.File;
import java.io.PrintWriter;

// IMPORTANT: avoid "Serial ambiguous"
import processing.serial.*;

// ===============================
// Window / layout
// ===============================
final int WIN_W = 1000;
final int WIN_H = 1000;
final int DBG_H = 140;

// ===============================
// Serial config
// ===============================
processing.serial.Serial myPort;
final String PORT_NAME = "COM1";   // <-- GANTI sesuai Serial.list()
final int    BAUD      = 1000000;

// ===============================
// Match main.c
// ===============================
final int MAX_NODES = 20;
final int CPU_HZ    = 27000000; // must match main.c (for microsecond conversion)

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
String lastTXT  = "";

// counts
int gngNodeCount = 0;
int gngEdgeCount = 0;
int lastFrameNodes = -1;
int lastFrameEdges = -1;
int lastFrameProf  = -1;

// ===============================
// TIMER (ms)
// ===============================
long tStartMs    = 0;
long tRunStartMs = -1;

// ===============================
// UART Binary protocol
// Frame: FF FF CMD LEN PAYLOAD CHK, CHK = ~(CMD + LEN + sum(payload))
// ===============================
final int UART_HDR       = 0xFF;

final int CMD_DATA_BATCH = 0x01;
final int CMD_DONE       = 0x02;
final int CMD_RUN        = 0x03;

final int CMD_GNG_NODES  = 0x10;
final int CMD_GNG_EDGES  = 0x11;
final int CMD_PROF       = 0x12;

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

// ASCII capture
StringBuilder asciiBuf = new StringBuilder(256);

// ===============================
// GNG state (fixed arrays)
// ===============================
static class Node {
  float x, y;
  boolean active;
}
static class Edge {
  int a, b;
  boolean active;
}

Node[] nodes = new Node[MAX_NODES];
boolean[][] adj = new boolean[MAX_NODES][MAX_NODES];
int[] deg = new int[MAX_NODES];

Edge[] edges = new Edge[512];
int edgesN = 0;

// PROF values (cycles)
static class Prof {
  int cyc_total, cyc_winner, cyc_move_w, cyc_nb, cyc_connect, cyc_delete, cyc_prune, cyc_insert, cyc_renorm;
  int stepCount;
}
Prof prof = new Prof();

// ===============================
// Logging / Saving
// ===============================
boolean logEnabled = true;
boolean autoSavePng = false;
PrintWriter csv;
String csvPath;
String capDir;

// frame complete tracking
int lastCompleteFrame = -1;

// ===============================
// Processing lifecycle
// ===============================
void settings() {
  size(WIN_W, WIN_H);  // must be here in some Processing versions
}

void setup() {
  surface.setTitle("GNG Eval Logger (paper style)");

  for (int i=0;i<MAX_NODES;i++) nodes[i] = new Node();

  tStartMs = millis();

  println("Available serial ports:");
  println(Serial.list());

  myPort = new processing.serial.Serial(this, PORT_NAME, BAUD);
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

  // output dirs
  capDir = sketchPath("capture");
  new File(capDir).mkdirs();

  String logDir = sketchPath("logs");
  new File(logDir).mkdirs();
  csvPath = logDir + File.separator + "gng_eval_" + year() + nf(month(),2) + nf(day(),2) + "_" + nf(hour(),2) + nf(minute(),2) + nf(second(),2) + ".csv";

  if (logEnabled) {
    csv = createWriter(csvPath);
    csv.println("# GNG Eval Logger");
    csv.println("# PORT=" + PORT_NAME + ", BAUD=" + BAUD);
    csv.println("# MOONS_N=" + MOONS_N + ", SEED=" + MOONS_SEED + ", NOISE=" + MOONS_NOISE_STD +
                ", RANDOM_ANGLE=" + MOONS_RANDOM_ANGLE + ", SHUFFLE=" + MOONS_SHUFFLE + ", NORM01=" + MOONS_NORMALIZE01);
    csv.println("run_ms,frame_id,nodes,edges,QE,TE,isolated,avg_degree,cyc_total,us_total,cyc_winner,cyc_nb,cyc_insert");
    csv.flush();
  }

  println("Uploading dataset...");
  println("CSV: " + csvPath);
  println("Capture dir: " + capDir);
}

void draw() {
  background(255);

  processSerial();

  if (!uploaded) uploadDataset();
  else if (!running) sendRunCommand();

  // plot area (keep it square inside the upper region)
  renderPlot(g, 0, 0, width, height - DBG_H, true);

  drawDebugPanel();
}

void keyPressed() {
  if (key == 's' || key == 'S') savePlotPNG(lastCompleteFrame >= 0 ? lastCompleteFrame : 0);
  if (key == 'p' || key == 'P') { autoSavePng = !autoSavePng; println("autoSavePng=" + autoSavePng); }
  if (key == 'l' || key == 'L') { logEnabled = !logEnabled; println("logEnabled=" + logEnabled); }
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
  idx += count;
}

void sendRunCommand() {
  sendFrame((byte)CMD_RUN, new byte[0]);
  lastTX = "RUN";
  running = true;
  tRunStartMs = millis();
  println("[TX] RUN");
}

// ===============================
// Serial processing (binary + ASCII)
// ===============================
void processSerial() {
  while (myPort.available() > 0) {
    int bi = myPort.read();
    if (bi == -1) return;
    int b = bi & 0xFF;

    if (rxState == RX_WAIT_H1 && b != UART_HDR) {
      handleAsciiByte(b);
      continue;
    }

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
        if (b == expected) handleFrame(rxCmd, rxPayload, rxLen);
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
      lastTXT = asciiBuf.toString();
      asciiBuf.setLength(0);
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

    for (int i=0;i<MAX_NODES;i++) nodes[i].active = false;

    int pos = 2;
    for (int i = 0; i < nodeCount; i++) {
      if (pos + 5 > len) break;

      int idxNode = payload[pos++] & 0xFF;
      int xi = (payload[pos++] & 0xFF) | ((payload[pos++] & 0xFF) << 8);
      int yi = (payload[pos++] & 0xFF) | ((payload[pos++] & 0xFF) << 8);
      if (xi >= 32768) xi -= 65536;
      if (yi >= 32768) yi -= 65536;

      if (idxNode >= 0 && idxNode < MAX_NODES) {
        nodes[idxNode].x = xi / 1000.0;
        nodes[idxNode].y = yi / 1000.0;
        nodes[idxNode].active = true;
      }
    }

    lastFrameNodes = frameId;
    lastRX = "NODES frame=" + frameId + " n=" + nodeCount;
  }

  else if (cmd == CMD_GNG_EDGES) {
    if (len < 2) return;

    int frameId   = payload[0] & 0xFF;
    int edgeCount = payload[1] & 0xFF;
    gngEdgeCount  = edgeCount;

    for (int i=0;i<MAX_NODES;i++) {
      Arrays.fill(adj[i], false);
      deg[i] = 0;
    }

    edgesN = 0;
    int pos = 2;
    for (int i = 0; i < edgeCount; i++) {
      if (pos + 2 > len) break;
      int a = payload[pos++] & 0xFF;
      int b = payload[pos++] & 0xFF;
      if (a < 0 || a >= MAX_NODES || b < 0 || b >= MAX_NODES || a == b) continue;

      adj[a][b] = true;
      adj[b][a] = true;
      deg[a]++;
      deg[b]++;

      if (edgesN < edges.length) {
        if (edges[edgesN] == null) edges[edgesN] = new Edge();
        edges[edgesN].a = a;
        edges[edgesN].b = b;
        edges[edgesN].active = true;
        edgesN++;
      }
    }

    lastFrameEdges = frameId;
    lastRX = "EDGES frame=" + frameId + " e=" + edgeCount;
  }

  else if (cmd == CMD_PROF) {
    if (len < 1 + 10*4) return;

    int frameId = payload[0] & 0xFF;
    int pos = 1;

    prof.cyc_total   = rdU32LE(payload, pos); pos += 4;
    prof.cyc_winner  = rdU32LE(payload, pos); pos += 4;
    prof.cyc_move_w  = rdU32LE(payload, pos); pos += 4;
    prof.cyc_nb      = rdU32LE(payload, pos); pos += 4;
    prof.cyc_connect = rdU32LE(payload, pos); pos += 4;
    prof.cyc_delete  = rdU32LE(payload, pos); pos += 4;
    prof.cyc_prune   = rdU32LE(payload, pos); pos += 4;
    prof.cyc_insert  = rdU32LE(payload, pos); pos += 4;
    prof.cyc_renorm  = rdU32LE(payload, pos); pos += 4;
    prof.stepCount   = rdU32LE(payload, pos); pos += 4;

    lastFrameProf = frameId;
    lastRX = "PROF frame=" + frameId + " cyc_total=" + prof.cyc_total;

    tryCompleteFrame();
  }
}

int rdU32LE(byte[] p, int off) {
  return (p[off] & 0xFF) |
         ((p[off+1] & 0xFF) << 8) |
         ((p[off+2] & 0xFF) << 16) |
         ((p[off+3] & 0xFF) << 24);
}

// ===============================
// Frame complete -> metrics + CSV + autosave
// ===============================
void tryCompleteFrame() {
  if (lastFrameNodes < 0 || lastFrameEdges < 0 || lastFrameProf < 0) return;
  if (!(lastFrameNodes == lastFrameEdges && lastFrameEdges == lastFrameProf)) return;

  int fid = lastFrameProf;
  if (fid == lastCompleteFrame) return;

  lastCompleteFrame = fid;

  Metrics m = computeMetrics();

  long runMs = (tRunStartMs >= 0) ? (millis() - tRunStartMs) : -1;
  float usTotal = (prof.cyc_total * 1e6f) / (float)CPU_HZ;

  if (logEnabled && csv != null) {
    csv.println(
      runMs + "," + fid + "," +
      m.nodeActive + "," + m.edgeCount + "," +
      nf(m.QE,1,6) + "," + nf(m.TE,1,6) + "," +
      m.isolated + "," + nf(m.avgDegree,1,4) + "," +
      prof.cyc_total + "," + nf(usTotal,1,3) + "," +
      prof.cyc_winner + "," + prof.cyc_nb + "," + prof.cyc_insert
    );
    csv.flush();
  }

  if (autoSavePng) savePlotPNG(fid);
}

// ===============================
// Metrics
// ===============================
static class Metrics {
  int nodeActive;
  int edgeCount;
  float QE;
  float TE;
  int isolated;
  float avgDegree;
}

Metrics computeMetrics() {
  Metrics m = new Metrics();

  int nAct = 0;
  for (int i=0;i<MAX_NODES;i++) if (nodes[i].active) nAct++;
  m.nodeActive = nAct;
  m.edgeCount = edgesN;

  int iso = 0;
  int degSum = 0;
  for (int i=0;i<MAX_NODES;i++) {
    if (!nodes[i].active) continue;
    degSum += deg[i];
    if (deg[i] == 0) iso++;
  }
  m.isolated = iso;
  m.avgDegree = (nAct > 0) ? ((float)degSum / (float)nAct) : 0;

  float qeSum = 0;
  int teCount = 0;

  for (int k=0;k<data.length;k++) {
    float px = data[k][0];
    float py = data[k][1];

    int s1=-1, s2=-1;
    float best1=1e9, best2=1e9;

    for (int i=0;i<MAX_NODES;i++) {
      if (!nodes[i].active) continue;
      float dx = px - nodes[i].x;
      float dy = py - nodes[i].y;
      float d2 = dx*dx + dy*dy;
      if (d2 < best1) {
        best2 = best1; s2 = s1;
        best1 = d2;    s1 = i;
      } else if (d2 < best2) {
        best2 = d2; s2 = i;
      }
    }

    if (s1 >= 0) qeSum += sqrt(best1);
    if (s1 >= 0 && s2 >= 0) {
      if (!adj[s1][s2]) teCount++;
    }
  }

  m.QE = qeSum / (float)data.length;
  m.TE = teCount / (float)data.length;
  return m;
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
// Plot rendering (paper style)
// ===============================
void renderPlot(PGraphics gg, int x0, int y0, int w, int h, boolean title) {
  // bigger margins for larger fonts
  int marginL = 85;
  int marginR = 30;
  int marginT = title ? 60 : 30;
  int marginB = 80;

  int px0 = x0 + marginL;
  int py0 = y0 + marginT;
  int pw  = w - marginL - marginR;
  int ph  = h - marginT - marginB;

  // ---- FORCE SQUARE PLOT AREA (1:1 aspect) ----
  int side = min(pw, ph);
  int sx0  = px0 + (pw - side)/2;
  int sy0  = py0 + (ph - side)/2;
  int sw   = side;
  int sh   = side;

  // frame
  gg.stroke(0);
  gg.strokeWeight(1);
  gg.noFill();
  gg.rect(sx0, sy0, sw, sh);

  // grid + ticks
  gg.fill(0);
  gg.textSize(14);
  gg.textAlign(CENTER, TOP);

  for (int t=0;t<=5;t++) {
    float v = t/5.0;
    float x = sx0 + v*sw;

    gg.stroke(235);
    gg.line(x, sy0, x, sy0+sh);

    gg.stroke(0);
    gg.line(x, sy0+sh, x, sy0+sh+6);
    gg.text(nf(v,1,1), x, sy0+sh+10);
  }

  gg.textAlign(RIGHT, CENTER);
  for (int t=0;t<=5;t++) {
    float v = t/5.0;
    float y = sy0 + (1.0-v)*sh;

    gg.stroke(235);
    gg.line(sx0, y, sx0+sw, y);

    gg.stroke(0);
    gg.line(sx0-6, y, sx0, y);
    gg.text(nf(v,1,1), sx0-10, y);
  }

  // axis labels
  gg.fill(0);
  gg.textAlign(CENTER, CENTER);
  gg.textSize(18);
  gg.text("x (normalized)", sx0 + sw/2, sy0 + sh + 55);

  gg.pushMatrix();
  gg.translate(sx0 - 60, sy0 + sh/2);
  gg.rotate(-HALF_PI);
  gg.text("y (normalized)", 0, 0);
  gg.popMatrix();

  // title
  if (title) {
    gg.textAlign(LEFT, CENTER);
    gg.textSize(20);
    gg.text("GNG on Two-Moons", x0 + 450, y0 + 26);
  }

  // dataset colors
  int cBlueR=40,  cBlueG=110, cBlueB=220;
  int cOrgR=40, cOrgG=110, cOrgB=220;

  // ---- DATASET (NO MIXING): Moon A = BLUE circle, Moon B = ORANGE square ----
gg.stroke(255);
gg.strokeWeight(1);
gg.rectMode(CENTER);

for (int i=0;i<data.length;i++) {
  float x = map01x(data[i][0], sx0, sw);
  float y = map01y(data[i][1], sy0, sh);

  if (i < data.length/2) {
    gg.fill(cBlueR, cBlueG, cBlueB);
    gg.circle(x, y, 5);
  } else {
    gg.fill(cOrgR, cOrgG, cOrgB);
    gg.rect(x, y, 5, 5);
  }
}

// 🔴 PENTING
gg.rectMode(CORNER);
gg.noStroke();

  // edges
  gg.stroke(110);
  gg.strokeWeight(2);
  for (int i=0;i<edgesN;i++) {
    int a = edges[i].a;
    int b = edges[i].b;
    if (a<0||a>=MAX_NODES||b<0||b>=MAX_NODES) continue;
    if (!nodes[a].active || !nodes[b].active) continue;

    float x1 = map01x(nodes[a].x, sx0, sw);
    float y1 = map01y(nodes[a].y, sy0, sh);
    float x2 = map01x(nodes[b].x, sx0, sw);
    float y2 = map01y(nodes[b].y, sy0, sh);
    gg.line(x1,y1,x2,y2);
  }

  // nodes (red X)
  gg.stroke(220, 0, 0);
  gg.strokeWeight(3);
  for (int i=0;i<MAX_NODES;i++) {
    if (!nodes[i].active) continue;
    float x = map01x(nodes[i].x, sx0, sw);
    float y = map01y(nodes[i].y, sy0, sh);
    float r = 8;
    gg.line(x-r, y-r, x+r, y+r);
    gg.line(x-r, y+r, x+r, y-r);
  }

  // legend
  drawLegend(gg, sx0, sy0, sw, sh, cBlueR,cBlueG,cBlueB, cOrgR,cOrgG,cOrgB);
}

void drawLegend(PGraphics gg, int sx0, int sy0, int sw, int sh,
                int bR,int bG,int bB, int oR,int oG,int oB) {
        

  int pad  = 12;
  int boxW = 290;
  int boxH = 120;

  // target: top-right inside square plot
  int bx = sx0 + sw - boxW - pad;
  int by = sy0 + pad ;   // turunkan 20 px


  // clamp INSIDE square plot (safe for screen and saved PGraphics)
  bx = constrain(bx, sx0 + 10, sx0 + sw - boxW - 10);
  by = constrain(by, sy0 + 10, sy0 + sh - boxH - 10);

  // legend box
  gg.pushStyle();
gg.rectMode(CORNER);

  gg.noStroke();
  gg.fill(255, 245);
  gg.rect(bx, by, boxW, boxH, 8);

  gg.stroke(0, 70);
  gg.strokeWeight(1);
  gg.noFill();
  gg.rect(bx, by, boxW, boxH, 8);

  gg.textSize(14);
  gg.textAlign(LEFT, CENTER);

  int x0 = bx + 16;
  int y0 = by + 24;

  // Moon A (circle)
  gg.stroke(255);
  gg.strokeWeight(1);
  gg.fill(bR,bG,bB);
  gg.circle(x0, y0, 9);
  gg.noStroke();
  gg.fill(0);
  gg.text("Two-Moons dataset", x0 + 16, y0);

//  // Moon B (square)
  int y1 = y0 + 0;
//  gg.stroke(255);
//  gg.strokeWeight(1);
//  gg.fill(oR,oG,oB);
//  gg.circle(x0, y1, 9);
//  gg.noStroke();
//  gg.fill(0);
//  gg.text("Moon B (second half)", x0 + 16, y1);

  // edges
  int y2 = y1 + 26;
  gg.stroke(110);
  gg.strokeWeight(2);
  gg.line(x0-5, y2, x0+12, y2);
  gg.noStroke();
  gg.fill(0);
  gg.text("GNG edges", x0 + 16, y2);

  // nodes
  int y3 = y2 + 26;
  gg.stroke(220, 0, 0);
  gg.strokeWeight(3);
  float r = 6;
  gg.line(x0-r, y3-r, x0+r, y3+r);
  gg.line(x0-r, y3+r, x0+r, y3-r);
  gg.noStroke();
  gg.fill(0);
  gg.text("GNG nodes", x0 + 16, y3);
  gg.popStyle();

}

float map01x(float v, int px0, int pw) {
  return px0 + constrain(v,0,1)*pw;
}
float map01y(float v, int py0, int ph) {
  return py0 + (1.0 - constrain(v,0,1))*ph;
}

// save plot-only PNG (no debug)
void savePlotPNG(int frameId) {
  int outW = WIN_W-100;
  int outH = WIN_H-100;

  PGraphics pg = createGraphics(outW, outH);
  pg.beginDraw();
  pg.background(255);

  // keep same layout as screen: plot uses (outH - DBG_H)
  renderPlot(pg, 0, 0, outW, outH - DBG_H, true);

  pg.endDraw();

  String fn = capDir + File.separator + "gng_overlay_frame_" + nf(frameId, 4) + ".png";
  pg.save(fn);
  println("Saved: " + fn);
}

// ===============================
// Debug panel
// ===============================
void drawDebugPanel() {
  int y0 = height - DBG_H;
  fill(0, 160);
  noStroke();
  rect(0, y0, width, DBG_H);

  long now = millis();
  long upMs = now - tStartMs;
  long runMs = (tRunStartMs >= 0) ? (now - tRunStartMs) : -1;

  float usTotal = (prof.cyc_total * 1e6f) / (float)CPU_HZ;

  fill(255);
  textSize(13);
  textAlign(LEFT, TOP);

  String runStr = (runMs >= 0) ? (runMs + " ms") : "--";
  text("Uptime(ms): " + upMs + "  |  Run(ms): " + runStr + "  |  CSV: " + csvPath, 12, y0 + 10);
  text("TX: " + lastTX, 12, y0 + 34);
  text("RX: " + lastRX, 12, y0 + 54);
  text("TXT: " + lastTXT, 12, y0 + 74);

  Metrics m = computeMetrics();
  text("Nodes=" + m.nodeActive + "  Edges=" + m.edgeCount + "  Isolated=" + m.isolated + "  AvgDeg=" + nf(m.avgDegree,1,4), 12, y0 + 96);
  text("PROF: frame=" + lastCompleteFrame + " cyc_total=" + prof.cyc_total + " (~" + nf(usTotal,1,3) + " us)  winner=" + prof.cyc_winner + "  nb=" + prof.cyc_nb + "  insert=" + prof.cyc_insert, 12, y0 + 116);
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
