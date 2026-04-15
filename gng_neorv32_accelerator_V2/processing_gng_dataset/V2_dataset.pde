// ======================================================
// GNG Viewer (Processing) : A5 RX (DBG + NODE/EDGE) + Two-Moons TX
// - RX expects:
//    A5 10 : DBG fixed 46 bytes (with markers)
//    A5 20 : NODE_SNAPSHOT fixed: 4 + MAX_NODES*7 bytes
//    A5 21 : EDGE_SNAPSHOT variable: 4 + cnt*3 bytes
// - TX sends dataset as raw points: [xi_lo xi_hi yi_lo yi_hi] * MOONS_N
//
// IMPORTANT: dataset generator here matches your "paper style" version:
//   second moon uses: y = -sin(t) + 0.5   (NOT -0.5)
// ======================================================

import processing.serial.*;
import java.util.*;

// -------------------------------
// Serial config
// -------------------------------
Serial myPort;
final String PORT_NAME = "COM1";
final int BAUD = 1_000_000;

// -------------------------------
// Window
// -------------------------------
final int WIN_W = 1000;
final int WIN_H = 1000;
final int DBG_H = 140;

// -------------------------------
// GNG limits (MUST MATCH FPGA/VHDL)
// -------------------------------
final int MAX_NODES = 40;

// VHDL node coordinate scale (0..1000 typical)
final float NODE_SCALE = 1000.0;

// Edge age for alpha mapping
final int A_MAX = 50; // match VHDL A_MAX

// -------------------------------
// Dataset mode: 0 = Two Moons, 1 = Concentric Circles
// Press '1' for Moons, '2' for Circles
// -------------------------------
int DATASET_MODE = 0;

// -------------------------------
// Two-moons dataset options (MATCH YOUR PAPER STYLE)
// -------------------------------
final int     MOONS_N            = 100;
final boolean MOONS_RANDOM_ANGLE = false;
final int     MOONS_SEED         = 1234;
final float   MOONS_NOISE_STD    = 0.06;
final boolean MOONS_SHUFFLE      = true;
final boolean MOONS_NORMALIZE01  = true;

// -------------------------------
// Concentric circles dataset options
// -------------------------------
final int     CIRCLES_N          = 100;
final int     CIRCLES_SEED       = 1234;
final float   CIRCLES_NOISE_STD  = 0.04;
final float   CIRCLES_FACTOR     = 0.45;  // inner_radius / outer_radius
final boolean CIRCLES_SHUFFLE    = true;

// TX packing (raw stream)
final float SCALE = 1000.0;
final int BYTES_PER_POINT = 4;
final int TX_BYTES = MOONS_N * BYTES_PER_POINT;
byte[] txBuf = new byte[TX_BYTES];
float[][] dataTx;
int[] dataLabel = new int[MOONS_N]; // 0 = moon A (blue), 1 = moon B (yellow)

// -------------------------------
// CSV logging
// -------------------------------
PrintWriter csvDataset;
PrintWriter csvDbg;
PrintWriter csvNodes;
PrintWriter csvEdges;
int csvSnapIdx = 0;

// -------------------------------
// RX ring buffer
// -------------------------------
byte[] rx = new byte[1 << 16];
int rxLen = 0;

// -------------------------------
// Parsed DBG state (from A5 10 frame)
// -------------------------------
int dbg_s1 = 0;
int dbg_s2 = 0;
int dbg_edge01 = 0;
int dbg_es1s2_pre = 0;

int dbg_deg_s1 = 0;
int dbg_deg_s2 = 0;

boolean dbg_conn = false;
boolean dbg_rm = false;
boolean dbg_iso = false;
int dbg_iso_id = 0;

int dbg_node_count = 0;

boolean dbg_ins = false;
int dbg_ins_id = 0;

long dbg_err32 = 0;

int dbg_s1x_raw = 0;
int dbg_s1y_raw = 0;

long dbg_fpga_ts   = 0;  // raw cycle count from FPGA (27 MHz)
long dbg_fpga_ts_prev = -1;
float dbg_iter_us  = 0;  // computed iteration period in microseconds

int dbg_sample = 0;

// -------------------------------
// Graph snapshot storage
// -------------------------------
float[] nodeX = new float[MAX_NODES];
float[] nodeY = new float[MAX_NODES];
boolean[] nodeAct = new boolean[MAX_NODES];
int[] nodeDeg = new int[MAX_NODES];

