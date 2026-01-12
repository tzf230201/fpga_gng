import processing.serial.*;

// ===============================
// Serial config
// ===============================
Serial myPort;
final String PORT_NAME = "COM1";   // <-- ganti sesuai Serial.list()
final int    BAUD      = 1_000_000;

// ===============================
// Two-moons dataset options
// ===============================
final int     MOONS_N            = 100;     // 100 points -> 400 bytes (x,y int16)
final boolean MOONS_RANDOM_ANGLE = false;
final int     MOONS_SEED         = 1234;
final float   MOONS_NOISE_STD    = 0.06;
final boolean MOONS_SHUFFLE      = true;
final boolean MOONS_NORMALIZE01  = true;

// quantization scale (same as your earlier code)
final float SCALE = 1000.0;

// ===============================
// TX/RX buffers
// ===============================
final int BYTES_PER_POINT = 4;              // int16 x + int16 y
final int TX_BYTES = MOONS_N * BYTES_PER_POINT; // must be 400

byte[] txBuf = new byte[TX_BYTES];
byte[] rxBuf = new byte[TX_BYTES];

float[][] moonsTx; // points we sent
float[][] moonsRx; // points decoded from echo

int rxCount = 0;
boolean waitingEcho = false;

int tSendMs = 0;
String statusMsg = "idle";
String verifyMsg = "";

// ===============================
// Setup / Draw
// ===============================
void setup() {
  size(1000, 600);
  surface.setTitle("Two Moons -> Send 400 bytes -> Echo 400 bytes (1 Mbps)");

  println("Available ports:");
  println(Serial.list());

  if (TX_BYTES != 400) {
    println("ERROR: TX_BYTES must be 400 for your FPGA buffer. Now = " + TX_BYTES);
    exit();
  }

  myPort = new Serial(this, PORT_NAME, BAUD);
  myPort.clear();
  delay(200);

  buildTwoMoonsAndPack();
  sendOnce();

  textFont(createFont("Consolas", 14));
}

void draw() {
  background(25);

  drawPointsPanels();
  drawDebug();

  // timeout (optional)
  if (waitingEcho && (millis() - tSendMs) > 3000) {
    waitingEcho = false;
    statusMsg = "TIMEOUT (echo not complete)";
    verifyMsg = "Try press 'r' to resend.";
  }
}

void keyPressed() {
  if (key == 'r' || key == 'R') {
    myPort.clear();
    rxCount = 0;
    waitingEcho = false;
    verifyMsg = "";
    statusMsg = "rebuild & resend";
    buildTwoMoonsAndPack();
    sendOnce();
  }
}

// ===============================
// Serial receive
// ===============================
void serialEvent(Serial p) {
  while (p.available() > 0 && rxCount < TX_BYTES) {
    int b = p.read();
    if (b < 0) break;
    rxBuf[rxCount++] = (byte)(b & 0xFF);
  }

  if (waitingEcho && rxCount >= TX_BYTES) {
    waitingEcho = false;
    statusMsg = "echo received: 400/400";
    verifyAndDecode();
  }
}

// ===============================
// Build dataset + pack to 400 bytes
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

  // pack int16 LE: [x0L x0H y0L y0H x1L x1H y1L y1H ...]
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

void sendOnce() {
  rxCount = 0;
  waitingEcho = true;
  tSendMs = millis();
  statusMsg = "sent 400 bytes, waiting echo...";
  myPort.write(txBuf);
}

// ===============================
// Verify + decode echo -> moonsRx
// ===============================
void verifyAndDecode() {
  int mism = 0;
  for (int i = 0; i < TX_BYTES; i++) {
    int a = txBuf[i] & 0xFF;
    int b = rxBuf[i] & 0xFF;
    if (a != b) mism++;
  }

  if (mism == 0) {
    verifyMsg = "✅ VERIFY OK (400 bytes match)";
  } else {
    verifyMsg = "❌ VERIFY FAIL mismatches=" + mism;
  }

  // decode rx to float points
  moonsRx = new float[MOONS_N][2];
  int p = 0;
  for (int i = 0; i < MOONS_N; i++) {
    int xi = (rxBuf[p++] & 0xFF) | ((rxBuf[p++] & 0xFF) << 8);
    int yi = (rxBuf[p++] & 0xFF) | ((rxBuf[p++] & 0xFF) << 8);
    if (xi >= 32768) xi -= 65536;
    if (yi >= 32768) yi -= 65536;

    moonsRx[i][0] = xi / SCALE;
    moonsRx[i][1] = yi / SCALE;
  }
}

// ===============================
// Drawing
// ===============================
void drawPointsPanels() {
  // left panel = TX points
  fill(220);
  text("TX (Two Moons sent)", 30, 30);
  drawScatter(moonsTx, 30, 50, 440, 500);

  // right panel = RX decoded
  fill(220);
  text("RX (Echo decoded)", 530, 30);
  drawScatter(moonsRx, 530, 50, 440, 500);
}

void drawScatter(float[][] pts, float x0, float y0, float w, float h) {
  // panel bg
  noStroke();
  fill(0, 0, 0, 120);
  rect(x0, y0, w, h);

  if (pts == null) return;

  // find bounds
  float minx=1e9, maxx=-1e9, miny=1e9, maxy=-1e9;
  for (int i = 0; i < pts.length; i++) {
    float x = pts[i][0], y = pts[i][1];
    minx = min(minx, x); maxx = max(maxx, x);
    miny = min(miny, y); maxy = max(maxy, y);
  }
  float dx = max(1e-6, maxx - minx);
  float dy = max(1e-6, maxy - miny);

  // points
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
       "  TX_BYTES=" + TX_BYTES + "  RX=" + rxCount + "/" + TX_BYTES, 20, height - 45);
  text("Status: " + statusMsg, 20, height - 25);

  fill(180, 220, 255);
  text(verifyMsg, 520, height - 25);
}

// ===============================
// Two-moons generator (same style as yours)
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
