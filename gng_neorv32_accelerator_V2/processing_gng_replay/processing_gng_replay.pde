// ======================================================
// GNG Replay Viewer
// Loads CSV logs from V2_dataset and replays GNG training
//
// Controls:
//   Left / Right arrow  : prev / next snapshot
//   Home / End          : jump to first / last snapshot
//   P                   : play / pause auto-advance
//   +  /  -             : speed up / slow down playback
//   S                   : save screenshot (PNG)
//   R                   : reload CSV files
//   1..9                : jump to ~10%..90% of timeline
// ======================================================

import java.io.File;
import java.util.Arrays;

// -------------------------------------------------------
// CONFIG  –  point to the logs folder
// -------------------------------------------------------
// Relative to sketch folder.  "../processing_gng_dataset/logs" works
// if both sketches are siblings inside processing_gng_dataset.
// Use absolute path if needed, e.g. "C:/Users/you/.../logs"
final String LOGS_PATH = "../processing_gng_dataset/logs";

// Leave blank ("") to auto-pick the LATEST set of CSV files.
// Or set a specific timestamp prefix, e.g. "20260413_103045"
String LOG_TIMESTAMP = "";

// -------------------------------------------------------
// Display constants
// -------------------------------------------------------
final int WIN_W      = 1060;
final int WIN_H      = 960;
final int INFO_H     = 110;
final int MAX_NODES  = 40;
final float NODE_SCALE = 1000.0;
final int A_MAX      = 50;

// Must match VHDL generics
final int SNAP_EVERY = 50;   // iterations per snapshot
final int DATA_WORDS = 100;  // samples per epoch

// -------------------------------------------------------
// Data structures
// -------------------------------------------------------
class NodeState {
  int     id, degree, x_int, y_int;
  float   x_norm, y_norm;
  boolean active;
}

class EdgeState {
  int a, b, ageStored, trueAge;
}

class SnapFrame {
  int         snapIdx;
  String      timestamp;
  long        fpgaTsCycles; // FPGA cycle counter at this snapshot (27 MHz); -1 if unavailable
  NodeState[] nodes;        // length MAX_NODES
  EdgeState[] edges;        // active edges only
}

// Dataset background
float[][] dataPoints;
int[]     dataLabel;
int       dataN = 0;
String    datasetName = "GNG";

// All snapshot frames, sorted by snapIdx
ArrayList<SnapFrame> snaps = new ArrayList<SnapFrame>();

// Playback state
int     currentSnap  = 0;
boolean playing      = false;
int     playInterval = 300;   // ms between auto-advance
int     lastPlayMs   = 0;

// Screenshot counter
int screenshotCount = 0;

// Crop selection state (click-drag)
boolean selActive  = false;   // selection box exists
boolean selDragging = false;
int selX0, selY0, selX1, selY1; // screen coords (raw, may be inverted)

// Status message
String statusMsg = "";
int    statusMs  = 0;

// -------------------------------------------------------
// Setup
// -------------------------------------------------------
void setup() {
  surface.setSize(WIN_W, WIN_H);
  surface.setTitle("GNG Replay");
  frameRate(30);
  smooth(4);
  textFont(createFont("Consolas", 13));
  loadCSVFiles();
}

// -------------------------------------------------------
// Draw
// -------------------------------------------------------
void draw() {
  background(255);

  if (snaps.isEmpty()) {
    fill(80); textSize(18); textAlign(CENTER, CENTER);
    text("No snapshot data loaded.\nCheck LOGS_PATH and press R to reload.", width/2, height/2);
    return;
  }

  // Auto-play
  if (playing && (millis() - lastPlayMs) >= playInterval) {
    currentSnap = (currentSnap + 1) % snaps.size();
    lastPlayMs  = millis();
  }

  renderPlot();
  renderInfoBar();
  drawSelectionOverlay();

  // Status overlay
  if (statusMsg.length() > 0 && (millis() - statusMs) < 2500) {
    fill(0, 180); noStroke();
    rect(10, height - INFO_H - 36, textWidth(statusMsg) + 24, 28, 6);
    fill(255); textAlign(LEFT, CENTER); textSize(14);
    text(statusMsg, 22, height - INFO_H - 22);
  }
}