static class Edge {
  int a, b;
  int ageStored; // 0=no edge, else age+1
  Edge(int a, int b, int ageStored) { this.a=a; this.b=b; this.ageStored=ageStored; }
}
ArrayList<Edge> edges = new ArrayList<Edge>();

int snapNodesSeen = 0;
int snapEdgesSeen = 0;

// -------------------------------
// Plot controls
// -------------------------------
boolean hideIsolated = true;        // press 'I' to toggle
boolean showMismatchPrint = true;    // press 'M' to toggle

// ======================================================
// Setup / Draw
// ======================================================
void setup() {
  // IMPORTANT: do NOT call size()
  surface.setSize(WIN_W, WIN_H);
  surface.setTitle("GNG on Two-Moons (A5 RX)");

  frameRate(60);
  smooth(4);
  textFont(createFont("Consolas", 13));

  // Build dataset (MATCH paper style) and pack to txBuf
  buildTwoMoonsAndPack();

  println("Serial ports:");
  println(Serial.list());

  try {
    myPort = new Serial(this, PORT_NAME, BAUD);
    myPort.clear();
    myPort.buffer(1);
    delay(250);

    sendDatasetOnce();
    println("Opened " + PORT_NAME + " @ " + BAUD + "  (sent dataset once)");
  } catch(Exception e) {
    println("Failed to open serial: " + e);
    myPort = null;
  }
}

void draw() {
  background(255);

  // read serial bytes
  if (myPort != null) {
    while (myPort.available() > 0) {
      int b = myPort.read();
      if (b < 0) break;
      if (rxLen < rx.length) rx[rxLen++] = (byte)b;
    }
    parseRx();
  }

  // plot (upper area)
  renderPlot(g, 0, 0, width, height - DBG_H, true);

  // debug bar bottom
  drawDebugPanel();
}

// ======================================================
// Keys
// ======================================================
void keyPressed() {
  if (key=='r' || key=='R') { buildDatasetAndPack(); sendDatasetOnce(); }
  if (key=='s' || key=='S') { sendDatasetOnce(); }
  if (key=='i' || key=='I') { hideIsolated = !hideIsolated; println("hideIsolated=" + hideIsolated); }
  if (key=='m' || key=='M') { showMismatchPrint = !showMismatchPrint; println("showMismatchPrint=" + showMismatchPrint); }
  if (key=='q' || key=='Q') { closeCSV(); println("CSV files closed/flushed."); }
  if (key=='1') { DATASET_MODE = 0; buildDatasetAndPack(); sendDatasetOnce(); }
  if (key=='2') { DATASET_MODE = 1; buildDatasetAndPack(); sendDatasetOnce(); }
}

void sendDatasetOnce() {
  // Fresh CSV for every dataset send.
  // Snapshot data from before this send (old GNG state) will NOT appear in the new files.
  closeCSV();
  setupCSV();
  csvSnapIdx = 0;
  writeDatasetCSV();

  if (myPort != null) {
    dbg_fpga_ts_prev = -1; // reset delta so first iter_us is not garbage
    myPort.write(txBuf);
    // Wait for all 400 bytes to be transmitted (at 1Mbaud: ~4ms) plus FPGA INIT time.
    // Then flush any stale snapshot bytes that arrived before the soft-reset.
    delay(50);
    myPort.clear();
    rxLen = 0;
    println("RX buffer flushed after dataset send.");
  }
}

// ======================================================
// Dataset + TX packing (MATCH YOUR PAPER STYLE)
// ======================================================
void buildDatasetAndPack() {
  if (DATASET_MODE == 1) {
    dataTx = generateCircles(
      CIRCLES_N, CIRCLES_FACTOR, CIRCLES_NOISE_STD,
      CIRCLES_SEED, CIRCLES_SHUFFLE, dataLabel
    );
    println("Dataset: Concentric Circles (" + CIRCLES_N + " samples)");
  } else {
    dataTx = generateMoons(
      MOONS_N, MOONS_RANDOM_ANGLE, MOONS_NOISE_STD,
      MOONS_SEED, MOONS_SHUFFLE, MOONS_NORMALIZE01, dataLabel
    );
    println("Dataset: Two Moons (" + MOONS_N + " samples)");
  }

  int N = dataTx.length;
  int p=0;
  for (int i=0;i<N;i++){
    short xi = (short)round(dataTx[i][0]*SCALE);
    short yi = (short)round(dataTx[i][1]*SCALE);
    txBuf[p++] = (byte)(xi & 0xFF);
    txBuf[p++] = (byte)((xi>>8)&0xFF);
    txBuf[p++] = (byte)(yi & 0xFF);
    txBuf[p++] = (byte)((yi>>8)&0xFF);
  }
}

