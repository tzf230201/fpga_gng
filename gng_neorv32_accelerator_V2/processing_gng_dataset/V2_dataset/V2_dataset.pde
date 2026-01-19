import processing.serial.*;

// ======================================================
// Serial config
// ======================================================
Serial myPort;
final String PORT_NAME = "COM1";     // <-- GANTI sesuai Serial.list()
final int    BAUD      = 1_000_000;

// ======================================================
// Dataset options (SAMA seperti sebelumnya)
// ======================================================
final int     MOONS_N            = 100;     // 100 points -> 400 bytes
final boolean MOONS_RANDOM_ANGLE = false;
final int     MOONS_SEED         = 1234;
final float   MOONS_NOISE_STD    = 0.06;
final boolean MOONS_SHUFFLE      = true;
final boolean MOONS_NORMALIZE01  = true;

final float SCALE = 1000.0;

final int BYTES_PER_POINT = 4;
final int TX_BYTES = MOONS_N * BYTES_PER_POINT; // 400
byte[] txBuf = new byte[TX_BYTES];

// ======================================================
// NEW: GNG state packet payload format
// ======================================================
final int PKT_TYPE_GNG = 0xA1;
final int MAX_NODES = 40;
final int MAX_DEG   = 6;

// payload length we expect from FPGA (recommended)
final int GNG_MASK_BYTES = 8; // support up to 64 nodes
final int GNG_PAYLOAD_LEN = 1 + 2 + 1 + 1 + GNG_MASK_BYTES + (MAX_NODES * 4) + (MAX_NODES * MAX_DEG * 2); // 653

// decoded GNG state
boolean[] gngActive = new boolean[MAX_NODES];
float[][] gngNodes  = new float[MAX_NODES][2];      // in "float" units (divide SCALE)
boolean[][] gngEdgeValid = new boolean[MAX_NODES][MAX_DEG];
int[][] gngEdgeNb   = new int[MAX_NODES][MAX_DEG];
int[][] gngEdgeAge  = new int[MAX_NODES][MAX_DEG];
int gngStep = 0;
int gngNodeN = MAX_NODES;
int gngDegN  = MAX_DEG;

boolean haveGng = false;

// ======================================================
// Live packet RX (FF FF LEN(2) SEQ(1) PAYLOAD LEN bytes CHK(1))
// CHK = SUM8(payload bytes) & 0xFF
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

// ignore RX right after sending TX (avoid garbage/echo)
final int IGNORE_AFTER_SEND_MS = 120;
int tSendMs = 0;
boolean ignoreRx = true;

// faster serial reading
byte[] inBuf = new byte[8192];
int lastByteMs = 0;

// timeout to auto reset parser if stuck
final int PARSER_TIMEOUT_MS = 120;

// ======================================================
// Data arrays
// ======================================================
float[][] moonsTx;
float[][] moonsRx = new float[MOONS_N][2]; // (optional fallback)

// ======================================================
// FIXED AXIS range (computed once from TX + margin)
// ======================================================
float viewMinX, viewMaxX, viewMinY, viewMaxY;

// ======================================================
// UI layout
// ======================================================
float panelY = 80;
float panelW = 600;
float panelH = 600;

void setup() {
  size(1400, 780);
  surface.setTitle("TX -> FPGA -> RX (GNG nodes+edges viewer)");

  textFont(createFont("Consolas", 14));
  frameRate(60);

  println("Available ports:");
  println(Serial.list());

  if (TX_BYTES != 400) {
    println("ERROR: TX_BYTES must be 400. Now = " + TX_BYTES);
    exit();
  }

  // Build dataset + pack
  buildTwoMoonsAndPack();

  // Compute fixed view from TX.
  computeFixedViewFromTx(0.35, 0.35);

  // Open serial
  myPort = new Serial(this, PORT_NAME, BAUD);
  myPort.clear();
  delay(200);

  // Send once
  sendDatasetOnce();
}

void draw() {
  background(18);

  drawPanels();
  drawDebugBar();

  // after sending dataset, wait a bit before parsing stream
  if (ignoreRx && (millis() - tSendMs) > IGNORE_AFTER_SEND_MS) {
    ignoreRx = false;
    statusMsg = "listening live packets...";
  }

  // parser timeout rescue
  if (!ignoreRx && st != RxState.FIND_FF1) {
    if ((millis() - lastByteMs) > PARSER_TIMEOUT_MS) {
      resetParser();
      statusMsg = "Parser reset (timeout) -> resync";
    }
  }
}