// -------------------------------------------------------
// Plot
// -------------------------------------------------------
void renderPlot() {
  int plotH = height - INFO_H;
  int marginL = 85, marginR = 30, marginT = 60, marginB = 120;

  int px0 = marginL, py0 = marginT;
  int pw  = WIN_W - marginL - marginR;
  int ph  = plotH  - marginT  - marginB;

  int side = min(pw, ph);
  int sx0  = px0 + (pw - side) / 2;
  int sy0  = py0 + (ph - side) / 2;
  int sw   = side, sh = side;

  pushStyle();

  // Frame
  stroke(0); strokeWeight(1); noFill();
  rect(sx0, sy0, sw, sh);

  // Grid + ticks
  fill(0); textSize(13); textAlign(CENTER, TOP);
  for (int t = 0; t <= 4; t++) {
    float v  = -1.0 + t * 0.5;
    float xx = sx0 + map(v, -1, 1, 0, sw);
    stroke(230); line(xx, sy0, xx, sy0 + sh);
    stroke(0);   line(xx, sy0 + sh, xx, sy0 + sh + 5);
    text(nf(v, 1, 1), xx, sy0 + sh + 9);
  }
  textAlign(RIGHT, CENTER);
  for (int t = 0; t <= 4; t++) {
    float v  = -1.0 + t * 0.5;
    float yy = sy0 + map(v, -1, 1, sh, 0);
    stroke(230); line(sx0, yy, sx0 + sw, yy);
    stroke(0);   line(sx0 - 5, yy, sx0, yy);
    text(nf(v, 1, 1), sx0 - 8, yy);
  }

  // Axis labels
  fill(0); textAlign(CENTER, CENTER); textSize(16);
  text("x (normalized)", sx0 + sw / 2, sy0 + sh + 48);
  pushMatrix();
  translate(sx0 - 58, sy0 + sh / 2);
  rotate(-HALF_PI);
  text("y (normalized)", 0, 0);
  popMatrix();

  // Title
  textSize(18); textAlign(CENTER, CENTER);
  SnapFrame sf = snaps.get(currentSnap);
  int iterNum  = sf.snapIdx * SNAP_EVERY;
  int epochNum = iterNum / DATA_WORDS;
  text("GNG " + datasetName + "  —  Epoch " + epochNum + "  |  FPGA: " + fpgaFmtTime(sf.fpgaTsCycles),
       sx0 + sw / 2, py0 - 18);

  // Dataset points
  noStroke();
  if (dataPoints != null) {
    for (int i = 0; i < dataN; i++) {
      fill(dataLabel[i] == 1 ? color(255, 140, 0) : color(40, 110, 220));
      float x = px(dataPoints[i][0], sx0, sw);
      float y = py(dataPoints[i][1], sy0, sh);
      rect(x - 2, y - 2, 4, 4);
    }
  }

  // Edges
  strokeWeight(2);
  for (EdgeState e : sf.edges) {
    if (e.a < 0 || e.b < 0 || e.a >= MAX_NODES || e.b >= MAX_NODES) continue;
    NodeState na = sf.nodes[e.a], nb = sf.nodes[e.b];
    if (!na.active || !nb.active) continue;
    float alpha = map(constrain(e.trueAge, 0, A_MAX), 0, A_MAX, 220, 40);
    stroke(100, alpha);
    line(px(na.x_norm, sx0, sw), py(na.y_norm, sy0, sh),
         px(nb.x_norm, sx0, sw), py(nb.y_norm, sy0, sh));
  }

  // Nodes
  stroke(220, 0, 0); strokeWeight(3);
  for (NodeState n : sf.nodes) {
    if (!n.active) continue;
    if (n.degree == 0) continue;  // hide isolated
    float x = px(n.x_norm, sx0, sw);
    float y = py(n.y_norm, sy0, sh);
    float r = 8;
    line(x - r, y - r, x + r, y + r);
    line(x - r, y + r, x + r, y - r);
  }

  // Legend
  drawLegend(sx0, sy0, sw, sh);

  popStyle();
}