void buildTwoMoonsAndPack() {
  buildDatasetAndPack();
}

// Two-moons generator (THIS IS THE ONE YOU WANTED)
float[][] generateMoons(int N, boolean randomAngle, float noiseStd, int seed,
                        boolean shuffle, boolean normalize01, int[] labelOut) {
  float[][] arr = new float[N][2];

  if (seed >= 0) randomSeed(seed);
  else randomSeed((int)millis());

  for (int i = 0; i < N/2; i++) {
    float t = randomAngle ? random(PI) : map(i, 0, (N/2) - 1, 0, PI);
    arr[i][0] = cos(t);
    arr[i][1] = sin(t);
    if (labelOut != null) labelOut[i] = 0; // moon A
  }

  for (int i = N/2; i < N; i++) {
    int j = i - N/2;
    float t = randomAngle ? random(PI) : map(j, 0, (N/2) - 1, 0, PI);
    arr[i][0] = 1 - cos(t);
    arr[i][1] = -sin(t) + 0.5;   // <-- IMPORTANT: +0.5 (match your code)
    if (labelOut != null) labelOut[i] = 1; // moon B
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
      // remap to [-1, 1] (symmetric around 0)
      arr[i][0] = ((arr[i][0] - minx) / dx) * 2.0 - 1.0;
      arr[i][1] = ((arr[i][1] - miny) / dy) * 2.0 - 1.0;
    }
  }

  if (shuffle) {
    for (int i = N - 1; i > 0; i--) {
      int j = (int)random(i + 1);
      float tx = arr[i][0], ty = arr[i][1];
      arr[i][0] = arr[j][0]; arr[i][1] = arr[j][1];
      arr[j][0] = tx;        arr[j][1] = ty;
      if (labelOut != null) {
        int tl = labelOut[i]; labelOut[i] = labelOut[j]; labelOut[j] = tl;
      }
    }
  }

  return arr;
}

// Concentric circles generator (similar to sklearn.datasets.make_circles)
float[][] generateCircles(int N, float factor, float noiseStd, int seed,
                          boolean shuffle, int[] labelOut) {
  float[][] arr = new float[N][2];

  if (seed >= 0) randomSeed(seed);
  else randomSeed((int)millis());

  int nOuter = N / 2;
  int nInner = N - nOuter;

  // outer circle (label 0)
  for (int i = 0; i < nOuter; i++) {
    float t = map(i, 0, nOuter, 0, TWO_PI);
    arr[i][0] = cos(t);
    arr[i][1] = sin(t);
    if (labelOut != null) labelOut[i] = 0;
  }

  // inner circle (label 1)
  for (int i = 0; i < nInner; i++) {
    float t = map(i, 0, nInner, 0, TWO_PI);
    arr[nOuter + i][0] = cos(t) * factor;
    arr[nOuter + i][1] = sin(t) * factor;
    if (labelOut != null) labelOut[nOuter + i] = 1;
  }

  // add noise
  if (noiseStd > 0.0) {
    for (int i = 0; i < N; i++) {
      arr[i][0] += (float)randomGaussian() * noiseStd;
      arr[i][1] += (float)randomGaussian() * noiseStd;
    }
  }

  // normalize to [-1, 1]
  float minx=999, maxx=-999, miny=999, maxy=-999;
  for (int i = 0; i < N; i++) {
    if (arr[i][0] < minx) minx = arr[i][0];
    if (arr[i][0] > maxx) maxx = arr[i][0];
    if (arr[i][1] < miny) miny = arr[i][1];
    if (arr[i][1] > maxy) maxy = arr[i][1];
  }
  float dx = maxx - minx; if (dx < 1e-9) dx = 1.0;
  float dy = maxy - miny; if (dy < 1e-9) dy = 1.0;
  for (int i = 0; i < N; i++) {
    arr[i][0] = ((arr[i][0] - minx) / dx) * 2.0 - 1.0;
    arr[i][1] = ((arr[i][1] - miny) / dy) * 2.0 - 1.0;
  }

  // shuffle
  if (shuffle) {
    for (int i = N - 1; i > 0; i--) {
      int j = (int)random(i + 1);
      float tx = arr[i][0], ty = arr[i][1];
      arr[i][0] = arr[j][0]; arr[i][1] = arr[j][1];
      arr[j][0] = tx;        arr[j][1] = ty;
      if (labelOut != null) {
        int tl = labelOut[i]; labelOut[i] = labelOut[j]; labelOut[j] = tl;
      }
    }
  }

  return arr;
}