void keyPressed() {
  if (key == 'r' || key == 'R') {
    buildTwoMoonsAndPack();
    computeFixedViewFromTx(0.35, 0.35);
    sendDatasetOnce();
  } else if (key == 's' || key == 'S') {
    sendDatasetOnce();
  } else if (key == 'c' || key == 'C') {
    pktOK=0; pktBad=0; badLen=0; lost=0; lastSeq=-1;
    statusMsg = "stats cleared";
  } else if (key == '+' || key == '=') {
    float mx = (viewMaxX - viewMinX) * 0.1;
    viewMinX -= mx; viewMaxX += mx;
    statusMsg = "view marginX increased";
  } else if (key == '-') {
    float mx = (viewMaxX - viewMinX) * 0.08;
    viewMinX += mx; viewMaxX -= mx;
    statusMsg = "view marginX decreased";
  }
}

// ======================================================
// TX
// ======================================================
void sendDatasetOnce() {
  myPort.clear();
  resetParser();

  tSendMs = millis();
  ignoreRx = true;

  statusMsg = "TX: sent 400 bytes (dataset). Waiting GNG stream...";
  myPort.write(txBuf);
}

// ======================================================
// Serial receive (FAST chunk read)
// ======================================================
void serialEvent(Serial p) {
  int n = p.readBytes(inBuf);
  if (n <= 0) return;

  lastByteMs = millis();
  if (ignoreRx) return;

  for (int i = 0; i < n; i++) {
    feedParser(inBuf[i] & 0xFF);
  }
}

// ======================================================
// Packet parser
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
        badLen++;
        pktBad++;
        resetParser();
      } else {
        st = RxState.SEQ;
      }
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
      } else {
        pktBad++;
      }
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

// ======================================================
// called only when checksum OK
// ======================================================
void onGoodPacket(int seq, int len) {
  // SEQ tracking
  if (lastSeq >= 0) {
    int diff = (seq - lastSeq) & 0xFF;
    if (diff != 1) {
      int missed = (diff - 1) & 0xFF;
      lost += missed;
    }
  }
  lastSeq = seq;

  // 1) GNG state packet
  if (len >= 5 && (payload[0] & 0xFF) == PKT_TYPE_GNG) {
    if (!decodeGngState(len)) {
      pktBad++;
      verifyMsg = "GNG decode failed (len=" + len + ")";
    } else {
      int activeCnt = 0;
      for (int i=0;i<gngNodeN;i++) if (gngActive[i]) activeCnt++;

      int edgeDrawn = countUndirectedEdges();

      verifyMsg = "GNG OK seq=" + seq +
                  " step=" + gngStep +
                  " nodes(active)=" + activeCnt + "/" + gngNodeN +
                  " edges~=" + edgeDrawn +
                  " ok=" + pktOK +
                  " bad=" + pktBad +
                  " lost~=" + lost +
                  " badLen=" + badLen;
    }
    return;
  }

  // 2) (optional) old mode: dataset 400 bytes
  if (len == TX_BYTES) {
    int p = 0;
    for (int i = 0; i < MOONS_N; i++) {
      int xL = payload[p++] & 0xFF;
      int xH = payload[p++] & 0xFF;
      int yL = payload[p++] & 0xFF;
      int yH = payload[p++] & 0xFF;

      int xi = xL | (xH << 8);
      int yi = yL | (yH << 8);

      if (xi >= 32768) xi -= 65536;
      if (yi >= 32768) yi -= 65536;

      moonsRx[i][0] = xi / SCALE;
      moonsRx[i][1] = yi / SCALE;
    }

    float[] cTx = centroid(moonsTx);
    float[] cRx = centroid(moonsRx);

    verifyMsg = "DATA OK seq=" + seq +
                " len=" + len +
                " ok=" + pktOK +
                " bad=" + pktBad +
                " lost~=" + lost +
                " badLen=" + badLen +
                "  dC=(" + nf(cRx[0]-cTx[0],1,3) + "," + nf(cRx[1]-cTx[1],1,3) + ")";
    return;
  }

  // unknown len
  badLen++;
  verifyMsg = "CHK OK but unknown LEN=" + len;
}

