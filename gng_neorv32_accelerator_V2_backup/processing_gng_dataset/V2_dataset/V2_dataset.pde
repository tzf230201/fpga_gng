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
// Packet types (UPDATED)
// ======================================================
final int PKT_TYPE_EDGE = 0xB1; // edges dump
final int PKT_TYPE_NODE = 0xA1; // nodes dump

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
// payload A1 (as sent by your dumper):
// [0]=A1
// [1]=stepL [2]=stepH
// [3]=NN
// [4]=degN (unused)
// [5..]=MASK_BYTES (8 bytes)
// [..]=NN * 4 bytes: xL xH yL yH  (signed 16-bit each)
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
// payload B1 (as sent by your new dumper):
// [0]=B1
// [1]=NN
// [2]=EcntL [3]=EcntH
// then Ecnt times: idxL idxH age
// We decode idx -> (i,j) using half-adj base table.
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
  surface.setTitle("GNG Dump Viewer (0xA1 nodes + 0xB1 edges)");
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

  // timeout rescue
  if (st != RxState.FIND_FF1 && (millis() - lastByteMs) > PARSER_TIMEOUT_MS) {
    resetParser();
    statusMsg = "Parser reset (timeout) -> resync";
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

  haveNodes = false;
  haveEdges = false;
  nodeN = 0;
  edgeCount = 0;
  for (int i=0;i<MAX_NODES;i++) nodeActive[i] = false;
  for (int i=0;i<edgeSeen.length;i++) edgeSeen[i] = false;

  scroll = 0;

  statusMsg = "TX: sent 400 bytes. Waiting 0xA1 then 0xB1...";
  myPort.write(txBuf);
}

// ======================================================
// Serial receive
// ======================================================
void serialEvent(Serial p) {
  int n = p.readBytes(inBuf);
  if (n <= 0) return;

  lastByteMs = millis();
  for (int i=0; i<n; i++) feedParser(inBuf[i] & 0xFF);
}

// ======================================================
// Parser
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

  verifyMsg = "Unknown type=0x" + hex(type,2) + " len=" + len;
}

// ======================================================
// Decode 0xA1 nodes
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

  // mask bytes
  int[] mask = new int[MASK_BYTES];
  for (int i=0;i<MASK_BYTES;i++) mask[i] = payload[p++] & 0xFF;

  // decode nodes
  int need = 1 + 2 + 1 + 1 + MASK_BYTES + (NN * 4);
  if (len < need) return false;

  for (int i=0;i<NN;i++) {
    int xLo = payload[p++] & 0xFF;
    int xHi = payload[p++] & 0xFF;
    int yLo = payload[p++] & 0xFF;
    int yHi = payload[p++] & 0xFF;

    int xi = (short)(xLo | (xHi << 8)); // signed 16
    int yi = (short)(yLo | (yHi << 8));

    nodeX[i] = xi / SCALE; // IMPORTANT: same space as moonsTx (0..1)
    nodeY[i] = yi / SCALE;
  }

  // decode active bitset (LSB-first per byte)
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
// Build base table for half-adj indexing (inverse mapping helper)
// base(i) = sum_{k=0..i-1} (N-1-k)
// idx(i<j) = base(i) + (j-i-1)
// ======================================================
void buildEdgeBase(int N) {
  int acc = 0;
  for (int i=0;i<N;i++) {
    edgeBase[i] = acc;
    acc += (N - 1 - i);
  }
}

int findIFromIdx(int idx, int N) {
  // small N (40) => linear ok
  int i = 0;
  while (i+1 < N && idx >= edgeBase[i+1]) i++;
  return i;
}

// ======================================================
// Decode 0xB1 edges
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
  text("RX GRAPH: dataset + nodes (0xA1) + edges (0xB1)", rightX, 55);
  drawScatter(moonsTx, rightX, panelY, panelW, panelH, 70, 4);

  // overlay nodes+edges
  drawGraphOverlay(rightX, panelY, panelW, panelH);

  // info box
  fill(0, 160);
  noStroke();
  rect(rightX + 20, panelY + 20, panelW - 40, 150);

  fill(220);
  int yy = (int)(panelY + 45);
  text("Nodes: " + (haveNodes ? ("OK (NN=" + nodeN + ", step=" + stepA1 + ")") : "waiting 0xA1..."), rightX + 30, yy); yy += 18;
  text("Edges: " + (haveEdges ? ("OK (EC=" + edgeCount + ", NN=" + edgeNNodes + ")") : "waiting 0xB1..."), rightX + 30, yy); yy += 18;

  // small list: show first few active nodes
  if (haveNodes) {
    int shown = 0;
    for (int i=0;i<nodeN && shown<6;i++) {
      if (nodeActive[i]) {
        text("active node " + nf(i,2) + " : (" + nf(nodeX[i],1,3) + ", " + nf(nodeY[i],1,3) + ")", rightX + 30, yy);
        yy += 16;
        shown++;
      }
    }
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

      // biasanya age=0 berarti tidak ada edge
      if (age == 0) continue;

      int i = edgeI[idx];
      int j = edgeJ[idx];
      if (i < 0 || j < 0 || i >= nodeN || j >= nodeN) continue;
      if (!nodeActive[i] || !nodeActive[j]) continue;

      float x1 = mapToPanelX(nodeX[i], x0, w);
      float y1 = mapToPanelY(nodeY[i], y0, h);
      float x2 = mapToPanelX(nodeX[j], x0, w);
      float y2 = mapToPanelY(nodeY[j], y0, h);

      // alpha based on age (lebih tua => lebih gelap)
      int a = (int)map(constrain(age, 1, 255), 1, 255, 220, 40);
      stroke(255, a);
      line(x1, y1, x2, y2);
    }
  }

  // nodes
  noStroke();
  for (int i=0;i<nodeN;i++) {
    float px = mapToPanelX(nodeX[i], x0, w);
    float py = mapToPanelY(nodeY[i], y0, h);

    if (nodeActive[i]) fill(255, 220);
    else              fill(120, 120);

    ellipse(px, py, 9, 9);

    // label
    fill(220, 200);
    text(nf(i,2), px + 6, py - 6);
  }
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

float mapToPanelX(float x, float x0, float w) {
  float xn = (x - viewMinX) / (viewMaxX - viewMinX);
  return x0 + 10 + xn * (w - 20);
}
float mapToPanelY(float y, float y0, float h) {
  float yn = (y - viewMinY) / (viewMaxY - viewMinY);
  return y0 + 10 + yn * (h - 20);
}

void drawDebugBar() {
  fill(0, 180);
  rect(0, height - 90, width, 90);

  fill(220);
  text("PORT=" + PORT_NAME + " BAUD=" + BAUD +
       " state=" + st +
       " payload(" + payIdx + "/" + expectLen + ")", 30, height - 60);

  int ago = (lastPktMs == 0) ? -1 : (millis() - lastPktMs);
  text("PKT_OK=" + pktOK + " BAD=" + pktBad + " LOST~=" + lost +
       " RX_age(ms)=" + ago + "  " + statusMsg, 30, height - 40);

  fill(180, 220, 255);
  text(verifyMsg, 30, height - 20);

  fill(180);
  text("Keys: [R]=rebuild+send [S]=send [P]=print nodes+edges",
       860, height - 20);
}

// ======================================================
// Debug prints
// ======================================================
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
// Build dataset + pack
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
// Two-moons generator
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