// ======================================================
// Plot rendering (paper style)
// ======================================================
void renderPlot(PGraphics gg, int x0, int y0, int w, int h, boolean title) {
  int marginL = 85;
  int marginR = 30;
  int marginT = title ? 60 : 30;
  int marginB = 110;

  int px0 = x0 + marginL;
  int py0 = y0 + marginT;
  int pw  = w - marginL - marginR;
  int ph  = h - marginT - marginB;

  // force square
  int side = min(pw, ph);
  int sx0  = px0 + (pw - side)/2;
  int sy0  = py0 + (ph - side)/2;
  int sw   = side;
  int sh   = side;

  gg.pushStyle();

  // frame
  gg.stroke(0);
  gg.strokeWeight(1);
  gg.noFill();
  gg.rect(sx0, sy0, sw, sh);

  // grid + ticks (range -1 to 1, step 0.5)
  gg.fill(0);
  gg.textSize(14);
  gg.textAlign(CENTER, TOP);

  for (int t=0;t<=4;t++) {
    float v = -1.0 + t * 0.5;
    float xx = sx0 + map(v, -1, 1, 0, sw);

    gg.stroke(235);
    gg.line(xx, sy0, xx, sy0+sh);

    gg.stroke(0);
    gg.line(xx, sy0+sh, xx, sy0+sh+6);
    gg.text(nf(v,1,1), xx, sy0+sh+10);
  }

  gg.textAlign(RIGHT, CENTER);
  for (int t=0;t<=4;t++) {
    float v = -1.0 + t * 0.5;
    float yy = sy0 + map(v, -1, 1, sh, 0);

    gg.stroke(235);
    gg.line(sx0, yy, sx0+sw, yy);

    gg.stroke(0);
    gg.line(sx0-6, yy, sx0, yy);
    gg.text(nf(v,1,1), sx0-10, yy);
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
    gg.textAlign(CENTER, CENTER);
    gg.textSize(20);
    String dsName = (DATASET_MODE == 1) ? "Concentric Circles" : "Two-Moons";
    gg.text("GNG on " + dsName + " (A5 RX)", x0 + w/2, y0 + 26);
  }

  // dataset: moon A (blue), moon B (yellow)
  gg.noStroke();
  for (int i=0;i<dataTx.length;i++) {
    if (dataLabel[i] == 1) gg.fill(255, 140, 0);   // moon B: yellow
    else                   gg.fill(40, 110, 220);   // moon A: blue
    float x = mapN11x(dataTx[i][0], sx0, sw);
    float y = mapN11y(dataTx[i][1], sy0, sh);
    gg.rect(x-2, y-2, 4, 4);
  }

  // edges
  gg.strokeWeight(2);
  for (Edge e : edges) {
    if (e.ageStored == 0) continue;
    if (e.a < 0 || e.a >= MAX_NODES || e.b < 0 || e.b >= MAX_NODES) continue;
    if (!nodeAct[e.a] || !nodeAct[e.b]) continue;

    int age = max(0, e.ageStored - 1);
    float alpha = map(constrain(age, 0, A_MAX), 0, A_MAX, 220, 40);
    gg.stroke(110, alpha);

    float x1 = mapN11x(nodeX[e.a]/NODE_SCALE, sx0, sw);
    float y1 = mapN11y(nodeY[e.a]/NODE_SCALE, sy0, sh);
    float x2 = mapN11x(nodeX[e.b]/NODE_SCALE, sx0, sw);
    float y2 = mapN11y(nodeY[e.b]/NODE_SCALE, sy0, sh);
    gg.line(x1,y1,x2,y2);
  }

  // nodes (red X) + (optional) hide isolated (from edge list)
  gg.stroke(220, 0, 0);
  gg.strokeWeight(3);
  for (int i=0;i<MAX_NODES;i++) {
    if (!nodeAct[i]) continue;

    int dEdge = degFromEdges(i);
    if (hideIsolated && dEdge == 0) continue;

    float x = mapN11x(nodeX[i]/NODE_SCALE, sx0, sw);
    float y = mapN11y(nodeY[i]/NODE_SCALE, sy0, sh);
    float r = 8;
    gg.line(x-r, y-r, x+r, y+r);
    gg.line(x-r, y+r, x+r, y-r);
  }

  // legend
  drawLegend(gg, sx0, sy0, sw, sh);

  gg.popStyle();
}

