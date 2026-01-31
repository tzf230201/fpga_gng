import processing.serial.*;
import java.util.ArrayList;

// ===============================
// Serial config
// ===============================
Serial myPort;
final String PORT_NAME = "COM1";   // <-- GANTI sesuai Serial.list()
final int    BAUD      = 1000000;

// ===============================
// Two-moons dataset options
// ===============================
final int     MOONS_N            = 100;
final boolean MOONS_RANDOM_ANGLE = false;
final int     MOONS_SEED         = 1234;
final float   MOONS_NOISE_STD    = 0.06;
final boolean MOONS_SHUFFLE      = true;
final boolean MOONS_NORMALIZE01  = true;

// ===============================
// Dataset upload state
// ===============================
float[][] data;
int idx = 0;
boolean uploaded = false;
boolean running  = false;

// debug strings
String lastTX   = "";
String lastRX   = "";
String lastTXT  = "";   // <-- NEW: last ASCII line from NEORV32

// counts from payload
int gngNodeCount = 0;
int gngEdgeCount = 0;
int lastFrameNodes = -1;
int lastFrameEdges = -1;

// ===============================
// UART Binary protocol (match main.c)
// Frame: FF FF CMD LEN PAYLOAD CHK, CHK = ~(CMD + LEN + sum(payload))
// ===============================
final int UART_HDR       = 0xFF;

final int CMD_DATA_BATCH = 0x01;
final int CMD_DONE       = 0x02;
final int CMD_RUN        = 0x03;

final int CMD_GNG_NODES  = 0x10;
final int CMD_GNG_EDGES  = 0x11;

// RX state machine
final int RX_WAIT_H1      = 0;
final int RX_WAIT_H2      = 1;
final int RX_WAIT_CMD     = 2;
final int RX_WAIT_LEN     = 3;
final int RX_WAIT_PAYLOAD = 4;
final int RX_WAIT_CHK     = 5;

int    rxState    = RX_WAIT_H1;
int    rxCmd      = 0;
int    rxLen      = 0;
int    rxIndex    = 0;
int    rxChecksum = 0;
byte[] rxPayload  = new byte[512];

// ===============================
// ASCII capture (for printf/puts)
// ===============================
StringBuilder asciiBuf = new StringBuilder(256);

// ===============================
// GNG structures
// ===============================
class Node {
  float x, y;
  boolean active = false;
}
class Edge {
  int a, b;
  boolean active = false;
}

ArrayList<Node> gngNodes = new ArrayList<Node>();
ArrayList<Edge> gngEdges = new ArrayList<Edge>();

// ===============================
// Setup / Draw
// ===============================
void setup() {
  size(1000, 600);
  surface.setTitle("Two Moons → NEORV32 GNG (binary + text)");

  println("Available serial ports:");
  println(Serial.list());

  myPort = new Serial(this, PORT_NAME, BAUD);

  // optional: buang data awal yang “nyangkut”
  myPort.clear();
  delay(1200);

  data = generateMoons(
    MOONS_N,
    MOONS_RANDOM_ANGLE,
    MOONS_NOISE_STD,
    MOONS_SEED,
    MOONS_SHUFFLE,
    MOONS_NORMALIZE01
  );

  println("Uploading dataset...");
}

void draw() {
  background(30);

  // IMPORTANT: selalu baca serial, biar text seperti "READY\n" kebaca
  processSerial();

  drawDataset();
  drawGNG();
  drawDebug();

  if (!uploaded) {
    uploadDataset();
  } else if (!running) {
    sendRunCommand();
  }
  // kalau sudah running, data akan terus masuk via processSerial()
}

// ===============================
// Upload dataset in batches
// ===============================
void uploadDataset() {
  final int BATCH_POINTS = 20;

  if (idx >= data.length) {
    sendFrame((byte)CMD_DONE, new byte[0]);
    lastTX = "DONE";
    uploaded = true;
    println("[TX] DONE");
    return;
  }

  int remaining = data.length - idx;
  int count = min(BATCH_POINTS, remaining);

  // payload: [count] + count*(xi,yi) where xi,yi are int16 LE scaled 1000
  byte[] payload = new byte[1 + count * 4];
  payload[0] = (byte)count;

  int p = 1;
  for (int i = 0; i < count; i++) {
    float x = data[idx + i][0];
    float y = data[idx + i][1];

    short xi = (short)(x * 1000.0);
    short yi = (short)(y * 1000.0);

    payload[p++] = (byte)(xi & 0xFF);
    payload[p++] = (byte)((xi >> 8) & 0xFF);
    payload[p++] = (byte)(yi & 0xFF);
    payload[p++] = (byte)((yi >> 8) & 0xFF);
  }

  sendFrame((byte)CMD_DATA_BATCH, payload);
  lastTX = "DATA_BATCH count=" + count + " idx=" + idx;
  println("[TX] " + lastTX);

  idx += count;
}

