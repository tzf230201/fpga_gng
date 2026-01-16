import processing.serial.*;

// ======================================================
// SERIAL CONFIG
// ======================================================
Serial myPort;
final String PORT_NAME = "COM1";
final int    BAUD      = 1_000_000;

// ======================================================
// TWO MOONS SETTINGS (ASLI)
// ======================================================
final int     MOONS_N            = 100;
final boolean MOONS_RANDOM_ANGLE = false;
final int     MOONS_SEED         = 1234;
final float   MOONS_NOISE_STD    = 0.06;
final boolean MOONS_SHUFFLE      = true;
final boolean MOONS_NORMALIZE01  = true;

final float SCALE = 1000.0;
final int TX_BYTES = MOONS_N * 4; // 400

// ======================================================
// FIXED VIEW (NO AUTO NORMALIZE PER FRAME)
// ======================================================
final float VIEW_MIN_X = -0.3;
final float VIEW_MAX_X =  1.3;
final float VIEW_MIN_Y = -0.3;
final float VIEW_MAX_Y =  1.3;

// ======================================================
// DATA BUFFERS
// ======================================================
byte[] txBuf = new byte[TX_BYTES];

float[][] moonsTx;                   // static (TX)
float[][] moonsRx = new float[MOONS_N][2]; // RX from FPGA (reuse)

// ======================================================
// RX PACKET FORMAT
// FF FF | LEN_L LEN_H | SEQ | PAYLOAD | CHK
// ======================================================
final int MAX_PAYLOAD = 1024;

enum RxState { FIND_FF1, FIND_FF2, LEN0, LEN1, SEQ, PAYLOAD, CHK }
RxState st = RxState.FIND_FF1;

int expectLen = 0;
int seqRx = 0;
int lastSeq = -1;

byte[] payload = new byte[MAX_PAYLOAD];
int payIdx = 0;

int chkCalc = 0;
int chkRx   = 0;

// ======================================================
// STATS
// ======================================================
int pktOK = 0;
int pktBad = 0;
int lost = 0;
int lastPktMs = 0;
int lastByteMs = 0;

final int PARSER_TIMEOUT_MS = 150;

// ignore RX shortly after TX
boolean ignoreRx = true;
int tSendMs = 0;
final int IGNORE_AFTER_SEND_MS = 100;

// fast serial buffer
byte[] inBuf = new byte[8192];

// ======================================================
// SETUP
// ======================================================
void setup() {
  size(1200, 650);
  frameRate(60);
  surface.setTitle("TX → FPGA → RX (Two Moons, Fixed Axis)");

  println("Available ports:");
  println(Serial.list());

  myPort = new Serial(this, PORT_NAME, BAUD);
  myPort.clear();
  delay(200);

  // build dataset (ASLI)
  moonsTx = generateMoons(
    MOONS_N,
    MOONS_RANDOM_ANGLE,
    MOONS_NOISE_STD,
    MOONS_SEED,
    MOONS_SHUFFLE,
    MOONS_NORMALIZE01
  );

  packDataset();
  sendDatasetOnce();
}

// ======================================================
// DRAW
// ======================================================
void draw() {
  background(20);

  // LEFT: TX static
  drawPanel(moonsTx, 50, 50, "TX DATASET (static)", 0.0);

  // RIGHT: RX from FPGA
  drawPanel(moonsRx, 650, 50, "RX FROM FPGA", 0.0);

  drawDebug();

  // enable RX after TX settle
  if (ignoreRx && millis() - tSendMs > IGNORE_AFTER_SEND_MS) {
    ignoreRx = false;
  }

  // parser timeout rescue
  if (!ignoreRx && st != RxState.FIND_FF1) {
    if (millis() - lastByteMs > PARSER_TIMEOUT_MS) {
      resetParser();
      println("Parser timeout → reset");
    }
  }
}

// ======================================================
// KEY
// ======================================================
void keyPressed() {
  if (key == 'r' || key == 'R') {
    packDataset();
    sendDatasetOnce();
  }
}