void drawLegend(PGraphics gg, int sx0, int sy0, int sw, int sh) {
  gg.pushStyle();
  gg.textSize(13);
  gg.textAlign(LEFT, CENTER);

  int ly = sy0 + sh + 78;
  int cx = sx0 + sw / 2;
  int totalW = 520;
  int x0 = cx - totalW / 2;
  int spacing = 130;

  String labelA = (DATASET_MODE == 1) ? "Outer" : "Moon A";
  String labelB = (DATASET_MODE == 1) ? "Inner" : "Moon B";

  // item 1: dataset A (blue square)
  gg.noStroke();
  gg.fill(40, 110, 220);
  gg.rect(x0-3, ly-3, 6, 6);
  gg.fill(0);
  gg.text(labelA, x0 + 12, ly);

  // item 2: dataset B (yellow square)
  int x1 = x0 + spacing;
  gg.noStroke();
  gg.fill(255, 140, 0);
  gg.rect(x1-3, ly-3, 6, 6);
  gg.fill(0);
  gg.text(labelB, x1 + 12, ly);

  // item 3: edges (gray line)
  int x2 = x1 + spacing;
  gg.stroke(110);
  gg.strokeWeight(2);
  gg.line(x2-5, ly, x2+12, ly);
  gg.noStroke();
  gg.fill(0);
  gg.text("GNG edges", x2 + 18, ly);

  // item 4: nodes (red X)
  int x3 = x2 + spacing;
  gg.stroke(220, 0, 0);
  gg.strokeWeight(3);
  float r = 5;
  gg.line(x3-r, ly-r, x3+r, ly+r);
  gg.line(x3-r, ly+r, x3+r, ly-r);
  gg.noStroke();
  gg.fill(0);
  gg.text("GNG nodes", x3 + 12, ly);

  gg.popStyle();
}

float mapN11x(float v, int px0, int pw) {
  return px0 + map(constrain(v, -1, 1), -1, 1, 0, pw);
}
float mapN11y(float v, int py0, int ph) {
  return py0 + map(constrain(v, -1, 1), -1, 1, ph, 0);
}

// ======================================================
// Debug panel + mismatch detector
// ======================================================
void drawDebugPanel() {
  int y0 = height - DBG_H;

  fill(0, 160);
  noStroke();
  rect(0, y0, width, DBG_H);

  // counts
  int actN = 0;
  for (int i=0;i<MAX_NODES;i++) if (nodeAct[i]) actN++;

  int isoByEdges = 0;
  int isoByNodeDeg = 0;
  for (int i=0;i<MAX_NODES;i++){
    if(!nodeAct[i]) continue;
    if(degFromEdges(i) == 0) isoByEdges++;
    if(nodeDeg[i] == 0) isoByNodeDeg++;
  }

  // mismatch prints (optional)
  if (showMismatchPrint) {
    for (int i=0;i<MAX_NODES;i++){
      if(!nodeAct[i]) continue;
      int dE = degFromEdges(i);
      int dN = nodeDeg[i];
      // "mismatch" heuristics: nodeDeg says connected but edges snapshot says 0, or vice versa
      if ((dE==0 && dN>0) || (dE>0 && dN==0)) {
        println("DEG MISMATCH node=" + i + "  nodeDeg=" + dN + "  degFromEdges=" + dE +
                "  (snapNodes=" + snapNodesSeen + " snapEdges=" + snapEdgesSeen + ")");
      }
    }
  }

  fill(255);
  textSize(13);
  textAlign(LEFT, TOP);

  String s1 =
    "A5 DBG: s1=" + dbg_s1 + " s2=" + dbg_s2 +
    " deg=(" + dbg_deg_s1 + "," + dbg_deg_s2 + ")" +
    " conn=" + (dbg_conn?"Y":"N") +
    " rm=" + (dbg_rm?1:0) +
    " iso=" + (dbg_iso?1:0) + "(id=" + dbg_iso_id + ")" +
    " nodes=" + dbg_node_count +
    " ins=" + (dbg_ins?1:0) + "(id=" + dbg_ins_id + ")" +
    " err32=" + dbg_err32 +
    " samp=" + dbg_sample +
    "  |  FPGA: elapsed=" + fpgaFmtTime(dbg_fpga_ts) + "  iter=" + fpgaFmtIter(dbg_iter_us);

  String s2 =
    "SNAP: active=" + actN +
    " edges=" + edges.size() +
    " iso(nodeDeg)=" + isoByNodeDeg +
    " iso(edges)=" + isoByEdges +
    " | snapNodesSeen=" + snapNodesSeen +
    " snapEdgesSeen=" + snapEdgesSeen +
    " | hideIsolated=" + hideIsolated + " (toggle I)";

  text(s1, 12, y0 + 12);
  text(s2, 12, y0 + 34);
  text("Keys: [R]=rebuild+send dataset  [S]=send dataset  [I]=hide isolated(by edges)  [M]=toggle mismatch print",
       12, y0 + 58);
}

