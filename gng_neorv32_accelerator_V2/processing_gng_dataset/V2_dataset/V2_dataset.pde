import processing.serial.*;

// ======================================================
// Serial config
// ======================================================
Serial myPort;
final String PORT_NAME = "COM1";     // <-- GANTI sesuai Serial.list()
final int    BAUD      = 1_000_000;

// ======================================================
// Dataset options
// ======================================================
final int     MOONS_N            = 100;
final boolean MOONS_RANDOM_ANGLE = false;
final int     MOONS_SEED         = 1234;
final float   MOONS_NOISE_STD    = 0.06;
final boolean MOONS_SHUFFLE      = true;
final boolean MOONS_NORMALIZE01  = true;

final float SCALE = 1000.0;
final int BYTES_PER_POINT = 4;
final int TX_BYTES = MOONS_N * BYTES_PER_POINT; // 400

byte[] txBuf = new byte[TX_BYTES];
float[][] moonsTx;

// ======================================================
// Packet types (framed dump - old format)
// ======================================================
final int PKT_TYPE_EDGE = 0xB1; // edges dump
final int PKT_TYPE_NODE = 0xA1; // nodes dump

// ======================================================
// DEBUG TLV stream from new gng.vhd (tag,value)
// New frame (15 bytes total):
//   A5 type, A6 s1, A7 s2, A8 edge01, AA err32(LE4), A9 sample_idx
// ======================================================
final int TAG_A5 = 0xA5; // type / phase code
final int TAG_A6 = 0xA6; // s1 id
final int TAG_A7 = 0xA7; // s2 id
final int TAG_A8 = 0xA8; // edge(0,1) age
final int TAG_AA = 0xAA; // NEW: err32 little-endian 4 bytes
final int TAG_A9 = 0xA9; // sample idx (frame end marker)

// TLV parser state (supports 1B value or 4B value for AA)
int dbgTag = 0;
int dbgNeed = 0;   // how many value bytes needed
int dbgGot  = 0;
int[] dbgValBuf = new int[4];

int dbgType = -1;
int dbgS1   = -1;
int dbgS2   = -1;
int dbgEdge01 = -1;
int dbgSample = -1;
long dbgErr32U = 0;     // unsigned view (0..2^32-1)
boolean dbgHaveErr = false;

int dbgKVCount = 0;      // count TLV items (tag+value)
int dbgFrameCount = 0;   // count full frames (when A9 arrives)
int dbgLastMs = 0;
String dbgMsg = "waiting TLV (A5/A6/A7/A8/AA/A9)...";

// history of last frames
final int DBG_HIST_MAX = 32;
int[]  dbgHistType   = new int[DBG_HIST_MAX];
int[]  dbgHistS1     = new int[DBG_HIST_MAX];
int[]  dbgHistS2     = new int[DBG_HIST_MAX];
int[]  dbgHistEdge01 = new int[DBG_HIST_MAX];
int[]  dbgHistSample = new int[DBG_HIST_MAX];
long[] dbgHistErr32U = new long[DBG_HIST_MAX];
int[]  dbgHistMs     = new int[DBG_HIST_MAX];
int dbgHistN = 0;

// ======================================================
// RX framed packets: FF FF LEN(2) SEQ(1) PAYLOAD LEN bytes CHK(1)
// CHK = SUM8(payload) & 0xFF
// ======================================================
final int MAX_PAYLOAD = 4096;

enum RxState { FIND_FF1, FIND_FF2, LEN0, LEN1, SEQ, PAYLOAD, CHK }
RxState st = RxState.FIND_FF1;

int expectLen = 0;
int seqRx = 0;

byte[] payload = new byte[MAX_PAYLOAD];
int payIdx = 0;

int chkCalc = 0;
int chkRx   = 0;

int pktOK = 0, pktBad = 0, badLen = 0;
int lastSeq = -1;
int lost = 0;

int lastPktMs = 0;
String statusMsg = "idle";
String verifyMsg = "";

// fast read
byte[] inBuf = new byte[8192];
int lastByteMs = 0;
final int PARSER_TIMEOUT_MS = 120;

// ======================================================
// Storage for NODE packet (0xA1)
// ======================================================
final int MAX_NODES = 64;
final int MASK_BYTES = 8;

