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
// Packet types
// ======================================================
final int PKT_TYPE_WIN = 0xB1; // winners log
final int PKT_TYPE_GNG = 0xA1; // optional

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

// ======================================================
// IMPORTANT: jangan buang 0xB1 yang dikirim cepat
// Kita masih boleh "ignore", tapi hanya sampai ketemu header FF FF.
// ======================================================
boolean ignoreRx = false;
final int IGNORE_AFTER_SEND_MS = 0; // biar aman, 0
int tSendMs = 0;

// fast read
byte[] inBuf = new byte[8192];
int lastByteMs = 0;
final int PARSER_TIMEOUT_MS = 120;

// ======================================================
// Winners storage (sorted by idx)
// ======================================================
boolean haveWin = false;
int winN = 0;

int[] s1ByIdx = new int[256];
int[] s2ByIdx = new int[256];
boolean[] seenIdx = new boolean[256];

boolean printedThisRun = false;
boolean AUTO_SAVE_CSV = true;
String CSV_NAME = "winners_fpga.csv";

int scroll = 0;
final int LINES_PER_PAGE = 26;

// ======================================================
// Setup
// ======================================================
void setup() {
  size(1400, 780);
  surface.setTitle("GNG Winner Print (0xB1) - FPGA log");
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
    if (haveWin) printWinnersToConsole();
    else println("No winners yet.");
  } else if (key == 'w' || key == 'W') {
    if (haveWin) saveWinnersCsv(CSV_NAME);
    else println("No winners yet.");
  } else if (keyCode == UP) {
    scroll = max(0, scroll - 1);
  } else if (keyCode == DOWN) {
    scroll = min(99, scroll + 1);
  }
}

// ======================================================
// TX
// ======================================================
void sendDatasetOnce() {
  resetParser();

  haveWin = false;
  winN = 0;
  printedThisRun = false;
  scroll = 0;

  for (int i=0;i<256;i++) {
    s1ByIdx[i] = -1;
    s2ByIdx[i] = -1;
    seenIdx[i] = false;
  }

  // MULAI ignore sebentar (opsional), tapi kita akan unlock saat ketemu FF FF
  tSendMs = millis();
  ignoreRx = (IGNORE_AFTER_SEND_MS > 0);

  statusMsg = "TX: sent 400 bytes. Waiting 0xB1...";
  myPort.write(txBuf);

  // kalau IGNORE_AFTER_SEND_MS = 0, langsung listen
  if (IGNORE_AFTER_SEND_MS == 0) ignoreRx = false;
}

// ======================================================
// Serial receive
// ======================================================
void serialEvent(Serial p) {
  int n = p.readBytes(inBuf);
  if (n <= 0) return;

  lastByteMs = millis();

  // kalau lagi ignore, kita scan FF FF supaya paket 0xB1 yang cepat tidak hilang
  if (ignoreRx) {
    // timeout ignore
    if ((millis() - tSendMs) > IGNORE_AFTER_SEND_MS) {
      ignoreRx = false;
    } else {
      // scan header
      for (int i=0; i<n-1; i++) {
        int b0 = inBuf[i] & 0xFF;
        int b1 = inBuf[i+1] & 0xFF;
        if (b0 == 0xFF && b1 == 0xFF) {
          ignoreRx = false;
          resetParser();
          // feed mulai dari posisi FF pertama
          for (int j=i; j<n; j++) feedParser(inBuf[j] & 0xFF);
          return;
        }
      }
      return; // masih ignore dan belum ketemu header
    }
  }

  // normal parse
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

  if (type == PKT_TYPE_WIN) {
    if (decodeWinnersB1(len)) {
      verifyMsg = "0xB1 OK: N=" + winN + " (idx 0..99)";
      statusMsg = "Got 0xB1 winners.";

      if (!printedThisRun) {
        printWinnersToConsole();
        if (AUTO_SAVE_CSV) saveWinnersCsv(CSV_NAME);
        printedThisRun = true;
      }
    } else {
      verifyMsg = "0xB1 decode failed (len=" + len + ")";
      pktBad++;
    }
    return;
  }

  if (type == PKT_TYPE_GNG) {
    verifyMsg = "0xA1 received (ignored here), len=" + len;
    return;
  }

  verifyMsg = "Unknown type=0x" + hex(type,2) + " len=" + len;
}

