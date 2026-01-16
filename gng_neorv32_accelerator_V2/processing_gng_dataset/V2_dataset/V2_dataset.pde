import processing.serial.*;

// ======================================================
// Serial config
// ======================================================
Serial myPort;
final String PORT_NAME = "COM1";     // <-- GANTI sesuai Serial.list()
final int    BAUD      = 1_000_000;

// ======================================================
// Dataset options (SAMA PERSIS seperti yang kamu kirim)
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
// Data arrays (REUSE, no new each packet)
// ======================================================
float[][] moonsTx;
float[][] moonsRx = new float[MOONS_N][2];

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
  surface.setTitle("TX -> FPGA -> RX (Two Moons, FIXED AXIS, Y normal)");

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
  // Jika LIMIT shift di FPGA besar (misal 0.8), naikkan marginX.
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

  drawPointsPanelsFixedAxis();
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
    // enlarge X margin quickly for big shift tests
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

  statusMsg = "TX: sent 400 bytes (dataset). Waiting stream...";
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

  // decode only if len == 400
  if (len != TX_BYTES) {
    badLen++;
    verifyMsg = "CHK OK but LEN!=" + TX_BYTES + " (len=" + len + ")";
    return;
  }

  // decode payload -> moonsRx
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

  // centroid delta (helps confirm shift)
  float[] cTx = centroid(moonsTx);
  float[] cRx = centroid(moonsRx);

  verifyMsg = "OK seq=" + seq +
              " len=" + len +
              " ok=" + pktOK +
              " bad=" + pktBad +
              " lost~=" + lost +
              " badLen=" + badLen +
              "  dC=(" + nf(cRx[0]-cTx[0],1,3) + "," + nf(cRx[1]-cTx[1],1,3) + ")";
}

// ======================================================
// Build dataset + pack 400 bytes (SAMA PERSIS DENGAN KODE KAMU)
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
// Drawing (FIXED AXIS, Y normal / tidak dibalik)
// ======================================================
void drawPointsPanelsFixedAxis() {
  float leftX  = 60;
  float rightX = 740;

  fill(230);
  text("TX DATASET (static)", leftX, 55);
  drawScatterFixed(moonsTx, leftX, panelY, panelW, panelH);

  fill(230);
  text("RX FROM FPGA", rightX, 55);
  drawScatterFixed(moonsRx, rightX, panelY, panelW, panelH);

  // border
  noFill();
  stroke(60);
  rect(leftX, panelY, panelW, panelH);
  rect(rightX, panelY, panelW, panelH);
}

void drawScatterFixed(float[][] pts, float x0, float y0, float w, float h) {
  noStroke();
  fill(0, 0, 0, 110);
  rect(x0, y0, w, h);

  // axis cross at x=0,y=0 (Y normal: top-down)
  stroke(70);

  float xZero = map(0, viewMinX, viewMaxX, x0, x0 + w);
  float yZero = map(0, viewMinY, viewMaxY, y0, y0 + h);

  line(x0, yZero, x0 + w, yZero);
  line(xZero, y0, xZero, y0 + h);

  if (pts == null) return;

  noStroke();
  fill(255);
  for (int i = 0; i < pts.length; i++) {
    float xn = (pts[i][0] - viewMinX) / (viewMaxX - viewMinX);
    float yn = (pts[i][1] - viewMinY) / (viewMaxY - viewMinY);

    float px = x0 + 10 + xn * (w - 20);
    float py = y0 + 10 + yn * (h - 20);  // ✅ Y tidak dibalik

    ellipse(px, py, 5, 5);
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
// Two-moons generator (SAMA PERSIS DENGAN KODE KAMU)
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