boolean haveNodes = false;
int nodeN = 0;
boolean[] nodeActive = new boolean[MAX_NODES];
float[] nodeX = new float[MAX_NODES];
float[] nodeY = new float[MAX_NODES];
int stepA1 = 0;

// ======================================================
// Storage for EDGE packet (0xB1)
// ======================================================
boolean haveEdges = false;
int edgeNNodes = 0;
int edgeCount = 0;

int[] edgeI = new int[2048];
int[] edgeJ = new int[2048];
int[] edgeAge = new int[2048];
boolean[] edgeSeen = new boolean[2048];

// base table for inverse mapping
int[] edgeBase = new int[MAX_NODES];

// ======================================================
// UI
// ======================================================
int scroll = 0;
final int LINES_PER_PAGE = 26;

float viewMinX, viewMaxX, viewMinY, viewMaxY;

// ======================================================
// Setup
// ======================================================
void setup() {
  size(1400, 780);
  surface.setTitle("GNG Viewer (framed A1/B1) + DEBUG TLV (A5/A6/A7/A8/AA/A9)");
  textFont(createFont("Consolas", 14));
  frameRate(60);

  println("Available ports:");
  println(Serial.list());

  if (TX_BYTES != 400) {
    println("ERROR: TX_BYTES must be 400. Now=" + TX_BYTES);
    exit();
  }

  buildTwoMoonsAndPack();

  myPort = new Serial(this, PORT_NAME, BAUD);
  delay(200);

  sendDatasetOnce();
}

void draw() {
  background(18);
  drawPanels();
  drawDebugBar();

  // timeout rescue for framed parser ONLY
  if (st != RxState.FIND_FF1 && (millis() - lastByteMs) > PARSER_TIMEOUT_MS) {
    resetParser();
    statusMsg = "Framed parser reset (timeout) -> resync";
  }
}

void keyPressed() {
  if (key == 'r' || key == 'R') {
    buildTwoMoonsAndPack();
    sendDatasetOnce();
  } else if (key == 's' || key == 'S') {
    sendDatasetOnce();
  } else if (key == 'p' || key == 'P') {
    printNodesToConsole();
    printEdgesToConsole(30);
    printDbgToConsole();
  } else if (keyCode == UP) {
    scroll = max(0, scroll - 1);
  } else if (keyCode == DOWN) {
    scroll = min(2000, scroll + 1);
  }
}

// ======================================================
// TX
// ======================================================
void sendDatasetOnce() {
  resetParser();

  // reset framed results
  haveNodes = false;
  haveEdges = false;
  nodeN = 0;
  edgeCount = 0;
  for (int i=0;i<MAX_NODES;i++) nodeActive[i] = false;
  for (int i=0;i<edgeSeen.length;i++) edgeSeen[i] = false;

  // reset debug TLV
  dbgTag = 0;
  dbgNeed = 0;
  dbgGot = 0;

  dbgType = -1;
  dbgS1 = -1;
  dbgS2 = -1;
  dbgEdge01 = -1;
  dbgSample = -1;
  dbgErr32U = 0;
  dbgHaveErr = false;

  dbgKVCount = 0;
  dbgFrameCount = 0;
  dbgLastMs = 0;
  dbgMsg = "waiting TLV (A5/A6/A7/A8/AA/A9)...";
  dbgHistN = 0;

  scroll = 0;

  statusMsg = "TX: sent 400 bytes. Waiting TLV debug or framed A1/B1...";
  myPort.write(txBuf);
}

// ======================================================
// Serial receive
// ======================================================
void serialEvent(Serial p) {
  int n = p.readBytes(inBuf);
  if (n <= 0) return;

  lastByteMs = millis();

  for (int i=0; i<n; i++) {
    int ub = inBuf[i] & 0xFF;

    // ======================================================
    // DEBUG TLV parser (tag,value)
    // Only intercept when framed parser is idle/resync (FIND_FF1)
    // ======================================================
    if (st == RxState.FIND_FF1) {

      // If we are collecting a value (1B or 4B)
      if (dbgNeed > 0) {
        dbgValBuf[dbgGot++] = ub;
        if (dbgGot >= dbgNeed) {
          onDbgTLV(dbgTag, dbgValBuf, dbgNeed);
          dbgNeed = 0;
          dbgGot  = 0;
          dbgTag  = 0;
        }
        continue; // do NOT feed framed parser
      }

      // Detect tag start
      if (ub == TAG_A5 || ub == TAG_A6 || ub == TAG_A7 || ub == TAG_A8 || ub == TAG_AA || ub == TAG_A9) {
        dbgTag = ub;
        dbgNeed = (ub == TAG_AA) ? 4 : 1;
        dbgGot = 0;
        continue; // do NOT feed framed parser
      }
    }

    // otherwise feed framed packet parser (FF FF LEN ...)
    feedParser(ub);
  }
}