// -------------------------------------------------------
// Info bar
// -------------------------------------------------------
void renderInfoBar() {
  if (snaps.isEmpty()) return;
  SnapFrame sf = snaps.get(currentSnap);

  int actN = 0;
  for (NodeState n : sf.nodes) if (n.active) actN++;

  int y0 = height - INFO_H;

  // Progress bar — sits just above the info bar, inside the dark region
  float frac = (snaps.size() > 1) ? (float)currentSnap / (snaps.size() - 1) : 0;
  int barH = 6, barPad = 10;
  fill(30); noStroke();
  rect(0, y0 - barH - barPad, width, barH + barPad); // background strip
  fill(50); noStroke();
  rect(barPad, y0 - barH - barPad/2, width - barPad*2, barH, 3);
  fill(playing ? color(0, 200, 90) : color(70, 140, 240));
  rect(barPad, y0 - barH - barPad/2, (width - barPad*2) * frac, barH, 3);

  fill(30); noStroke();
  rect(0, y0, width, INFO_H);

  fill(255); textSize(13); textAlign(LEFT, TOP);
  int lh = 20;
  int iter  = sf.snapIdx * SNAP_EVERY;
  int epoch = iter / DATA_WORDS;
  int totalEpochs = (snaps.size()-1) * SNAP_EVERY / DATA_WORDS;
  text("Epoch    : " + epoch + " / " + totalEpochs +
       "   (iter " + iter + ")" +
       "   FPGA: " + fpgaFmtTime(sf.fpgaTsCycles), 12, y0 + 6);
  text("Nodes    : " + actN + " active   Edges: " + sf.edges.length, 12, y0 + 6 + lh);
  text("Playback : " + (playing ? "PLAYING" : "PAUSED") +
       "  interval=" + playInterval + "ms", 12, y0 + 6 + lh*2);

  fill(160); textSize(12);
  text("← → navigate   Home/End first/last   P play/pause   +/- speed   drag=select  s=crop/plot  S=full  Esc=clear  1-9 jump   R reload",
       12, y0 + 6 + lh*3);
  text("Dataset: " + dataN + " pts   Log: " + LOG_TIMESTAMP, 12, y0 + 6 + lh*4);
}

// -------------------------------------------------------
// Legend
// -------------------------------------------------------
void drawLegend(int sx0, int sy0, int sw, int sh) {
  pushStyle();
  textSize(13); textAlign(LEFT, CENTER);

  int ly = sy0 + sh + 78;
  int cx = sx0 + sw / 2;
  int totalW = 520;
  int x0 = cx - totalW / 2;
  int spacing = 130;

  // item 1: dataset A (blue square)
  noStroke(); fill(40, 110, 220);
  rect(x0-3, ly-3, 6, 6);
  fill(0); text("Class A", x0 + 12, ly);

  // item 2: dataset B (orange square)
  int x1 = x0 + spacing;
  noStroke(); fill(255, 140, 0);
  rect(x1-3, ly-3, 6, 6);
  fill(0); text("Class B", x1 + 12, ly);

  // item 3: edges (gray line)
  int x2 = x1 + spacing;
  stroke(100); strokeWeight(2);
  line(x2-5, ly, x2+12, ly);
  noStroke(); fill(0); text("GNG edges", x2 + 18, ly);

  // item 4: nodes (red X)
  int x3 = x2 + spacing;
  stroke(220, 0, 0); strokeWeight(3);
  float r = 5;
  line(x3-r, ly-r, x3+r, ly+r);
  line(x3-r, ly+r, x3+r, ly-r);
  noStroke(); fill(0); text("GNG nodes", x3 + 12, ly);

  popStyle();
}