// ======================================================
// TX
// ======================================================
void sendDatasetOnce() {
  myPort.clear();
  resetParser();
  ignoreRx = true;
  tSendMs = millis();

  myPort.write(txBuf);
  println("TX dataset sent (400 bytes)");
}

// ======================================================
// SERIAL EVENT (FAST)
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
// PARSER
// ======================================================
void feedParser(int b) {
  switch(st) {
    case FIND_FF1:
      if (b == 0xFF) st = RxState.FIND_FF2;
      break;

    case FIND_FF2:
      st = (b == 0xFF) ? RxState.LEN0 : RxState.FIND_FF1;
      break;

    case LEN0:
      expectLen = b;
      st = RxState.LEN1;
      break;

    case LEN1:
      expectLen |= (b << 8);
      if (expectLen <= 0 || expectLen > MAX_PAYLOAD) {
        pktBad++;
        resetParser();
      } else {
        st = RxState.SEQ;
      }
      break;

    case SEQ:
      seqRx = b;
      payIdx = 0;
      chkCalc = 0;
      st = RxState.PAYLOAD;
      break;

    case PAYLOAD:
      payload[payIdx++] = (byte)b;
      chkCalc = (chkCalc + b) & 0xFF;
      if (payIdx >= expectLen) st = RxState.CHK;
      break;

    case CHK:
      chkRx = b;
      if ((chkCalc & 0xFF) == (chkRx & 0xFF)) {
        onGoodPacket(seqRx, expectLen);
        pktOK++;
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
}

// ======================================================
// GOOD PACKET
// ======================================================
void onGoodPacket(int seq, int len) {
  lastPktMs = millis();

  if (lastSeq >= 0) {
    int diff = (seq - lastSeq) & 0xFF;
    if (diff != 1) lost += (diff - 1) & 0xFF;
  }
  lastSeq = seq;

  if (len != TX_BYTES) return;

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
}

// ======================================================
// DRAW PANEL
// ======================================================
void drawPanel(float[][] pts, float x0, float y0, String title, float shiftX) {
  float w = 500;
  float h = 500;

  fill(30);
  rect(x0, y0, w, h);

  fill(220);
  text(title, x0, y0 - 10);

  stroke(80);
  float xZero = map(0, VIEW_MIN_X, VIEW_MAX_X, x0, x0 + w);
  float yZero = map(0, VIEW_MIN_Y, VIEW_MAX_Y, y0 + h, y0);
  line(x0, yZero, x0 + w, yZero);
  line(xZero, y0, xZero, y0 + h);

  noStroke();
  fill(255);

  for (int i = 0; i < pts.length; i++) {
    float x = pts[i][0] + shiftX;
    float y = pts[i][1];

    float xn = (x - VIEW_MIN_X) / (VIEW_MAX_X - VIEW_MIN_X);
    float yn = (y - VIEW_MIN_Y) / (VIEW_MAX_Y - VIEW_MIN_Y);

    float px = x0 + 10 + xn * (w - 20);
    float py = y0 + h - (10 + yn * (h - 20));

    ellipse(px, py, 5, 5);
  }
}

// ======================================================
// DEBUG
// ======================================================
void drawDebug() {
  fill(0, 180);
  rect(0, height - 80, width, 80);

  fill(220);
  textSize(14);
  text(
    "PKT_OK=" + pktOK +
    "  BAD=" + pktBad +
    "  LOST~=" + lost +
    "  RX_age(ms)=" + (lastPktMs == 0 ? -1 : millis() - lastPktMs),
    30, height - 35
  );
}

// ======================================================
// PACK DATASET
// ======================================================
void packDataset() {
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
// Two-Moons generator (ASLI, TIDAK DIUBAH)
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
      arr[i][0] = arr[j][0];
      arr[i][1] = arr[j][1];
      arr[j][0] = tx;
      arr[j][1] = ty;
    }
  }

  return arr;
}