// degree computed from current edges snapshot
int degFromEdges(int id) {
  int d = 0;
  for (Edge e : edges) {
    if (e.ageStored == 0) continue;
    if (e.a == id) d++;
    else if (e.b == id) d++;
  }
  return d;
}

// ======================================================
// RX parsing (A5)
// ======================================================
final int TAG_A5 = 0xA5;

boolean checkDbgFixed(byte[] b, int off) {
  return (u8(b[off+0]) == 0xA5) &&
         (u8(b[off+1]) == 0x10) &&
         (u8(b[off+2]) == 0xA6) &&
         (u8(b[off+4]) == 0xA7) &&
         (u8(b[off+6]) == 0xA8) &&
         (u8(b[off+8]) == 0xC0) &&
         (u8(b[off+10])== 0xC1) &&
         (u8(b[off+12])== 0xC2) &&
         (u8(b[off+14])== 0xC3) &&
         (u8(b[off+16])== 0xC4) &&
         (u8(b[off+18])== 0xC5) &&
         (u8(b[off+20])== 0xC6) &&
         (u8(b[off+22])== 0xC7) &&
         (u8(b[off+24])== 0xC8) &&
         (u8(b[off+26])== 0xC9) &&
         (u8(b[off+28])== 0xAA) &&
         (u8(b[off+30])== 0xAB) &&
         (u8(b[off+32])== 0xAC) &&
         (u8(b[off+34])== 0xAD) &&
         (u8(b[off+36])== 0xAE) &&
         (u8(b[off+38])== 0xAF) &&
         (u8(b[off+40])== 0xB0) &&
         (u8(b[off+42])== 0xB1) &&
         (u8(b[off+44])== 0xB2) &&  // FPGA timestamp bytes (new)
         (u8(b[off+46])== 0xB3) &&
         (u8(b[off+48])== 0xB4) &&
         (u8(b[off+50])== 0xB5) &&
         (u8(b[off+52])== 0xA9);    // terminator moved to [52]
}

void parseDbgFrame(byte[] b, int off) {
  dbg_s1 = u8(b[off+3]);
  dbg_s2 = u8(b[off+5]);
  dbg_edge01 = u8(b[off+7]);
  dbg_es1s2_pre = u8(b[off+9]);
  dbg_deg_s1 = u8(b[off+11]);
  dbg_deg_s2 = u8(b[off+13]);
  dbg_conn = (u8(b[off+15]) & 0x01) != 0;
  dbg_rm   = (u8(b[off+17]) & 0x01) != 0;
  dbg_iso  = (u8(b[off+19]) & 0x01) != 0;
  dbg_iso_id = u8(b[off+21]);
  dbg_node_count = u8(b[off+23]);
  dbg_ins = (u8(b[off+25]) & 0x01) != 0;
  dbg_ins_id = u8(b[off+27]);

  long e0 = u8(b[off+29]);
  long e1 = u8(b[off+31]);
  long e2 = u8(b[off+33]);
  long e3 = u8(b[off+35]);
  dbg_err32 = (e3<<24) | (e2<<16) | (e1<<8) | e0;

  dbg_s1x_raw = s16le(b, off+37, off+39);
  dbg_s1y_raw = s16le(b, off+41, off+43);

  // FPGA cycle timestamp (32-bit LE, tags B2-B5 at offsets 44-51)
  long ts = ((long)u8(b[off+45])) |
            ((long)u8(b[off+47]) << 8) |
            ((long)u8(b[off+49]) << 16) |
            ((long)u8(b[off+51]) << 24);
  if (dbg_fpga_ts_prev >= 0) {
    long delta = (ts - dbg_fpga_ts_prev) & 0xFFFFFFFFL; // handle 32-bit wrap
    dbg_iter_us = delta / 27.0;  // 27 MHz → microseconds
  }
  dbg_fpga_ts_prev = ts;
  dbg_fpga_ts      = ts;

  dbg_sample = u8(b[off+53]); // moved from [45] to [53]
}