// -------------------------------------------------------
// Coordinate helpers
// -------------------------------------------------------
float px(float v, int sx0, int sw) {
  return sx0 + map(constrain(v, -1, 1), -1, 1, 0, sw);
}
float py(float v, int sy0, int sh) {
  return sy0 + map(constrain(v, -1, 1), -1, 1, sh, 0);
}

// -------------------------------------------------------
// Key handling
// -------------------------------------------------------
void keyPressed() {
  if (keyCode == LEFT)  { currentSnap = max(0, currentSnap - 1); playing = false; }
  if (keyCode == RIGHT) { currentSnap = min(snaps.size()-1, currentSnap + 1); playing = false; }
  if (keyCode == 36 /*HOME*/) { currentSnap = 0; playing = false; }
  if (keyCode == 35 /*END*/)  { currentSnap = max(0, snaps.size()-1); playing = false; }

  if (key == 'p' || key == 'P') {
    playing = !playing;
    lastPlayMs = millis();
  }
  if ((key == '+' || key == '=') && playInterval > 50)  playInterval -= 50;
  if (key == '-'                  && playInterval < 2000) playInterval += 50;

  if (key == 's') saveScreenshot(false);   // plot area or crop selection
  if (key == 'S') saveScreenshot(true);    // full window
  if (key == 'r' || key == 'R') { loadCSVFiles(); status("Reloaded CSV files."); }
  if (keyCode == ESC) { selActive = false; key = 0; } // clear selection, suppress quit

  // Jump to 10%..90% of timeline
  if (key >= '1' && key <= '9' && !snaps.isEmpty()) {
    float frac = (key - '0') / 10.0;
    currentSnap = (int)(frac * (snaps.size() - 1));
    playing = false;
  }
}

// -------------------------------------------------------
// Mouse – crop selection (click-drag)
// -------------------------------------------------------
void mousePressed() {
  // Only start selection in plot area (above info bar)
  if (mouseY < height - INFO_H) {
    selDragging = true;
    selActive   = false;
    selX0 = selX1 = mouseX;
    selY0 = selY1 = mouseY;
  }
}
void mouseDragged() {
  if (selDragging) { selX1 = mouseX; selY1 = mouseY; }
}
void mouseReleased() {
  if (selDragging) {
    selX1       = mouseX;
    selY1       = mouseY;
    selDragging = false;
    // Only keep selection if large enough
    selActive   = (abs(selX1 - selX0) > 8 && abs(selY1 - selY0) > 8);
    if (!selActive) status("Selection too small — cleared.");
  }
}

// Draw selection overlay (called at end of draw())
void drawSelectionOverlay() {
  if (!selActive && !selDragging) return;
  int rx = min(selX0, selX1), ry = min(selY0, selY1);
  int rw = abs(selX1 - selX0),  rh = abs(selY1 - selY0);
  pushStyle();
  noFill();
  stroke(255, 80, 0); strokeWeight(1.5);
  rect(rx, ry, rw, rh);
  // dim outside
  fill(0, 60); noStroke();
  rect(0, 0, width, ry);
  rect(0, ry + rh, width, height - ry - rh);
  rect(0, ry, rx, rh);
  rect(rx + rw, ry, width - rx - rw, rh);
  // label
  fill(255, 80, 0); textSize(12); textAlign(LEFT, BOTTOM);
  text(rw + " × " + rh + "  (s=crop  Esc=clear)", rx + 2, ry - 3);
  popStyle();
}