void onDbgTLV(int tag, int[] v, int n) {
  dbgKVCount++;
  dbgLastMs = millis();

  // Optional: when A5 arrives, treat it as "start of a new frame"
  if (tag == TAG_A5) {
    dbgS1 = -1;
    dbgS2 = -1;
    dbgEdge01 = -1;
    dbgSample = -1;
    dbgErr32U = 0;
    dbgHaveErr = false;
  }

  if (tag == TAG_A5) dbgType = v[0] & 0xFF;
  if (tag == TAG_A6) dbgS1   = v[0] & 0xFF;
  if (tag == TAG_A7) dbgS2   = v[0] & 0xFF;
  if (tag == TAG_A8) dbgEdge01 = v[0] & 0xFF;

  if (tag == TAG_AA) {
    // little-endian u32
    long x = (long)(v[0] & 0xFF)
           | ((long)(v[1] & 0xFF) << 8)
           | ((long)(v[2] & 0xFF) << 16)
           | ((long)(v[3] & 0xFF) << 24);
    dbgErr32U = x & 0xFFFFFFFFL;
    dbgHaveErr = true;
  }

  if (tag == TAG_A9) dbgSample = v[0] & 0xFF;

  // Build message continuously
  String errStr = dbgHaveErr ? ("" + dbgErr32U + " (0x" + hex((int)dbgErr32U, 8) + ")") : "-";
  dbgMsg = "type=0x" + hex(max(dbgType,0),2) +
           " s1=" + dbgS1 + " s2=" + dbgS2 +
           " edge01=" + dbgEdge01 +
           " err32=" + errStr +
           " samp=" + dbgSample;

  // A9 dianggap "end of frame"
  if (tag == TAG_A9) {
    dbgFrameCount++;
    statusMsg = "Got DBG frame: " + dbgMsg;
    pushDbgHistory();
  }
}

void pushDbgHistory() {
  int t = dbgType;
  int s1 = dbgS1;
  int s2 = dbgS2;
  int e01 = dbgEdge01;
  int smp = dbgSample;
  long er = dbgHaveErr ? dbgErr32U : 0;
  int ms = dbgLastMs;

  if (dbgHistN < DBG_HIST_MAX) {
    dbgHistType[dbgHistN]   = t;
    dbgHistS1[dbgHistN]     = s1;
    dbgHistS2[dbgHistN]     = s2;
    dbgHistEdge01[dbgHistN] = e01;
    dbgHistSample[dbgHistN] = smp;
    dbgHistErr32U[dbgHistN] = er;
    dbgHistMs[dbgHistN]     = ms;
    dbgHistN++;
  } else {
    for (int k=0; k<DBG_HIST_MAX-1; k++) {
      dbgHistType[k]   = dbgHistType[k+1];
      dbgHistS1[k]     = dbgHistS1[k+1];
      dbgHistS2[k]     = dbgHistS2[k+1];
      dbgHistEdge01[k] = dbgHistEdge01[k+1];
      dbgHistSample[k] = dbgHistSample[k+1];
      dbgHistErr32U[k] = dbgHistErr32U[k+1];
      dbgHistMs[k]     = dbgHistMs[k+1];
    }
    int last = DBG_HIST_MAX-1;
    dbgHistType[last]   = t;
    dbgHistS1[last]     = s1;
    dbgHistS2[last]     = s2;
    dbgHistEdge01[last] = e01;
    dbgHistSample[last] = smp;
    dbgHistErr32U[last] = er;
    dbgHistMs[last]     = ms;
  }
}