void parseNodeSnap(byte[] b, int off) {
  // clear first to avoid stale state if something goes weird
  for (int i=0;i<MAX_NODES;i++) {
    nodeAct[i] = false;
    nodeDeg[i] = 0;
    nodeX[i]   = 0;
    nodeY[i]   = 0;
  }

  int p = off + 4;
  for (int k=0; k<MAX_NODES; k++) {
    int id  = u8(b[p+0]);
    int act = u8(b[p+1]);
    int deg = u8(b[p+2]);
    int x   = s16le(b, p+3, p+4);
    int y   = s16le(b, p+5, p+6);

    if (id >= 0 && id < MAX_NODES) {
      nodeAct[id] = (act != 0);
      nodeDeg[id] = deg;
      nodeX[id]   = x;
      nodeY[id]   = y;
    }
    p += 7;
  }
  snapNodesSeen++;
}

void parseEdgeSnap(byte[] b, int off, int cnt) {
  edges.clear();
  int p = off + 4;
  for (int k=0; k<cnt; k++) {
    int i = u8(b[p+0]);
    int j = u8(b[p+1]);
    int a = u8(b[p+2]); // ageStored
    edges.add(new Edge(i, j, a));
    p += 3;
  }
  snapEdgesSeen++;
}

void parseRx() {
  int i = 0;
  while (i <= rxLen - 2) {
    if (u8(rx[i]) != TAG_A5) { i++; continue; }

    int type = u8(rx[i+1]);

    if (type == 0x10) {
      int frameLen = 54; // 46 + 8 bytes (4 × tag+value for FPGA timestamp)
      if (i + frameLen > rxLen) break;
      if (!checkDbgFixed(rx, i)) { i++; continue; }
      parseDbgFrame(rx, i);
      writeDbgCSV();
      i += frameLen;

    } else if (type == 0x20) {
      int frameLen = 4 + MAX_NODES * 7;
      if (i + frameLen > rxLen) break;
      parseNodeSnap(rx, i);
      writeNodeSnapCSV();
      i += frameLen;

    } else if (type == 0x21) {
      if (i + 4 > rxLen) break;
      int cnt = u8(rx[i+2]) | (u8(rx[i+3]) << 8);
      int frameLen = 4 + cnt * 3;
      if (i + frameLen > rxLen) break;
      parseEdgeSnap(rx, i, cnt);
      writeEdgeSnapCSV();
      i += frameLen;

    } else {
      i++;
    }
  }

  if (i > 0) {
    int rem = rxLen - i;
    if (rem > 0) arrayCopy(rx, i, rx, 0, rem);
    rxLen = rem;
  }
}

// ======================================================
// Byte helpers
// ======================================================
int u8(byte b) { return b & 0xFF; }
int s16le(byte[] b, int loPos, int hiPos) {
  int lo = u8(b[loPos]);
  int hi = u8(b[hiPos]);
  short v = (short)((hi << 8) | lo);
  return (int)v;
}

// ======================================================
// FPGA time formatting helpers (27 MHz clock)
// ======================================================
// elapsed: cycles → "X.XXX s" or "X.X ms"
String fpgaFmtTime(long cycles) {
  float ms = cycles / 27000.0;
  if (ms >= 1000.0) return nf(ms / 1000.0, 1, 3) + " s";
  return nf(ms, 1, 1) + " ms";
}
// iter period: microseconds → "X.X ms" or "X us"
String fpgaFmtIter(float us) {
  if (us >= 1000.0) return nf(us / 1000.0, 1, 2) + " ms";
  return nf(us, 1, 1) + " us";
}

// ======================================================
// CSV logging
// ======================================================
String csvTimestamp() {
  return String.format("%d%02d%02d_%02d%02d%02d",
    year(), month(), day(), hour(), minute(), second());
}

String csvNow() {
  return String.format("%d-%02d-%02d %02d:%02d:%02d.%03d",
    year(), month(), day(), hour(), minute(), second(), millis() % 1000);
}

