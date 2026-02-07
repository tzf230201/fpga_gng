// ======================================================
// GNG Viewer (Processing) : DATASET + DBG + NODE/EDGE render
// WITHOUT settings() AND WITHOUT size()
// Uses: surface.setSize(WIN_W, WIN_H);
// RX expects:
//   A5 10 : DBG fixed 46 bytes
//   A5 20 : NODE_SNAPSHOT fixed: 4 + MAX_NODES*7 bytes
//   A5 21 : EDGE_SNAPSHOT variable: 4 + cnt*3 bytes
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
// Window / layout
// -------------------------------
final int WIN_W = 1400;
final int WIN_H = 780;

final int TOP = 80;
final int DBG_H = 110;

final int PANEL_W = 600;
final int PANEL_H = 600;

final int L_X = 60;
final int L_Y = TOP;

final int R_X = 740;
final int R_Y = TOP;

// -------------------------------
// GNG limits
// -------------------------------
final int MAX_NODES = 40;

// VHDL node coordinate scale (0..1000 typical)
final float NODE_SCALE = 1000.0;

// Edge age for alpha mapping
final int A_MAX = 50; // match VHDL A_MAX

// -------------------------------
// Dataset (Two Moons) for reference + TX
// -------------------------------
final int     MOONS_N            = 100;
final boolean MOONS_RANDOM_ANGLE = false;
final int     MOONS_SEED         = 1234;
final float   MOONS_NOISE_STD    = 0.06;
final boolean MOONS_SHUFFLE      = true;
final boolean MOONS_NORMALIZE01  = true;

final float SCALE = 1000.0;
final int BYTES_PER_POINT = 4;
final int TX_BYTES = MOONS_N * BYTES_PER_POINT;

byte[] txBuf = new byte[TX_BYTES];
float[][] moonsTx;

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

// ======================================================
// Setup / Draw
// ======================================================
void setup() {
  // IMPORTANT: do NOT call size()
  surface.setSize(WIN_W, WIN_H);

  surface.setTitle("GNG Viewer (DBG + NODE/EDGE) - no settings(), no size()");
  frameRate(60);
  smooth(4);
  textFont(createFont("Consolas", 14));

  buildTwoMoonsAndPack();

  println("Serial ports:");
  println(Serial.list());

  try {
    myPort = new Serial(this, PORT_NAME, BAUD);
    myPort.clear();
    myPort.buffer(1);
    delay(200);
    sendDatasetOnce();
    println("Opened " + PORT_NAME + " @ " + BAUD);
  } catch(Exception e) {
    println("Failed to open serial: " + e);
    myPort = null;
  }
}

void draw() {
  background(14);

  // read serial bytes
  if (myPort != null) {
    while (myPort.available() > 0) {
      int b = myPort.read();
      if (b < 0) break;
      if (rxLen < rx.length) rx[rxLen++] = (byte)b;
    }
    parseRx();
  }

  // Panels
  drawPanelFrame(L_X, L_Y, "TX DATASET (static)");
  drawPanelFrame(R_X, R_Y, "RX: DBG + NODE/EDGE (now)");

  // Left: dataset bright
  drawDataset(L_X, L_Y, true);

  // Right: dataset dim + edges + nodes + winners
  drawDataset(R_X, R_Y, false);
  drawEdges(R_X, R_Y);
  drawNodes(R_X, R_Y);
  drawWinners(R_X, R_Y);

  drawDebugBar();
}

// ======================================================
// Keys
// ======================================================
void keyPressed() {
  if (key=='r' || key=='R') { buildTwoMoonsAndPack(); sendDatasetOnce(); }
  if (key=='s' || key=='S') { sendDatasetOnce(); }
}

void sendDatasetOnce() {
  if (myPort == null) return;
  myPort.write(txBuf);
}

// ======================================================
// UI helpers
// ======================================================
void drawPanelFrame(int x0, int y0, String title) {
  noFill();
  stroke(60);
  rect(x0, y0, PANEL_W, PANEL_H);
  fill(200);
  textSize(14);
  text(title, x0, y0 - 18);

  // grid
  stroke(35);
  line(x0 + PANEL_W/2, y0, x0 + PANEL_W/2, y0 + PANEL_H);
  line(x0, y0 + PANEL_H/2, x0 + PANEL_W, y0 + PANEL_H/2);
}