// ======================================================
// Framed Parser (unchanged)
// ======================================================
void feedParser(int ub) {
  switch(st) {
    case FIND_FF1:
      if (ub == 0xFF) st = RxState.FIND_FF2;
      break;
    case FIND_FF2:
      if (ub == 0xFF) st = RxState.LEN0;
      else st = RxState.FIND_FF1;
      break;
    case LEN0:
      expectLen = ub;
      st = RxState.LEN1;
      break;
    case LEN1:
      expectLen |= (ub << 8);
      if (expectLen <= 0 || expectLen > MAX_PAYLOAD) {
        badLen++; pktBad++;
        resetParser();
      } else st = RxState.SEQ;
      break;
    case SEQ:
      seqRx = ub;
      payIdx = 0;
      chkCalc = 0;
      st = RxState.PAYLOAD;
      break;
    case PAYLOAD:
      payload[payIdx++] = (byte)ub;
      chkCalc = (chkCalc + ub) & 0xFF;
      if (payIdx >= expectLen) st = RxState.CHK;
      break;
    case CHK:
      chkRx = ub;
      if ((chkCalc & 0xFF) == (chkRx & 0xFF)) {
        pktOK++;
        lastPktMs = millis();
        onGoodPacket(seqRx, expectLen);
      } else pktBad++;
      resetParser();
      break;
  }
}

void resetParser() {
  st = RxState.FIND_FF1;
  expectLen = 0;
  payIdx = 0;
  chkCalc = 0;
  chkRx = 0;
}

void onGoodPacket(int seq, int len) {
  // seq tracking
  if (lastSeq >= 0) {
    int diff = (seq - lastSeq) & 0xFF;
    if (diff != 1) lost += ((diff - 1) & 0xFF);
  }
  lastSeq = seq;

  if (len < 1) return;
  int type = payload[0] & 0xFF;

  if (type == PKT_TYPE_NODE) {
    if (decodeNodesA1(len)) {
      verifyMsg = "0xA1 OK: NN=" + nodeN + " step=" + stepA1;
      statusMsg = "Got 0xA1 nodes.";
    } else {
      verifyMsg = "0xA1 decode FAILED len=" + len;
      pktBad++;
    }
    return;
  }

  if (type == PKT_TYPE_EDGE) {
    if (decodeEdgesB1(len)) {
      verifyMsg = "0xB1 OK: NN=" + edgeNNodes + " edges=" + edgeCount;
      statusMsg = "Got 0xB1 edges.";
    } else {
      verifyMsg = "0xB1 decode FAILED len=" + len;
      pktBad++;
    }
    return;
  }

  verifyMsg = "Unknown framed type=0x" + hex(type,2) + " len=" + len;
}

// ======================================================
// Decode 0xA1 nodes (unchanged)
// ======================================================
boolean decodeNodesA1(int len) {
  int p = 0;
  int type = payload[p++] & 0xFF;
  if (type != PKT_TYPE_NODE) return false;

  if (p + 2 + 1 + 1 + MASK_BYTES > len) return false;

  int stepL = payload[p++] & 0xFF;
  int stepH = payload[p++] & 0xFF;
  stepA1 = stepL | (stepH << 8);

  int NN = payload[p++] & 0xFF;
  int degN = payload[p++] & 0xFF; // unused

  if (NN <= 0 || NN > MAX_NODES) return false;
  nodeN = NN;

  int[] mask = new int[MASK_BYTES];
  for (int i=0;i<MASK_BYTES;i++) mask[i] = payload[p++] & 0xFF;

  int need = 1 + 2 + 1 + 1 + MASK_BYTES + (NN * 4);
  if (len < need) return false;

  for (int i=0;i<NN;i++) {
    int xLo = payload[p++] & 0xFF;
    int xHi = payload[p++] & 0xFF;
    int yLo = payload[p++] & 0xFF;
    int yHi = payload[p++] & 0xFF;

    int xi = (short)(xLo | (xHi << 8));
    int yi = (short)(yLo | (yHi << 8));

    nodeX[i] = xi / SCALE;
    nodeY[i] = yi / SCALE;
  }

  for (int i=0;i<MAX_NODES;i++) nodeActive[i] = false;
  for (int i=0;i<NN;i++) {
    int b = mask[i/8];
    int bit = (b >> (i % 8)) & 1;
    nodeActive[i] = (bit == 1);
  }

  haveNodes = true;
  return true;
}

// ======================================================
// Edge base helper (unchanged)
// ======================================================
void buildEdgeBase(int N) {
  int acc = 0;
  for (int i=0;i<N;i++) {
    edgeBase[i] = acc;
    acc += (N - 1 - i);
  }
}