// -------------------------------------------------------
// Screenshot
// -------------------------------------------------------
// fullWindow=false : save crop selection if active, else plot area (no info bar)
// fullWindow=true  : save entire window (S key)
void saveScreenshot(boolean fullWindow) {
  String base;
  if (!snaps.isEmpty()) {
    SnapFrame sf = snaps.get(currentSnap);
    base = "screenshot_snap" + nf(sf.snapIdx, 4) + "_" + timestamp();
  } else {
    base = "screenshot_" + timestamp();
  }

  if (fullWindow) {
    saveFrame(base + "_full.png");
    status("Full screenshot: " + base + "_full.png");
    return;
  }

  // Crop selection active?
  if (selActive) {
    int rx = min(selX0, selX1), ry = min(selY0, selY1);
    int rw = abs(selX1 - selX0),  rh = abs(selY1 - selY0);
    // get() reads the current frame buffer
    PImage crop = get(rx, ry, rw, rh);
    String fname = base + "_crop.png";
    crop.save(sketchPath(fname));
    status("Crop saved: " + fname + "  (" + rw + "×" + rh + ")");
  } else {
    // Plot area only (no info bar or progress bar)
    int cutY = height - INFO_H - 16;
    PImage plot = get(0, 0, WIN_W, cutY);
    String fname = base + "_plot.png";
    plot.save(sketchPath(fname));
    status("Plot screenshot: " + fname);
  }
}

void status(String msg) { statusMsg = msg; statusMs = millis(); println(msg); }

// FPGA time formatting (27 MHz clock)
String fpgaFmtTime(long cycles) {
  if (cycles < 0) return "n/a";
  float ms = cycles / 27000.0;
  if (ms >= 1000.0) return nf(ms / 1000.0, 1, 3) + " s";
  return nf(ms, 1, 1) + " ms";
}
String timestamp() {
  return String.format("%d%02d%02d_%02d%02d%02d",
    year(), month(), day(), hour(), minute(), second());
}

// -------------------------------------------------------
// CSV loading
// -------------------------------------------------------
void loadCSVFiles() {
  snaps.clear(); dataPoints = null; dataN = 0;

  // Find log timestamp
  String ts = LOG_TIMESTAMP.trim();
  if (ts.equals("")) ts = findLatestTimestamp();
  if (ts.equals("")) { status("No CSV files found in: " + LOGS_PATH); return; }
  LOG_TIMESTAMP = ts;
  println("Loading log set: " + ts);

  loadDataset(LOGS_PATH + "/dataset_"   + ts + ".csv");
  loadNodes  (LOGS_PATH + "/gng_nodes_" + ts + ".csv");
  loadEdges  (LOGS_PATH + "/gng_edges_" + ts + ".csv");
  loadMeta   (LOGS_PATH + "/meta_"      + ts + ".txt");

  currentSnap = 0;
  surface.setTitle("GNG " + datasetName + " Replay");
  status("Loaded " + snaps.size() + " snapshots, " + dataN + " dataset pts  [" + ts + "]");
}

// Find latest timestamp by listing files matching dataset_*.csv
String findLatestTimestamp() {
  File dir = new File(sketchPath(LOGS_PATH));
  if (!dir.exists()) { println("LOGS_PATH not found: " + dir.getAbsolutePath()); return ""; }

  File[] files = dir.listFiles();
  if (files == null) return "";

  String latest = "";
  for (File f : files) {
    String name = f.getName();
    if (name.startsWith("dataset_") && name.endsWith(".csv")) {
      String ts = name.replace("dataset_", "").replace(".csv", "");
      if (ts.compareTo(latest) > 0) latest = ts;
    }
  }
  return latest;
}

void loadDataset(String path) {
  String[] lines = loadStrings(sketchPath(path));
  if (lines == null) { println("Cannot load: " + path); return; }

  // Count data rows (skip header)
  int n = 0;
  for (int i = 1; i < lines.length; i++) if (lines[i].trim().length() > 0) n++;

  dataPoints = new float[n][2];
  dataLabel  = new int[n];
  dataN      = 0;

  for (int i = 1; i < lines.length; i++) {
    String line = lines[i].trim();
    if (line.length() == 0) continue;
    String[] tok = line.split(",");
    if (tok.length < 7) continue;
    try {
      // timestamp,index,x_norm,y_norm,label,x_int,y_int
      dataPoints[dataN][0] = float(tok[2]);
      dataPoints[dataN][1] = float(tok[3]);
      dataLabel[dataN]     = int(tok[4]);
      dataN++;
    } catch (Exception e) { /* skip malformed */ }
  }
  println("Dataset loaded: " + dataN + " points");
}