void sendRunCommand() {
  sendFrame((byte)CMD_RUN, new byte[0]);
  lastTX = "RUN";
  running = true;
  println("[TX] RUN");
}

// ===============================
// Unified serial processing:
// - parse binary frames FF FF ...
// - also capture ASCII lines from printf/puts
// ===============================
void processSerial() {
  while (myPort.available() > 0) {
    int bi = myPort.read();
    if (bi == -1) return;
    int b = bi & 0xFF;

    // If we're idle and this isn't a frame header, treat as ASCII text
    if (rxState == RX_WAIT_H1 && b != UART_HDR) {
      handleAsciiByte(b);
      continue;
    }

    // Otherwise continue binary frame parser
    switch (rxState) {
      case RX_WAIT_H1:
        if (b == UART_HDR) rxState = RX_WAIT_H2;
        break;

      case RX_WAIT_H2:
        if (b == UART_HDR) rxState = RX_WAIT_CMD;
        else {
          // false alarm: we saw one 0xFF but not second
          rxState = RX_WAIT_H1;
        }
        break;

      case RX_WAIT_CMD:
        rxCmd = b;
        rxChecksum = b & 0xFF;
        rxState = RX_WAIT_LEN;
        break;

      case RX_WAIT_LEN:
        rxLen = b;
        rxChecksum = (rxChecksum + (b & 0xFF)) & 0xFF;
        rxIndex = 0;
        if (rxLen == 0) rxState = RX_WAIT_CHK;
        else if (rxLen > rxPayload.length) rxState = RX_WAIT_H1;
        else rxState = RX_WAIT_PAYLOAD;
        break;

      case RX_WAIT_PAYLOAD:
        rxPayload[rxIndex++] = (byte)b;
        rxChecksum = (rxChecksum + (b & 0xFF)) & 0xFF;
        if (rxIndex >= rxLen) rxState = RX_WAIT_CHK;
        break;

      case RX_WAIT_CHK: {
        int expected = (~rxChecksum) & 0xFF;
        if (b == expected) {
          handleFrame(rxCmd, rxPayload, rxLen);
        } else {
          // checksum fail, you can uncomment to debug
          // println("[RX] checksum fail cmd=" + hex(rxCmd) + " len=" + rxLen);
        }
        rxState = RX_WAIT_H1;
        break;
      }

      default:
        rxState = RX_WAIT_H1;
        break;
    }
  }
}

void handleAsciiByte(int b) {
  // ignore CR
  if (b == '\r') return;

  // newline -> flush line
  if (b == '\n') {
    if (asciiBuf.length() > 0) {
      String line = asciiBuf.toString();
      asciiBuf.setLength(0);
      lastTXT = line;
      println("[NEORV32] " + line); // <-- ini yang kamu mau: print non-dataset ke terminal
    }
    return;
  }

  // keep printable chars + tab
  if ((b >= 32 && b <= 126) || b == '\t') {
    // optional limit biar gak membengkak kalau never ends
    if (asciiBuf.length() < 400) asciiBuf.append((char)b);
  }
}