int findIFromIdx(int idx, int N) {
  int i = 0;
  while (i+1 < N && idx >= edgeBase[i+1]) i++;
  return i;
}

// ======================================================
// Decode 0xB1 edges (unchanged)
// ======================================================
boolean decodeEdgesB1(int len) {
  int p = 0;
  int type = payload[p++] & 0xFF;
  if (type != PKT_TYPE_EDGE) return false;

  if (p + 1 + 2 > len) return false;

  int NN = payload[p++] & 0xFF;
  int ecL = payload[p++] & 0xFF;
  int ecH = payload[p++] & 0xFF;
  int EC = ecL | (ecH << 8);

  if (NN <= 0 || NN > MAX_NODES) return false;
  if (EC <= 0 || EC > edgeSeen.length) return false;

  int need = 1 + 1 + 2 + (EC * 3);
  if (len < need) return false;

  edgeNNodes = NN;
  edgeCount  = EC;

  for (int i=0;i<edgeSeen.length;i++) edgeSeen[i] = false;

  buildEdgeBase(NN);

  for (int k=0;k<EC;k++) {
    int idxL = payload[p++] & 0xFF;
    int idxH = payload[p++] & 0xFF;
    int age  = payload[p++] & 0xFF;

    int idx = idxL | (idxH << 8);
    if (idx < 0 || idx >= EC) continue;

    int ii = findIFromIdx(idx, NN);
    int off = idx - edgeBase[ii];
    int jj = ii + 1 + off;
    if (jj < 0 || jj >= NN) continue;

    edgeI[idx] = ii;
    edgeJ[idx] = jj;
    edgeAge[idx] = age;
    edgeSeen[idx] = true;
  }

  haveEdges = true;
  return true;
}

// ======================================================
// UI
// ======================================================
void drawPanels() {
  float leftX  = 60;
  float rightX = 740;
  float panelY = 80;
  float panelW = 600;
  float panelH = 600;

  fill(230);
  text("TX DATASET (static)", leftX, 55);
  drawScatter(moonsTx, leftX, panelY, panelW, panelH, 255, 5);

  fill(230);
  text("RX: framed A1/B1 (later) + DEBUG TLV (now)", rightX, 55);
  drawScatter(moonsTx, rightX, panelY, panelW, panelH, 70, 4);

  drawGraphOverlay(rightX, panelY, panelW, panelH);

  // info box
  fill(0, 160);
  noStroke();
  rect(rightX + 20, panelY + 20, panelW - 40, 230);

  fill(220);
  int yy = (int)(panelY + 45);

  text("DBG: " + dbgMsg + "  (frames=" + dbgFrameCount + ", kv=" + dbgKVCount + ")", rightX + 30, yy); yy += 18;

  text("Nodes: " + (haveNodes ? ("OK (NN=" + nodeN + ", step=" + stepA1 + ")") : "waiting 0xA1..."),
       rightX + 30, yy); yy += 18;
  text("Edges: " + (haveEdges ? ("OK (EC=" + edgeCount + ", NN=" + edgeNNodes + ")") : "waiting 0xB1..."),
       rightX + 30, yy); yy += 18;

  yy += 8;
  text("Last DBG frames:", rightX + 30, yy); yy += 16;

  int show = min(dbgHistN, 8);
  for (int k=0; k<show; k++) {
    int idx = dbgHistN - show + k;
    String line = "  " + k + ") samp=" + dbgHistSample[idx] +
                  " s1=" + dbgHistS1[idx] +
                  " s2=" + dbgHistS2[idx] +
                  " edge01=" + dbgHistEdge01[idx] +
                  " err32=" + dbgHistErr32U[idx] +
                  " type=0x" + hex(max(dbgHistType[idx],0),2);
    text(line, rightX + 30, yy);
    yy += 16;
  }

  noFill();
  stroke(60);
  rect(leftX, panelY, panelW, panelH);
  rect(rightX, panelY, panelW, panelH);
}