// ======================================================
// Decode 0xB1
// payload: [0]=B1 [1]=N [2..]= idx,s1,s2 repeated
// ======================================================
boolean decodeWinnersB1(int len) {
  int p = 0;
  int type = payload[p++] & 0xFF;
  if (type != PKT_TYPE_WIN) return false;
  if (p + 1 > len) return false;

  int N = payload[p++] & 0xFF;
  if (N <= 0 || N > 255) return false;

  int need = 2 + (N * 3);
  if (len < need) return false;
  if (len != need) println("WARN: len=" + len + " expected=" + need);

  winN = N;

  for (int i=0;i<256;i++) seenIdx[i] = false;

  for (int i=0;i<N;i++) {
    int idx = payload[p++] & 0xFF;
    int s1  = payload[p++] & 0xFF;
    int s2  = payload[p++] & 0xFF;

    s1ByIdx[idx] = s1;
    s2ByIdx[idx] = s2;
    seenIdx[idx] = true;
  }

  haveWin = true;
  return true;
}

// ======================================================
// Print + CSV (sorted by idx)
// ======================================================
void printWinnersToConsole() {
  println("====================================================");
  println("FPGA 0xB1 WINNERS (sorted by idx) N=" + winN);
  println("idx | s1(winner) | s2(runner-up)");
  println("====================================================");
  for (int idx=0; idx<100; idx++) {
    if (seenIdx[idx]) println(nf(idx,3) + " | " + nf(s1ByIdx[idx],3) + " | " + nf(s2ByIdx[idx],3));
    else              println(nf(idx,3) + " |   -   |   -   (missing)");
  }
  println("====================================================");
}

void saveWinnersCsv(String filename) {
  PrintWriter out = createWriter(filename);
  out.println("idx,s1,s2");
  for (int idx=0; idx<100; idx++) {
    if (seenIdx[idx]) out.println(idx + "," + s1ByIdx[idx] + "," + s2ByIdx[idx]);
    else              out.println(idx + ",,");
  }
  out.flush();
  out.close();
  println("Saved CSV -> " + sketchPath(filename));
}

// ======================================================
// UI
// ======================================================
float viewMinX, viewMaxX, viewMinY, viewMaxY;

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
  text("0xB1 winners list (idx -> s1,s2)", rightX, 55);
  drawScatter(moonsTx, rightX, panelY, panelW, panelH, 90, 4);

  // list box
  fill(0, 160);
  noStroke();
  rect(rightX + 20, panelY + 20, panelW - 40, 430);

  fill(220);
  if (!haveWin) {
    text("waiting 0xB1...", rightX + 30, panelY + 45);
  } else {
    text("RECEIVED 0xB1: N=" + winN + "  (UP/DOWN scroll, P print, W save)", rightX + 30, panelY + 45);
    text("Showing idx " + scroll + " .. " + min(99, scroll + LINES_PER_PAGE - 1), rightX + 30, panelY + 70);

    int y = (int)(panelY + 100);
    fill(200);
    for (int idx = scroll; idx < 100 && idx < scroll + LINES_PER_PAGE; idx++) {
      if (seenIdx[idx]) text(nf(idx,3) + ": s1=" + nf(s1ByIdx[idx],2) + "  s2=" + nf(s2ByIdx[idx],2), rightX + 30, y);
      else              text(nf(idx,3) + ": (missing)", rightX + 30, y);
      y += 16;
    }
  }

  noFill();
  stroke(60);
  rect(leftX, panelY, panelW, panelH);
  rect(rightX, panelY, panelW, panelH);
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
  text("Keys: [R]=rebuild+send [S]=send [P]=print [W]=save [UP/DOWN]=scroll",
       740, height - 20);
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
