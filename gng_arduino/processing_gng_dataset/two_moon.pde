import processing.serial.*;

Serial myPort;

float[][] data;
int idx = 0;

boolean uploaded = false;
boolean running = false;

String lastTX = "";
String lastRX = "";

// GNG structures
class Node {
  float x, y;
  boolean active = false;
}
class Edge {
  int a, b;
  boolean active = false;
}

Node[] gngNodes = new Node[20];
Edge[] gngEdges = new Edge[40];


void setup() {
  size(1000, 600);
  surface.setTitle("Two Moons (100 pts) → Arduino → GNG");

  // Init GNG arrays
  for (int i=0;i<20;i++) gngNodes[i] = new Node();
  for (int i=0;i<40;i++) gngEdges[i] = new Edge();

  println(Serial.list());
  myPort = new Serial(this, "COM8", 115200);
  delay(1500);

  data = generateMoons100();

  println("Uploading dataset...");
}

void draw() {
  background(30);

  drawDataset();
  drawGNG();
  drawDebug();

  if (!uploaded) {
    uploadDataset();
  }
  else if (!running) {
    sendRunCommand();
  }
  else {
    readGNG();
  }
}

/* --------------------------------------------------
   UPLOAD DATASET (100 POINTS)
-------------------------------------------------- */
void uploadDataset() {
  if (idx >= data.length) {
    myPort.write("DONE;\n");
    lastTX = "DONE;";
    println("[TX] DONE;");
    uploaded = true;
    return;
  }

  float x = data[idx][0];
  float y = data[idx][1];

  String msg = "DATA:" + x + "," + y + ";\n";
  myPort.write(msg);
  lastTX = msg.trim();
  println("[TX] " + lastTX);

  idx++;
  delay(3);
}

void sendRunCommand() {
  myPort.write("RUN;\n");
  lastTX = "RUN;";
  println("[TX] RUN;");
  running = true;
}

/* --------------------------------------------------
   READ GNG FROM ARDUINO
-------------------------------------------------- */
void readGNG() {
  while (myPort.available() > 0) {
    String line = myPort.readStringUntil('\n');
    if (line == null) return;

    lastRX = line.trim();

    if (line.startsWith("GNG:")) {
      parseGNG(line.substring(4));
    }

    println("[RX] " + lastRX);
  }
}

/* --------------------------------------------------
   PARSE GNG DATA
-------------------------------------------------- */
void parseGNG(String s) {
  for (Node n : gngNodes) n.active = false;
  for (Edge e : gngEdges) e.active = false;

  String[] parts = s.split(";");

  for (String p : parts) {
    if (p.startsWith("N:")) {
      String[] a = p.substring(2).split(",");
      int id = int(a[0]);
      gngNodes[id].x = float(a[1]);
      gngNodes[id].y = float(a[2]);
      gngNodes[id].active = true;
    }
    else if (p.startsWith("E:")) {
      String[] a = p.substring(2).split(",");
      for (Edge e : gngEdges) {
        if (!e.active) {
          e.a = int(a[0]);
          e.b = int(a[1]);
          e.active = true;
          break;
        }
      }
    }
  }
}

/* --------------------------------------------------
   DRAWINGS
-------------------------------------------------- */
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
  text("Two Moons – 100 pts", 50, 30);
}

void drawGNG() {
  pushMatrix();
  translate(500, 0);

  stroke(255);
  strokeWeight(2);
  for (Edge e : gngEdges) {
    if (e.active) {
      Node a = gngNodes[e.a];
      Node b = gngNodes[e.b];
      line(a.x * 400 + 50, a.y * 400 + 50,
           b.x * 400 + 50, b.y * 400 + 50);
    }
  }

  fill(0, 180, 255);
  noStroke();
  for (Node n : gngNodes) {
    if (n.active) {
      ellipse(n.x * 400 + 50, n.y * 400 + 50, 12, 12);
    }
  }

  fill(200);
  text("MCU GNG Output", 150, 30);
  popMatrix();
}

void drawDebug() {
  fill(0, 0, 0, 180);
  rect(0, height - 60, width, 60);

  fill(0,255,0);
  text("TX: " + lastTX, 10, height - 40);

  fill(255,200,0);
  text("RX: " + lastRX, 10, height - 20);
}

/* --------------------------------------------------
   GENERATE 100 TWO-MOONS DATASET
-------------------------------------------------- */
float[][] generateMoons100() {
  int N = 100;
  float[][] arr = new float[N][2];

  for (int i = 0; i < N/2; i++) {
    float t = random(PI);
    arr[i][0] = cos(t);
    arr[i][1] = sin(t);
  }

  for (int i = N/2; i < N; i++) {
    float t = random(PI);
    arr[i][0] = 1 - cos(t);
    arr[i][1] = -sin(t) + 0.5;
  }

  float noise = 0.06;
  for (int i=0;i<N;i++) {
    arr[i][0] += random(-noise, noise);
    arr[i][1] += random(-noise, noise);
  }

  float minx=999,maxx=-999,miny=999,maxy=-999;
  for (float[] p : arr) {
    if(p[0]<minx) minx=p[0];
    if(p[0]>maxx) maxx=p[0];
    if(p[1]<miny) miny=p[1];
    if(p[1]>maxy) maxy=p[1];
  }

  for (int i=0;i<N;i++) {
    arr[i][0]=(arr[i][0]-minx)/(maxx-minx);
    arr[i][1]=(arr[i][1]-miny)/(maxy-miny);
  }

  return arr;
}