void drawGraphOverlay(float x0, float y0, float w, float h) {
  if (!haveNodes) return;

  // edges
  if (haveEdges) {
    for (int idx=0; idx<edgeCount; idx++) {
      if (!edgeSeen[idx]) continue;
      int age = edgeAge[idx] & 0xFF;
      if (age == 0) continue;

      int i = edgeI[idx];
      int j = edgeJ[idx];
      if (i < 0 || j < 0 || i >= nodeN || j >= nodeN) continue;
      if (!nodeActive[i] || !nodeActive[j]) continue;

      float x1 = mapToPanelX(nodeX[i], x0, w);
      float y1 = mapToPanelY(nodeY[i], y0, h);  // FIX: y0
      float x2 = mapToPanelX(nodeX[j], x0, w);
      float y2 = mapToPanelY(nodeY[j], y0, h);  // FIX: y0

      int a = (int)map(constrain(age, 1, 255), 1, 255, 220, 40);
      stroke(255, a);
      line(x1, y1, x2, y2);
    }
  }

  // nodes
  noStroke();
  for (int i=0;i<nodeN;i++) {
    float px = mapToPanelX(nodeX[i], x0, w);
    float py = mapToPanelY(nodeY[i], y0, h); // FIX: y0

    if (nodeActive[i]) fill(255, 220);
    else              fill(120, 120);

    ellipse(px, py, 9, 9);

    fill(220, 200);
    text(nf(i,2), px + 6, py - 6);
  }
}

float mapToPanelX(float x, float x0, float w) {
  float xn = (x - viewMinX) / (viewMaxX - viewMinX);
  return x0 + 10 + xn * (w - 20);
}
float mapToPanelY(float y, float y0, float h) {
  float yn = (y - viewMinY) / (viewMaxY - viewMinY);
  return y0 + 10 + yn * (h - 20);
}

void drawScatter(float[][] pts, float x0, float y0, float w, float h, int alpha, float dotSize) {
  if (pts != null) {
    float minx=1e9, maxx=-1e9, miny=1e9, maxy=-1e9;
    for (int i=0; i<pts.length; i++) {
      float x=pts[i][0], y=pts[i][1];
      minx=min(minx,x); maxx=max(maxx,x);
      miny=min(miny,y); maxy=max(maxy,y);
    }
    viewMinX=minx-0.35; viewMaxX=maxx+0.35;
    viewMinY=miny-0.35; viewMaxY=maxy+0.35;
  }

  noStroke();
  fill(0, 0, 0, 110);
  rect(x0, y0, w, h);

  stroke(70);
  float xZero = map(0, viewMinX, viewMaxX, x0, x0 + w);
  float yZero = map(0, viewMinY, viewMaxY, y0, y0 + h);
  line(x0, yZero, x0 + w, yZero);
  line(xZero, y0, xZero, y0 + h);

  if (pts == null) return;
  noStroke();
  fill(255, alpha);
  for (int i=0; i<pts.length; i++) {
    float px = mapToPanelX(pts[i][0], x0, w);
    float py = mapToPanelY(pts[i][1], y0, h);
    ellipse(px, py, dotSize, dotSize);
  }
}

void drawDebugBar() {
  fill(0, 180);
  rect(0, height - 90, width, 90);

  fill(220);
  text("PORT=" + PORT_NAME + " BAUD=" + BAUD +
       " framed_state=" + st +
       " payload(" + payIdx + "/" + expectLen + ")", 30, height - 60);

  int ago = (lastPktMs == 0) ? -1 : (millis() - lastPktMs);
  int dbgAgo = (dbgLastMs == 0) ? -1 : (millis() - dbgLastMs);

  text("FRAMED: OK=" + pktOK + " BAD=" + pktBad + " LOST~=" + lost +
       " RX_age(ms)=" + ago +
       " | DBG: age(ms)=" + dbgAgo +
       " frames=" + dbgFrameCount +
       " lastErr=" + (dbgHaveErr ? ("" + dbgErr32U) : "-"),
       30, height - 40);

  fill(180, 220, 255);
  text(verifyMsg, 30, height - 20);

  fill(180);
  text("Keys: [R]=rebuild+send [S]=send [P]=print nodes/edges/dbg",
       820, height - 20);
}