void setupCSV() {
  // Ensure logs/ directory exists
  new java.io.File(sketchPath("logs")).mkdirs();

  String ts = csvTimestamp();
  csvDataset = createWriter(sketchPath("logs/dataset_"   + ts + ".csv"));
  csvDbg     = createWriter(sketchPath("logs/gng_dbg_"   + ts + ".csv"));
  csvNodes   = createWriter(sketchPath("logs/gng_nodes_" + ts + ".csv"));
  csvEdges   = createWriter(sketchPath("logs/gng_edges_" + ts + ".csv"));

  csvDataset.println("timestamp,index,x_norm,y_norm,label,x_int,y_int");
  csvDbg.println("timestamp,sample_idx,s1,s2,deg_s1,deg_s2,err32,s1x_raw,s1y_raw,node_count,conn,rm,iso,iso_id,ins,ins_id,fpga_ts_cycles,iter_us");
  csvNodes.println("timestamp,snap_idx,node_id,active,degree,x_int,y_int,x_norm,y_norm,fpga_ts_cycles");
  csvEdges.println("timestamp,snap_idx,node_a,node_b,age_stored,true_age");

  // Save dataset name metadata for replay
  String dsName = (DATASET_MODE == 1) ? "Concentric Circles" : "Two Moons";
  PrintWriter meta = createWriter(sketchPath("logs/meta_" + ts + ".txt"));
  meta.println(dsName);
  meta.flush();
  meta.close();

  println("CSV logging started: logs/*_" + ts + ".csv");
}

void writeDatasetCSV() {
  if (csvDataset == null) return;
  String ts = csvNow();
  for (int i = 0; i < MOONS_N; i++) {
    int xi = (int)round(dataTx[i][0] * SCALE);
    int yi = (int)round(dataTx[i][1] * SCALE);
    csvDataset.println(ts + "," + i + "," +
      nf(dataTx[i][0], 1, 6) + "," + nf(dataTx[i][1], 1, 6) + "," +
      dataLabel[i] + "," + xi + "," + yi);
  }
  csvDataset.flush();
}

void writeDbgCSV() {
  if (csvDbg == null) return;
  csvDbg.println(csvNow() + "," +
    dbg_sample + "," + dbg_s1 + "," + dbg_s2 + "," +
    dbg_deg_s1 + "," + dbg_deg_s2 + "," + dbg_err32 + "," +
    dbg_s1x_raw + "," + dbg_s1y_raw + "," + dbg_node_count + "," +
    (dbg_conn?1:0) + "," + (dbg_rm?1:0) + "," +
    (dbg_iso?1:0) + "," + dbg_iso_id + "," +
    (dbg_ins?1:0) + "," + dbg_ins_id + "," +
    dbg_fpga_ts + "," + nf(dbg_iter_us, 1, 3));
}

void writeNodeSnapCSV() {
  if (csvNodes == null) return;
  String ts = csvNow();
  for (int i = 0; i < MAX_NODES; i++) {
    float xn = nodeX[i] / NODE_SCALE;
    float yn = nodeY[i] / NODE_SCALE;
    csvNodes.println(ts + "," + csvSnapIdx + "," + i + "," +
      (nodeAct[i]?1:0) + "," + nodeDeg[i] + "," +
      (int)nodeX[i] + "," + (int)nodeY[i] + "," +
      nf(xn, 1, 6) + "," + nf(yn, 1, 6) + "," +
      dbg_fpga_ts);
  }
  csvNodes.flush();
}

void writeEdgeSnapCSV() {
  if (csvEdges == null) return;
  String ts = csvNow();
  for (Edge e : edges) {
    if (e.ageStored == 0) continue;
    csvEdges.println(ts + "," + csvSnapIdx + "," +
      e.a + "," + e.b + "," + e.ageStored + "," + (e.ageStored - 1));
  }
  csvEdges.flush();
  csvSnapIdx++;
}

void closeCSV() {
  if (csvDataset != null) { csvDataset.flush(); csvDataset.close(); csvDataset = null; }
  if (csvDbg     != null) { csvDbg.flush();     csvDbg.close();     csvDbg = null;     }
  if (csvNodes   != null) { csvNodes.flush();   csvNodes.close();   csvNodes = null;   }
  if (csvEdges   != null) { csvEdges.flush();   csvEdges.close();   csvEdges = null;   }
}