void drawDebugBar() {
  fill(0, 160);
  noStroke();
  rect(0, height-DBG_H, width, DBG_H);

  fill(220);
  textSize(12);
  String s =
    "DBG(A5 10): s1=" + dbg_s1 +
    " s2=" + dbg_s2 +
    " edge01=" + dbg_edge01 +
    " e_s1s2_pre=" + dbg_es1s2_pre +
    " deg=(" + dbg_deg_s1 + "," + dbg_deg_s2 + ")" +
    " conn=" + (dbg_conn ? "Y":"N") +
    " rm=" + (dbg_rm ? 1:0) +
    " iso=" + (dbg_iso ? 1:0) + "(id=" + dbg_iso_id + ")" +
    " nodes=" + dbg_node_count +
    " ins=" + (dbg_ins ? 1:0) + "(id=" + dbg_ins_id + ")" +
    " err32=" + dbg_err32 +
    " samp=" + dbg_sample +
    " | snapNodes=" + snapNodesSeen +
    " snapEdges=" + snapEdgesSeen;

  text(s, 30, height-DBG_H+35);

  fill(160);
  text("RX expects: A5 10 (DBG), A5 20 (NODE_SNAPSHOT), A5 21 (EDGE_SNAPSHOT).  Keys: [R]=rebuild+send  [S]=send",
       30, height-DBG_H+60);
}

// ======================================================
// Dataset + TX packing
// ======================================================
void buildTwoMoonsAndPack() {
  moonsTx = generateMoons(MOONS_N, MOONS_RANDOM_ANGLE, MOONS_NOISE_STD, MOONS_SEED, MOONS_SHUFFLE, MOONS_NORMALIZE01);

  int p=0;
  for (int i=0;i<MOONS_N;i++){
    short xi=(short)round(moonsTx[i][0]*SCALE);
    short yi=(short)round(moonsTx[i][1]*SCALE);
    txBuf[p++]=(byte)(xi & 0xFF);
    txBuf[p++]=(byte)((xi>>8)&0xFF);
    txBuf[p++]=(byte)(yi & 0xFF);
    txBuf[p++]=(byte)((yi>>8)&0xFF);
  }
}

float[][] generateMoons(int N, boolean randomAngle, float noiseStd, int seed, boolean shuffle, boolean normalize01) {
  float[][] arr=new float[N][2];
  randomSeed(seed);

  for (int i=0;i<N/2;i++){
    float t = randomAngle ? random(PI) : map(i,0,(N/2)-1,0,PI);
    arr[i][0]=cos(t);
    arr[i][1]=sin(t);
  }
  for (int i=N/2;i<N;i++){
    int j=i-N/2;
    float t = randomAngle ? random(PI) : map(j,0,(N/2)-1,0,PI);
    arr[i][0]=1-cos(t);
    arr[i][1]=-sin(t)-0.5;
  }

  if (noiseStd>0){
    for (int i=0;i<N;i++){
      arr[i][0]+= (float)randomGaussian()*noiseStd;
      arr[i][1]+= (float)randomGaussian()*noiseStd;
    }
  }

  if (normalize01){
    float minx=999,maxx=-999,miny=999,maxy=-999;
    for (int i=0;i<N;i++){
      minx=min(minx,arr[i][0]); maxx=max(maxx,arr[i][0]);
      miny=min(miny,arr[i][1]); maxy=max(maxy,arr[i][1]);
    }
    float dx=max(1e-9, maxx-minx);
    float dy=max(1e-9, maxy-miny);
    for (int i=0;i<N;i++){
      arr[i][0]=(arr[i][0]-minx)/dx;
      arr[i][1]=(arr[i][1]-miny)/dy;
    }
  }

  if (shuffle){
    for (int i=N-1;i>0;i--){
      int j=(int)random(i+1);
      float tx=arr[i][0], ty=arr[i][1];
      arr[i][0]=arr[j][0]; arr[i][1]=arr[j][1];
      arr[j][0]=tx; arr[j][1]=ty;
    }
  }
  return arr;
}