// ======================================================
// Debug prints
// ======================================================
void printDbgToConsole() {
  println("====================================================");
  println("DBG TLV: frames=" + dbgFrameCount + " kv=" + dbgKVCount + " last=" + dbgMsg);
  int show = min(dbgHistN, 16);
  for (int k=0; k<show; k++) {
    int idx = dbgHistN - show + k;
    println("  " + k + ") samp=" + dbgHistSample[idx] +
            " s1=" + dbgHistS1[idx] +
            " s2=" + dbgHistS2[idx] +
            " edge01=" + dbgHistEdge01[idx] +
            " err32=" + dbgHistErr32U[idx] +
            " type=0x" + hex(max(dbgHistType[idx],0),2));
  }
  println("====================================================");
}

void printNodesToConsole() {
  println("====================================================");
  println("0xA1 NODES (NN=" + nodeN + ") have=" + haveNodes);
  for (int i=0;i<nodeN;i++) {
    println("node " + nf(i,2) + " active=" + (nodeActive[i] ? "1" : "0") +
            "  x=" + nf(nodeX[i],1,4) + " y=" + nf(nodeY[i],1,4));
  }
  println("====================================================");
}

void printEdgesToConsole(int maxPrint) {
  println("====================================================");
  println("0xB1 EDGES (EC=" + edgeCount + ") have=" + haveEdges);
  int c = 0;
  for (int idx=0; idx<edgeCount && c<maxPrint; idx++) {
    if (!edgeSeen[idx]) continue;
    int age = edgeAge[idx] & 0xFF;
    if (age == 0) continue;
    println("idx=" + idx + "  (" + edgeI[idx] + "," + edgeJ[idx] + ")  age=" + age);
    c++;
  }
  println("====================================================");
}

// ======================================================
// Build dataset + pack (unchanged)
// ======================================================
void buildTwoMoonsAndPack() {
  moonsTx = generateMoons(
    MOONS_N,
    MOONS_RANDOM_ANGLE,
    MOONS_NOISE_STD,
    MOONS_SEED,
    MOONS_SHUFFLE,
    MOONS_NORMALIZE01
  );

  int p = 0;
  for (int i = 0; i < MOONS_N; i++) {
    short xi = (short)round(moonsTx[i][0] * SCALE);
    short yi = (short)round(moonsTx[i][1] * SCALE);

    txBuf[p++] = (byte)(xi & 0xFF);
    txBuf[p++] = (byte)((xi >> 8) & 0xFF);
    txBuf[p++] = (byte)(yi & 0xFF);
    txBuf[p++] = (byte)((yi >> 8) & 0xFF);
  }
}

// ======================================================
// Two-moons generator (unchanged)
// ======================================================
float[][] generateMoons(int N, boolean randomAngle, float noiseStd, int seed,
                        boolean shuffle, boolean normalize01) {
  float[][] arr = new float[N][2];
  randomSeed(seed);

  for (int i=0; i<N/2; i++) {
    float t = randomAngle ? random(PI) : map(i, 0, (N/2)-1, 0, PI);
    arr[i][0] = cos(t);
    arr[i][1] = sin(t);
  }
  for (int i=N/2; i<N; i++) {
    int j = i - N/2;
    float t = randomAngle ? random(PI) : map(j, 0, (N/2)-1, 0, PI);
    arr[i][0] = 1 - cos(t);
    arr[i][1] = -sin(t) + 0.5;
  }

  if (noiseStd > 0.0) {
    for (int i=0; i<N; i++) {
      arr[i][0] += (float)randomGaussian() * noiseStd;
      arr[i][1] += (float)randomGaussian() * noiseStd;
    }
  }

  if (normalize01) {
    float minx=999, maxx=-999, miny=999, maxy=-999;
    for (int i=0; i<N; i++) {
      float x=arr[i][0], y=arr[i][1];
      minx=min(minx,x); maxx=max(maxx,x);
      miny=min(miny,y); maxy=max(maxy,y);
    }
    float dx = max(1e-9, maxx-minx);
    float dy = max(1e-9, maxy-miny);
    for (int i=0; i<N; i++) {
      arr[i][0] = (arr[i][0]-minx)/dx;
      arr[i][1] = (arr[i][1]-miny)/dy;
    }
  }

  if (shuffle) {
    for (int i=N-1; i>0; i--) {
      int j = (int)random(i+1);
      float tx=arr[i][0], ty=arr[i][1];
      arr[i][0]=arr[j][0]; arr[i][1]=arr[j][1];
      arr[j][0]=tx;        arr[j][1]=ty;
    }
  }
  return arr;
}