// ======================================================
// Decode GNG state payload
// Payload spec:
// [0] type=0xA1
// [1..2] step u16 LE
// [3] nodeN
// [4] degN
// [5..12] active mask (8 bytes)
// [..] nodes (nodeN * 4): x s16 LE, y s16 LE
// [..] edges (nodeN*degN*2): edge word16 LE (same as edge_mem)
// ======================================================
boolean decodeGngState(int len) {
  int p = 0;
  int type = payload[p++] & 0xFF;
  if (type != PKT_TYPE_GNG) return false;

  if (p + 4 > len) return false;

  int stepL = payload[p++] & 0xFF;
  int stepH = payload[p++] & 0xFF;
  gngStep = stepL | (stepH << 8);

  gngNodeN = payload[p++] & 0xFF;
  gngDegN  = payload[p++] & 0xFF;

  if (gngNodeN > MAX_NODES) gngNodeN = MAX_NODES;
  if (gngDegN  > MAX_DEG)   gngDegN  = MAX_DEG;

  if (p + GNG_MASK_BYTES > len) return false;

  int[] mask = new int[GNG_MASK_BYTES];
  for (int i=0;i<GNG_MASK_BYTES;i++) mask[i] = payload[p++] & 0xFF;

  for (int i=0;i<MAX_NODES;i++) gngActive[i] = false;
  for (int i=0;i<gngNodeN;i++) {
    int b = mask[i >> 3];
    int bit = (b >> (i & 7)) & 1;
    gngActive[i] = (bit == 1);
  }

  // nodes
  int needNodes = gngNodeN * 4;
  if (p + needNodes > len) return false;

  for (int i=0;i<gngNodeN;i++) {
    int xL = payload[p++] & 0xFF;
    int xH = payload[p++] & 0xFF;
    int yL = payload[p++] & 0xFF;
    int yH = payload[p++] & 0xFF;

    int xi = xL | (xH << 8);
    int yi = yL | (yH << 8);

    if (xi >= 32768) xi -= 65536;
    if (yi >= 32768) yi -= 65536;

    gngNodes[i][0] = xi / SCALE;
    gngNodes[i][1] = yi / SCALE;
  }

  // edges
  int needEdges = gngNodeN * gngDegN * 2;
  if (p + needEdges > len) return false;

  for (int i=0;i<gngNodeN;i++) {
    for (int k=0;k<gngDegN;k++) {
      int wL = payload[p++] & 0xFF;
      int wH = payload[p++] & 0xFF;
      int w  = wL | (wH << 8);

      boolean vld = ((w >> 15) & 1) == 1;
      int age = (w >> 7) & 0xFF;
      int nb  = (w >> 1) & 0x3F;

      gngEdgeValid[i][k] = vld;
      gngEdgeAge[i][k]   = age;
      gngEdgeNb[i][k]    = nb;
    }
  }

  haveGng = true;
  return true;
}

int countUndirectedEdges() {
  int c = 0;
  for (int i=0;i<gngNodeN;i++) {
    if (!gngActive[i]) continue;
    for (int k=0;k<gngDegN;k++) {
      if (!gngEdgeValid[i][k]) continue;
      int nb = gngEdgeNb[i][k];
      if (nb < 0 || nb >= gngNodeN) continue;
      if (!gngActive[nb]) continue;
      if (i < nb) c++; // avoid duplicates
    }
  }
  return c;
}

// ======================================================
// Build dataset + pack 400 bytes
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
// FIXED VIEW range from TX + margin
// ======================================================
void computeFixedViewFromTx(float marginX, float marginY) {
  float minx=1e9, maxx=-1e9, miny=1e9, maxy=-1e9;
  for (int i=0; i<moonsTx.length; i++) {
    float x=moonsTx[i][0], y=moonsTx[i][1];
    if (x<minx) minx=x;
    if (x>maxx) maxx=x;
    if (y<miny) miny=y;
    if (y>maxy) maxy=y;
  }
  viewMinX = minx - marginX;
  viewMaxX = maxx + marginX;
  viewMinY = miny - marginY;
  viewMaxY = maxy + marginY;
}

// ======================================================
// Drawing panels
// ======================================================
void drawPanels() {
  float leftX  = 60;
  float rightX = 740;

  fill(230);
  text("TX DATASET (static)", leftX, 55);
  drawScatterFixed(moonsTx, leftX, panelY, panelW, panelH, 255, 5);

  fill(230);
  text("FPGA: GNG nodes + edges (overlay on dataset)", rightX, 55);

  // draw dataset faint as background reference
  drawScatterFixed(moonsTx, rightX, panelY, panelW, panelH, 120, 4);

  if (haveGng) {
    drawGngOverlay(rightX, panelY, panelW, panelH);
  } else {
    fill(180);
    text("waiting GNG_STATE packet (type 0xA1)...", rightX + 20, panelY + 30);
  }

  // border
  noFill();
  stroke(60);
  rect(leftX, panelY, panelW, panelH);
  rect(rightX, panelY, panelW, panelH);
}

