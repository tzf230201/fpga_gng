import processing.serial.*;

// ===============================
// Serial config
// ===============================
Serial myPort;
final String PORT_NAME = "COM1";
final int    BAUD      = 1_000_000;

// ===============================
// Dataset options (TX side)
// ===============================
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

// ===============================
// Live packet RX (FF FF LEN SEQ PAYLOAD CHK)
// ===============================
final int MAX_PAYLOAD = 4096;

enum RxState { FIND_FF1, FIND_FF2, LEN0, LEN1, SEQ, PAYLOAD, CHK }
RxState st = RxState.FIND_FF1;

int expectLen = 0;
int seqRx = 0;

byte[] payload = new byte[MAX_PAYLOAD];
int payIdx = 0;

int chkCalc = 0; // SUM8 over payload bytes
int chkRx   = 0;

float[][] moonsTx;
float[][] moonsRx = new float[MOONS_N][2]; // <-- REUSE, no new per packet

int pktOK = 0, pktBad = 0, badLen = 0;
int lastSeq = -1;
int lost = 0;

int lastPktMs = 0;
String statusMsg = "idle";
String verifyMsg = "";

// ignore streaming right after sending TX (to avoid echo/garbage at start)
final int IGNORE_AFTER_SEND_MS = 80;
int tSendMs = 0;
boolean ignoreRx = true;

// ===============================
// Faster serial reading
// ===============================
byte[] inBuf = new byte[8192];
int lastByteMs = 0;

// timeout to auto reset parser if stuck
final int PARSER_TIMEOUT_MS = 120;

// ===============================
// Setup / Draw
// ===============================
void setup() {
  size(1000, 600);
  surface.setTitle("TX dataset -> FPGA streams packets live (FAST + timeout + no-GC)");

  println("Available ports:");
  println(Serial.list());

  if (TX_BYTES != 400) {
    println("ERROR: TX_BYTES must be 400. Now = " + TX_BYTES);
    exit();
  }

  myPort = new Serial(this, PORT_NAME, BAUD);
  myPort.clear();
  // NOTE: some Processing versions don't support huge OS buffer reliably,
  // but keeping it is fine if available.
  // myPort.buffer(65536);
  delay(200);

  buildTwoMoonsAndPack();
  sendDatasetOnce();

  textFont(createFont("Consolas", 14));
  frameRate(60);
}

void draw() {
  background(25);
  drawPointsPanels();
  drawDebug();

  // after sending dataset, wait a bit before parsing stream
  if (ignoreRx && (millis() - tSendMs) > IGNORE_AFTER_SEND_MS) {
    ignoreRx = false;
    statusMsg = "listening live packets...";
  }

  // ---- Parser timeout rescue ----
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
    sendDatasetOnce();
  } else if (key == 's' || key == 'S') {
    sendDatasetOnce();
  } else if (key == 'c' || key == 'C') {
    pktOK=0; pktBad=0; badLen=0; lost=0; lastSeq=-1;
    statusMsg = "stats cleared";
  }
}

// ===============================
// TX
// ===============================
void sendDatasetOnce() {
  myPort.clear();
  resetParser();

  tSendMs = millis();
  ignoreRx = true;

  statusMsg = "TX: sent 400 bytes (dataset). Waiting stream...";
  myPort.write(txBuf);
}

// ===============================
// Serial receive (FAST chunk read)
// ===============================
void serialEvent(Serial p) {
  int n = p.readBytes(inBuf); // <-- FAST
  if (n <= 0) return;

  lastByteMs = millis();

  if (ignoreRx) return;

  for (int i = 0; i < n; i++) {
    feedParser(inBuf[i] & 0xFF);
  }
}

// ===============================
// Packet parser (byte by byte feed)
// ===============================
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

// ===============================
// called only when checksum OK
// ===============================
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

  // decode only if len == 400 (dataset)
  if (len != TX_BYTES) {
    badLen++;
    verifyMsg = "CHK OK but LEN!=" + TX_BYTES + " (len=" + len + ")";
    return;
  }

  // decode payload -> moonsRx (REUSE array)
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

  verifyMsg = "CHK OK  seq=" + seq +
              "  len=" + len +
              "  ok=" + pktOK +
              "  bad=" + pktBad +
              "  lost~=" + lost +
              "  badLen=" + badLen;
}

// ===============================
// Build dataset + pack 400 bytes
// ===============================
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

// ===============================
// Drawing
// ===============================
void drawPointsPanels() {
  fill(220);
  text("TX (dataset sent to FPGA)", 30, 30);
  drawScatter(moonsTx, 30, 50, 440, 500);

  fill(220);
  text("RX (FPGA stream decoded live)", 530, 30);
  drawScatter(moonsRx, 530, 50, 440, 500);
}

void drawScatter(float[][] pts, float x0, float y0, float w, float h) {
  noStroke();
  fill(0, 0, 0, 120);
  rect(x0, y0, w, h);

  if (pts == null) return;

  float minx=1e9, maxx=-1e9, miny=1e9, maxy=-1e9;
  for (int i = 0; i < pts.length; i++) {
    float x = pts[i][0], y = pts[i][1];
    if (x < minx) minx = x;
    if (x > maxx) maxx = x;
    if (y < miny) miny = y;
    if (y > maxy) maxy = y;
  }
  float dx = max(1e-6, maxx - minx);
  float dy = max(1e-6, maxy - miny);

  noStroke();
  fill(255);
  for (int i = 0; i < pts.length; i++) {
    float xn = (pts[i][0] - minx) / dx;
    float yn = (pts[i][1] - miny) / dy;
    float px = x0 + 10 + xn * (w - 20);
    float py = y0 + 10 + yn * (h - 20);
    ellipse(px, py, 5, 5);
  }
}

void drawDebug() {
  fill(0, 0, 0, 160);
  rect(0, height - 70, width, 70);

  fill(220);
  text("PORT=" + PORT_NAME + "  BAUD=" + BAUD +
       "  state=" + st +
       "  payload(" + payIdx + "/" + expectLen + ")", 20, height - 45);

  int ago = (lastPktMs == 0) ? -1 : (millis() - lastPktMs);
  text("Status: " + statusMsg + "   lastPkt(ms ago)=" + ago, 20, height - 25);

  fill(180, 220, 255);
  text(verifyMsg, 520, height - 25);
}

// ===============================
// Two-moons generator
// ===============================
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