// ======================================================
// Drawing dataset + nodes + edges
// ======================================================
PVector map01ToPanel(float x01, float y01, int x0, int y0) {
  float px = map(x01, 0, 1, x0 + 20, x0 + PANEL_W - 20);
  float py = map(y01, 0, 1, y0 + PANEL_H - 20, y0 + 20);
  return new PVector(px, py);
}

PVector mapNodeToPanel(float nxRaw, float nyRaw, int x0, int y0) {
  float nx = nxRaw / NODE_SCALE;
  float ny = nyRaw / NODE_SCALE;
  return map01ToPanel(nx, ny, x0, y0);
}

void drawDataset(int x0, int y0, boolean bright) {
  noStroke();
  fill(0, 110);
  rect(x0, y0, PANEL_W, PANEL_H);

  noStroke();
  fill(255, bright ? 255 : 90);
  for (int i=0;i<moonsTx.length;i++){
    PVector q = map01ToPanel(moonsTx[i][0], moonsTx[i][1], x0, y0);
    ellipse(q.x, q.y, bright?5:4, bright?5:4);
  }
}

void drawNodes(int x0, int y0) {
  for (int i=0; i<MAX_NODES; i++) {
    if (!nodeAct[i]) continue;
    PVector p = mapNodeToPanel(nodeX[i], nodeY[i], x0, y0);

    float r = 6 + min(10, nodeDeg[i]);

    noStroke();
    fill(220);
    ellipse(p.x, p.y, r, r);

    fill(160);
    textSize(11);
    text("" + i, p.x + 6, p.y - 6);
  }
}

void drawEdges(int x0, int y0) {
  for (Edge e : edges) {
    if (e.ageStored == 0) continue;
    if (e.a < 0 || e.a >= MAX_NODES || e.b < 0 || e.b >= MAX_NODES) continue;
    if (!nodeAct[e.a] || !nodeAct[e.b]) continue;

    PVector p1 = mapNodeToPanel(nodeX[e.a], nodeY[e.a], x0, y0);
    PVector p2 = mapNodeToPanel(nodeX[e.b], nodeY[e.b], x0, y0);

    int age = max(0, e.ageStored - 1);
    float a = map(constrain(age, 0, A_MAX), 0, A_MAX, 220, 40);

    stroke(200, a);
    strokeWeight(2);
    line(p1.x, p1.y, p2.x, p2.y);
  }
}

void drawWinners(int x0, int y0) {
  if (dbg_s1 >= 0 && dbg_s1 < MAX_NODES && nodeAct[dbg_s1]) {
    PVector p = mapNodeToPanel(nodeX[dbg_s1], nodeY[dbg_s1], x0, y0);
    noStroke();
    fill(255);
    ellipse(p.x, p.y, 14, 14);
    fill(255);
    textSize(14);
    text("s1", p.x + 10, p.y + 5);
  }
  if (dbg_s2 >= 0 && dbg_s2 < MAX_NODES && nodeAct[dbg_s2]) {
    PVector p = mapNodeToPanel(nodeX[dbg_s2], nodeY[dbg_s2], x0, y0);
    noStroke();
    fill(200);
    ellipse(p.x, p.y, 12, 12);
    fill(200);
    textSize(14);
    text("s2", p.x + 10, p.y + 5);
  }
}

// ======================================================
// RX parsing
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
         (u8(b[off+44])== 0xA9);
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
  dbg_sample = u8(b[off+45]);
}

void parseNodeSnap(byte[] b, int off) {
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
    int a = u8(b[p+2]);
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
      int frameLen = 46;
      if (i + frameLen > rxLen) break;
      if (!checkDbgFixed(rx, i)) { i++; continue; }
      parseDbgFrame(rx, i);
      i += frameLen;

    } else if (type == 0x20) {
      int frameLen = 4 + MAX_NODES * 7;
      if (i + frameLen > rxLen) break;
      parseNodeSnap(rx, i);
      i += frameLen;

    } else if (type == 0x21) {
      if (i + 4 > rxLen) break;
      int cnt = u8(rx[i+2]) | (u8(rx[i+3]) << 8);
      int frameLen = 4 + cnt * 3;
      if (i + frameLen > rxLen) break;
      parseEdgeSnap(rx, i, cnt);
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