void drawScatterFixed(float[][] pts, float x0, float y0, float w, float h, int alpha, float dotSize) {
  noStroke();
  fill(0, 0, 0, 110);
  rect(x0, y0, w, h);

  // axis cross at x=0,y=0
  stroke(70);
  float xZero = map(0, viewMinX, viewMaxX, x0, x0 + w);
  float yZero = map(0, viewMinY, viewMaxY, y0, y0 + h);
  line(x0, yZero, x0 + w, yZero);
  line(xZero, y0, xZero, y0 + h);

  if (pts == null) return;

  noStroke();
  fill(255, alpha);
  for (int i = 0; i < pts.length; i++) {
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
  return y0 + 10 + yn * (h - 20); // Y normal
}

void drawGngOverlay(float x0, float y0, float w, float h) {
  // draw edges first
  strokeWeight(2);

  for (int i=0;i<gngNodeN;i++) {
    if (!gngActive[i]) continue;

    float x1 = gngNodes[i][0];
    float y1 = gngNodes[i][1];
    float px1 = mapToPanelX(x1, x0, w);
    float py1 = mapToPanelY(y1, y0, h);

    for (int k=0;k<gngDegN;k++) {
      if (!gngEdgeValid[i][k]) continue;
      int nb = gngEdgeNb[i][k];
      if (nb < 0 || nb >= gngNodeN) continue;
      if (!gngActive[nb]) continue;

      // avoid duplicate drawing
      if (i >= nb) continue;

      float x2 = gngNodes[nb][0];
      float y2 = gngNodes[nb][1];
      float px2 = mapToPanelX(x2, x0, w);
      float py2 = mapToPanelY(y2, y0, h);

      int age = gngEdgeAge[i][k]; // 0..255
      int a = constrain(60 + age, 60, 220);

      stroke(120, 220, 255, a);
      line(px1, py1, px2, py2);
    }
  }

  // draw nodes on top
  noStroke();
  for (int i=0;i<gngNodeN;i++) {
    if (!gngActive[i]) continue;
    float px = mapToPanelX(gngNodes[i][0], x0, w);
    float py = mapToPanelY(gngNodes[i][1], y0, h);

    fill(255, 220, 80, 230);
    ellipse(px, py, 10, 10);

    fill(255, 180);
    text(i, px + 6, py - 6);
  }
}

// ======================================================
// Debug bar
// ======================================================
void drawDebugBar() {
  fill(0, 180);
  rect(0, height - 90, width, 90);

  fill(220);
  text("PORT=" + PORT_NAME + "  BAUD=" + BAUD +
       "  state=" + st +
       "  payload(" + payIdx + "/" + expectLen + ")", 30, height - 60);

  int ago = (lastPktMs == 0) ? -1 : (millis() - lastPktMs);
  text("PKT_OK=" + pktOK + "  BAD=" + pktBad + "  LOST~=" + lost +
       "  RX_age(ms)=" + ago + "   " + statusMsg, 30, height - 40);

  fill(180, 220, 255);
  text(verifyMsg, 30, height - 20);

  fill(180);
  text("Keys: [R]=rebuild+send  [S]=send  [C]=clear stats  [+/-]=adjust view X margin",
       740, height - 20);

  fill(180);
  text("Expecting GNG_STATE len=" + GNG_PAYLOAD_LEN + " (type=0xA1)", 740, height - 40);
}

// ======================================================
// Helpers
// ======================================================
float[] centroid(float[][] pts) {
  float sx=0, sy=0;
  int n=pts.length;
  for (int i=0;i<n;i++) { sx += pts[i][0]; sy += pts[i][1]; }
  return new float[]{ sx/n, sy/n };
}

// ======================================================
// Two-moons generator
// ======================================================
float[][] generateMoons(int N, boolean randomAngle, float noiseStd, int seed,
                        boolean shuffle, boolean normalize01) {
  float[][] arr = new float[N][2];

  randomSeed(seed);

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
    float dx = max(1e-9, maxx - minx);
    float dy = max(1e-9, maxy - miny);

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