// ===============================
// Handle frames from NEORV32
// ===============================
void handleFrame(int cmd, byte[] payload, int len) {

  if (cmd == CMD_GNG_NODES) {
    if (len < 2) return;

    int frameId   = payload[0] & 0xFF;
    int nodeCount = payload[1] & 0xFF;
    gngNodeCount  = nodeCount;

    int pos = 2;
    gngNodes.clear();

    for (int i = 0; i < nodeCount; i++) {
      if (pos + 5 > len) break;

      int idxNode = payload[pos++] & 0xFF;

      int xi = (payload[pos++] & 0xFF) | ((payload[pos++] & 0xFF) << 8);
      int yi = (payload[pos++] & 0xFF) | ((payload[pos++] & 0xFF) << 8);

      if (xi >= 32768) xi -= 65536;
      if (yi >= 32768) yi -= 65536;

      while (gngNodes.size() <= idxNode) gngNodes.add(new Node());
      Node n = gngNodes.get(idxNode);
      n.x = xi / 1000.0;
      n.y = yi / 1000.0;
      n.active = true;
    }

    lastFrameNodes = frameId;
    lastRX = "NODES frame=" + frameId + " n=" + nodeCount;
  }

  else if (cmd == CMD_GNG_EDGES) {
    if (len < 2) return;

    int frameId   = payload[0] & 0xFF;
    int edgeCount = payload[1] & 0xFF;
    gngEdgeCount  = edgeCount;

    int pos = 2;
    gngEdges.clear();

    for (int i = 0; i < edgeCount; i++) {
      if (pos + 2 > len) break;
      Edge e = new Edge();
      e.a = payload[pos++] & 0xFF;
      e.b = payload[pos++] & 0xFF;
      e.active = true;
      gngEdges.add(e);
    }

    lastFrameEdges = frameId;
    lastRX = "EDGES frame=" + frameId + " e=" + edgeCount;
  }
}

// ===============================
// Send frame helper
// ===============================
void sendFrame(byte cmd, byte[] payload) {
  int len = (payload == null) ? 0 : payload.length;
  int sum = (cmd & 0xFF) + (len & 0xFF);
  if (payload != null) {
    for (int i = 0; i < payload.length; i++) sum += payload[i] & 0xFF;
  }
  int chk = (~sum) & 0xFF;

  myPort.write(UART_HDR);
  myPort.write(UART_HDR);
  myPort.write(cmd & 0xFF);
  myPort.write(len & 0xFF);
  if (payload != null) myPort.write(payload);
  myPort.write(chk);
}

// ===============================
// Draw routines
// ===============================
void drawDataset() {
  fill(255);
  noStroke();

  for (int i = 0; i < data.length; i++) {
    float x = data[i][0] * 400 + 50;
    float y = data[i][1] * 400 + 50;
    ellipse(x, y, 6, 6);
  }

  fill(200);
  textSize(16);
  text("Two Moons (" + MOONS_N + " pts)  noise=" + nf(MOONS_NOISE_STD, 1, 3) +
       "  seed=" + MOONS_SEED +
       "  randomAngle=" + MOONS_RANDOM_ANGLE, 50, 30);
}

void drawGNG() {
  pushMatrix();
  translate(500, 0);

  stroke(255);
  strokeWeight(2);
  for (Edge e : gngEdges) {
    if (!e.active) continue;
    if (e.a < 0 || e.a >= gngNodes.size()) continue;
    if (e.b < 0 || e.b >= gngNodes.size()) continue;
    Node a = gngNodes.get(e.a);
    Node b = gngNodes.get(e.b);
    if (!a.active || !b.active) continue;

    line(a.x * 400 + 50, a.y * 400 + 50,
         b.x * 400 + 50, b.y * 400 + 50);
  }

  fill(0, 180, 255);
  noStroke();
  for (Node n : gngNodes) {
    if (n.active) ellipse(n.x * 400 + 50, n.y * 400 + 50, 12, 12);
  }

  fill(200);
  text("NEORV32 GNG Output", 150, 30);
  popMatrix();
}

void drawDebug() {
  fill(0, 0, 0, 180);
  rect(0, height - 105, width, 105);

  fill(0,255,0);
  text("TX: " + lastTX, 10, height - 75);

  fill(255,200,0);
  text("RX: " + lastRX, 10, height - 55);

  fill(180,180,255);
  text("TXT: " + lastTXT, 10, height - 35); // <-- NEW: ASCII prints

  fill(200);
  text("Nodes=" + gngNodeCount + "  Edges=" + gngEdgeCount +
       "  FrameN=" + lastFrameNodes + "  FrameE=" + lastFrameEdges,
       10, height - 15);
}

// ===============================
// Two-moons generator
// ===============================
float[][] generateMoons(int N, boolean randomAngle, float noiseStd, int seed,
                        boolean shuffle, boolean normalize01) {
  float[][] arr = new float[N][2];

  if (seed >= 0) randomSeed(seed);
  else randomSeed((int)millis());

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
    float dx = maxx - minx; if (dx < 1e-9) dx = 1.0;
    float dy = maxy - miny; if (dy < 1e-9) dy = 1.0;

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