void loadNodes(String path) {
  String[] lines = loadStrings(sketchPath(path));
  if (lines == null) { println("Cannot load: " + path); return; }

  // Parse all rows, group by snap_idx
  // timestamp,snap_idx,node_id,active,degree,x_int,y_int,x_norm,y_norm[,fpga_ts_cycles]
  java.util.TreeMap<Integer, SnapFrame> frameMap = new java.util.TreeMap<Integer, SnapFrame>();

  for (int i = 1; i < lines.length; i++) {
    String line = lines[i].trim();
    if (line.length() == 0) continue;
    String[] tok = line.split(",");
    if (tok.length < 9) continue;
    try {
      String ts    = tok[0];
      int snapIdx  = int(tok[1]);
      int nodeId   = int(tok[2]);
      if (nodeId < 0 || nodeId >= MAX_NODES) continue;

      if (!frameMap.containsKey(snapIdx)) {
        SnapFrame sf     = new SnapFrame();
        sf.snapIdx       = snapIdx;
        sf.timestamp     = ts;
        sf.fpgaTsCycles  = -1;
        sf.nodes         = new NodeState[MAX_NODES];
        for (int k = 0; k < MAX_NODES; k++) sf.nodes[k] = new NodeState();
        sf.edges         = new EdgeState[0];
        frameMap.put(snapIdx, sf);
      }
      SnapFrame sf      = frameMap.get(snapIdx);
      NodeState n       = sf.nodes[nodeId];
      n.id              = nodeId;
      n.active          = (int(tok[3]) == 1);
      n.degree          = int(tok[4]);
      n.x_int           = int(tok[5]);
      n.y_int           = int(tok[6]);
      n.x_norm          = float(tok[7]);
      n.y_norm          = float(tok[8]);
      // fpga_ts_cycles is the same for all nodes in a snap; read from first node row
      if (tok.length >= 10 && sf.fpgaTsCycles < 0) {
        sf.fpgaTsCycles = Long.parseLong(tok[9].trim());
      }
    } catch (Exception e) { /* skip */ }
  }

  snaps.addAll(frameMap.values());
  println("Node snapshots loaded: " + snaps.size() + " frames");
}

void loadEdges(String path) {
  String[] lines = loadStrings(sketchPath(path));
  if (lines == null) { println("Cannot load: " + path); return; }

  // Build a map snapIdx -> list of edges
  java.util.HashMap<Integer, ArrayList<EdgeState>> edgeMap =
    new java.util.HashMap<Integer, ArrayList<EdgeState>>();

  // timestamp,snap_idx,node_a,node_b,age_stored,true_age
  for (int i = 1; i < lines.length; i++) {
    String line = lines[i].trim();
    if (line.length() == 0) continue;
    String[] tok = line.split(",");
    if (tok.length < 6) continue;
    try {
      int snapIdx = int(tok[1]);
      EdgeState e = new EdgeState();
      e.a         = int(tok[2]);
      e.b         = int(tok[3]);
      e.ageStored = int(tok[4]);
      e.trueAge   = int(tok[5]);
      if (!edgeMap.containsKey(snapIdx)) edgeMap.put(snapIdx, new ArrayList<EdgeState>());
      edgeMap.get(snapIdx).add(e);
    } catch (Exception e2) { /* skip */ }
  }

  // Attach edges to snap frames
  for (SnapFrame sf : snaps) {
    ArrayList<EdgeState> list = edgeMap.get(sf.snapIdx);
    if (list != null) {
      sf.edges = list.toArray(new EdgeState[0]);
    } else {
      sf.edges = new EdgeState[0];
    }
  }
  println("Edges loaded and attached.");
}

void loadMeta(String path) {
  datasetName = "GNG";
  String[] lines = loadStrings(sketchPath(path));
  if (lines != null && lines.length > 0 && lines[0].trim().length() > 0) {
    datasetName = lines[0].trim();
  }
  println("Dataset name: " + datasetName);
}
