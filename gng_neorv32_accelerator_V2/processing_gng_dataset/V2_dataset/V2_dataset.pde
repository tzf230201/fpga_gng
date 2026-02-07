import processing.serial.*;

// ======================================================
// Serial config
// ======================================================
Serial myPort;
final String PORT_NAME = "COM1";
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
// DEBUG TLV tags
// ======================================================
final int TAG_A5 = 0xA5;
final int TAG_A6 = 0xA6;
final int TAG_A7 = 0xA7;
final int TAG_A8 = 0xA8;
final int TAG_A9 = 0xA9;

final int TAG_AA = 0xAA;
final int TAG_AB = 0xAB;
final int TAG_AC = 0xAC;
final int TAG_AD = 0xAD;

final int TAG_AE = 0xAE; // x lo
final int TAG_AF = 0xAF; // x hi
final int TAG_B0 = 0xB0; // y lo
final int TAG_B1 = 0xB1; // y hi

// extras
final int TAG_C0 = 0xC0; // e_s1s2_pre
final int TAG_C1 = 0xC1; // deg_s1
final int TAG_C2 = 0xC2; // deg_s2
final int TAG_C3 = 0xC3; // conn
final int TAG_C4 = 0xC4; // rm
final int TAG_C5 = 0xC5; // iso
final int TAG_C6 = 0xC6; // iso_id
final int TAG_C7 = 0xC7; // node_count
final int TAG_C8 = 0xC8; // ins_flag
final int TAG_C9 = 0xC9; // ins_id

boolean dbgWaitVal = false;
int dbgTag = 0;

// decoded
int dbgType=-1, dbgS1=-1, dbgS2=-1, dbgEdge01=-1, dbgSample=-1;
int dbgES1S2Pre=-1;
int dbgDegS1=-1, dbgDegS2=-1;
int dbgConn=-1, dbgRm=-1, dbgIso=-1, dbgIsoId=-1;
int dbgNodes=-1, dbgIns=-1, dbgInsId=-1;

int dbgErr0=-1, dbgErr1=-1, dbgErr2=-1, dbgErr3=-1;
long dbgErr32=-1;

int dbgXLo=-1, dbgXHi=-1, dbgYLo=-1, dbgYHi=-1;
float dbgS1X = Float.NaN;
float dbgS1Y = Float.NaN;

int dbgFrameCount=0;
int dbgLastMs=0;
String dbgMsg="waiting TLV...";

// history
final int DBG_HIST_MAX = 32;
String[] histLine = new String[DBG_HIST_MAX];
int dbgHistN=0;

// (optional framed parser remains idle)
final int MAX_PAYLOAD=4096;
enum RxState { FIND_FF1, FIND_FF2, LEN0, LEN1, SEQ, PAYLOAD, CHK }
RxState st = RxState.FIND_FF1;
int expectLen=0, payIdx=0, chkCalc=0, chkRx=0;
byte[] payload = new byte[MAX_PAYLOAD];

byte[] inBuf = new byte[8192];
int lastByteMs=0;
final int PARSER_TIMEOUT_MS=120;

// UI bounds
float viewMinX, viewMaxX, viewMinY, viewMaxY;

// ======================================================
void setup() {
  size(1400, 780);
  surface.setTitle("GNG Viewer (DBG TLV + insert/prune)");
  textFont(createFont("Consolas", 14));
  frameRate(60);

  println("Available ports:");
  println(Serial.list());

  buildTwoMoonsAndPack();

  myPort = new Serial(this, PORT_NAME, BAUD);
  delay(200);

  sendDatasetOnce();
}

void draw() {
  background(18);
  drawPanels();
  drawDebugBar();

  if (st != RxState.FIND_FF1 && (millis()-lastByteMs) > PARSER_TIMEOUT_MS) {
    resetParser();
  }
}

void keyPressed() {
  if (key=='r' || key=='R') { buildTwoMoonsAndPack(); sendDatasetOnce(); }
  else if (key=='s' || key=='S') { sendDatasetOnce(); }
}

// ======================================================
void sendDatasetOnce() {
  resetParser();
  dbgWaitVal=false;
  dbgTag=0;
  dbgFrameCount=0;
  dbgHistN=0;
  myPort.write(txBuf);
}

// ======================================================
void serialEvent(Serial p) {
  int n = p.readBytes(inBuf);
  if (n<=0) return;
  lastByteMs = millis();

  for (int i=0; i<n; i++) {
    int ub = inBuf[i] & 0xFF;

    if (dbgWaitVal) {
      dbgWaitVal=false;
      onDbgTLV(dbgTag, ub);
      continue;
    }

    if (st == RxState.FIND_FF1) {
      if (isDbgTag(ub)) {
        dbgTag = ub;
        dbgWaitVal = true;
        continue;
      }
    }

    feedParser(ub);
  }
}

boolean isDbgTag(int ub) {
  return ub==TAG_A5||ub==TAG_A6||ub==TAG_A7||ub==TAG_A8||ub==TAG_A9
      || ub==TAG_AA||ub==TAG_AB||ub==TAG_AC||ub==TAG_AD
      || ub==TAG_AE||ub==TAG_AF||ub==TAG_B0||ub==TAG_B1
      || ub==TAG_C0||ub==TAG_C1||ub==TAG_C2||ub==TAG_C3||ub==TAG_C4
      || ub==TAG_C5||ub==TAG_C6||ub==TAG_C7||ub==TAG_C8||ub==TAG_C9;
}

short s16_from_lohi(int lo, int hi) {
  return (short)((lo & 0xFF) | ((hi & 0xFF) << 8));
}

void onDbgTLV(int tag, int val) {
  dbgLastMs = millis();
  val &= 0xFF;

  if (tag==TAG_A5) dbgType=val;
  if (tag==TAG_A6) dbgS1=val;
  if (tag==TAG_A7) dbgS2=val;
  if (tag==TAG_A8) dbgEdge01=val;
  if (tag==TAG_A9) dbgSample=val;

  if (tag==TAG_C0) dbgES1S2Pre=val;
  if (tag==TAG_C1) dbgDegS1=val;
  if (tag==TAG_C2) dbgDegS2=val;
  if (tag==TAG_C3) dbgConn=val & 1;
  if (tag==TAG_C4) dbgRm=val & 1;
  if (tag==TAG_C5) dbgIso=val & 1;
  if (tag==TAG_C6) dbgIsoId=val;
  if (tag==TAG_C7) dbgNodes=val;
  if (tag==TAG_C8) dbgIns=val & 1;
  if (tag==TAG_C9) dbgInsId=val;

  if (tag==TAG_AA) dbgErr0=val;
  if (tag==TAG_AB) dbgErr1=val;
  if (tag==TAG_AC) dbgErr2=val;
  if (tag==TAG_AD) dbgErr3=val;

  if (tag==TAG_AE) dbgXLo=val;
  if (tag==TAG_AF) dbgXHi=val;
  if (tag==TAG_B0) dbgYLo=val;
  if (tag==TAG_B1) dbgYHi=val;

  if (dbgErr0>=0 && dbgErr1>=0 && dbgErr2>=0 && dbgErr3>=0) {
    dbgErr32 = ((long)dbgErr3<<24) | ((long)dbgErr2<<16) | ((long)dbgErr1<<8) | (long)dbgErr0;
    dbgErr32 &= 0xFFFFFFFFL;
  }

  if (dbgXLo>=0 && dbgXHi>=0) dbgS1X = s16_from_lohi(dbgXLo, dbgXHi) / SCALE;
  if (dbgYLo>=0 && dbgYHi>=0) dbgS1Y = s16_from_lohi(dbgYLo, dbgYHi) / SCALE;

  dbgMsg =
    "type=0x" + hex(max(dbgType,0),2) +
    " s1=" + dbgS1 + " s2=" + dbgS2 +
    " edge01=" + dbgEdge01 +
    " e_s1s2_pre=" + dbgES1S2Pre +
    " deg=(" + dbgDegS1 + "," + dbgDegS2 + ")" +
    " conn=" + (dbgConn==1?"Y":"N") +
    " rm=" + dbgRm +
    " iso=" + dbgIso + "(id=" + dbgIsoId + ")" +
    " nodes=" + dbgNodes +
    " ins=" + dbgIns + "(id=" + dbgInsId + ")" +
    " err=" + dbgErr32 +
    " s1xy=(" + (Float.isNaN(dbgS1X)?"--":nf(dbgS1X,1,4)) + "," + (Float.isNaN(dbgS1Y)?"--":nf(dbgS1Y,1,4)) + ")";

  if (tag==TAG_A9) {
    dbgFrameCount++;
    pushHistory(dbgMsg);
  }
}

void pushHistory(String s) {
  if (dbgHistN < DBG_HIST_MAX) {
    histLine[dbgHistN++] = s;
  } else {
    for (int k=0; k<DBG_HIST_MAX-1; k++) histLine[k]=histLine[k+1];
    histLine[DBG_HIST_MAX-1] = s;
  }
}

// ======================================================
// framed parser (idle/minimal)
// ======================================================
void feedParser(int ub) {
  switch(st) {
    case FIND_FF1: if (ub==0xFF) st=RxState.FIND_FF2; break;
    case FIND_FF2: if (ub==0xFF) st=RxState.LEN0; else st=RxState.FIND_FF1; break;
    case LEN0: expectLen=ub; st=RxState.LEN1; break;
    case LEN1: expectLen |= (ub<<8); if (expectLen<=0||expectLen>MAX_PAYLOAD) resetParser(); else st=RxState.SEQ; break;
    case SEQ: payIdx=0; chkCalc=0; st=RxState.PAYLOAD; break;
    case PAYLOAD: payload[payIdx++]=(byte)ub; chkCalc=(chkCalc+ub)&0xFF; if (payIdx>=expectLen) st=RxState.CHK; break;
    case CHK: chkRx=ub; resetParser(); break;
  }
}
void resetParser() { st=RxState.FIND_FF1; expectLen=0; payIdx=0; chkCalc=0; chkRx=0; }

// ======================================================
// UI
// ======================================================
void drawPanels() {
  float leftX=60, rightX=740, panelY=80, panelW=600, panelH=600;

  fill(230);
  text("TX DATASET (static)", leftX, 55);
  drawScatter(moonsTx, leftX, panelY, panelW, panelH, 255, 5);

  fill(230);
  text("RX: DEBUG TLV (now)", rightX, 55);
  drawScatter(moonsTx, rightX, panelY, panelW, panelH, 70, 4);

  if (!Float.isNaN(dbgS1X) && !Float.isNaN(dbgS1Y)) {
    float px = mapToPanelX(dbgS1X, rightX, panelW);
    float py = mapToPanelY(dbgS1Y, panelY, panelH);
    noStroke();
    fill(255, 220);
    ellipse(px, py, 14, 14);
    fill(255, 200);
    text("s1", px+10, py-10);
  }

  fill(0,160); noStroke();
  rect(rightX+20, panelY+20, panelW-40, 240);

  fill(220);
  int yy = (int)(panelY+45);
  text("DBG: " + dbgMsg, rightX+30, yy); yy+=22;
  text("Last DBG frames:", rightX+30, yy); yy+=18;

  int show = min(dbgHistN, 8);
  for (int k=0; k<show; k++) {
    int idx = dbgHistN - show + k;
    text("  " + k + ") " + histLine[idx], rightX+30, yy);
    yy += 16;
  }

  noFill(); stroke(60);
  rect(leftX, panelY, panelW, panelH);
  rect(rightX, panelY, panelW, panelH);
}

void drawScatter(float[][] pts, float x0, float y0, float w, float h, int alpha, float dotSize) {
  if (pts != null) {
    float minx=1e9, maxx=-1e9, miny=1e9, maxy=-1e9;
    for (int i=0;i<pts.length;i++){
      float x=pts[i][0], y=pts[i][1];
      minx=min(minx,x); maxx=max(maxx,x);
      miny=min(miny,y); maxy=max(maxy,y);
    }
    viewMinX=minx-0.35; viewMaxX=maxx+0.35;
    viewMinY=miny-0.35; viewMaxY=maxy+0.35;
  }

  noStroke();
  fill(0,0,0,110);
  rect(x0,y0,w,h);

  stroke(70);
  float xZero = map(0, viewMinX, viewMaxX, x0, x0+w);
  float yZero = map(0, viewMinY, viewMaxY, y0, y0+h);
  line(x0,yZero,x0+w,yZero);
  line(xZero,y0,xZero,y0+h);

  if (pts==null) return;
  noStroke();
  fill(255,alpha);
  for (int i=0;i<pts.length;i++){
    float px=mapToPanelX(pts[i][0], x0, w);
    float py=mapToPanelY(pts[i][1], y0, h);
    ellipse(px,py,dotSize,dotSize);
  }
}

float mapToPanelX(float x, float x0, float w) {
  float xn=(x-viewMinX)/(viewMaxX-viewMinX);
  return x0+10+xn*(w-20);
}
float mapToPanelY(float y, float y0, float h) {
  float yn=(y-viewMinY)/(viewMaxY-viewMinY);
  return y0+10+yn*(h-20);
}

void drawDebugBar() {
  fill(0,180);
  rect(0,height-90,width,90);

  fill(220);
  text("PORT=" + PORT_NAME + " BAUD=" + BAUD +
       " framed_state=" + st +
       " payload(" + payIdx + "/" + expectLen + ")", 30, height-60);

  int ago = (dbgLastMs==0) ? -1 : (millis()-dbgLastMs);
  text("DBG: age(ms)=" + ago + " frames=" + dbgFrameCount, 30, height-40);

  fill(180);
  text("Keys: [R]=rebuild+send [S]=send", 980, height-20);
}

// ======================================================
// Build dataset + pack
// ======================================================
void buildTwoMoonsAndPack() {
  moonsTx = generateMoons(MOONS_N, MOONS_RANDOM_ANGLE, MOONS_NOISE_STD, MOONS_SEED, MOONS_SHUFFLE, MOONS_NORMALIZE01);

  int p=0;
  for (int i=0;i<MOONS_N;i++){
    short xi=(short)round(moonsTx[i][0]*SCALE);
    short yi=(short)round(moonsTx[i][1]*SCALE);
    txBuf[p++]=(byte)(xi & 0xFF);
    txBuf[p++]=(byte)((xi>>8)&0xFF);
    txBuf[p++]=(byte)(yi & 0xFF);
    txBuf[p++]=(byte)((yi>>8)&0xFF);
  }
}

float[][] generateMoons(int N, boolean randomAngle, float noiseStd, int seed, boolean shuffle, boolean normalize01) {
  float[][] arr=new float[N][2];
  randomSeed(seed);

  for (int i=0;i<N/2;i++){
    float t = randomAngle ? random(PI) : map(i,0,(N/2)-1,0,PI);
    arr[i][0]=cos(t);
    arr[i][1]=sin(t);
  }
  for (int i=N/2;i<N;i++){
    int j=i-N/2;
    float t = randomAngle ? random(PI) : map(j,0,(N/2)-1,0,PI);
    arr[i][0]=1-cos(t);
    arr[i][1]=-sin(t)+0.5;
  }

  if (noiseStd>0){
    for (int i=0;i<N;i++){
      arr[i][0]+= (float)randomGaussian()*noiseStd;
      arr[i][1]+= (float)randomGaussian()*noiseStd;
    }
  }

  if (normalize01){
    float minx=999,maxx=-999,miny=999,maxy=-999;
    for (int i=0;i<N;i++){
      minx=min(minx,arr[i][0]); maxx=max(maxx,arr[i][0]);
      miny=min(miny,arr[i][1]); maxy=max(maxy,arr[i][1]);
    }
    float dx=max(1e-9, maxx-minx);
    float dy=max(1e-9, maxy-miny);
    for (int i=0;i<N;i++){
      arr[i][0]=(arr[i][0]-minx)/dx;
      arr[i][1]=(arr[i][1]-miny)/dy;
    }
  }

  if (shuffle){
    for (int i=N-1;i>0;i--){
      int j=(int)random(i+1);
      float tx=arr[i][0], ty=arr[i][1];
      arr[i][0]=arr[j][0]; arr[i][1]=arr[j][1];
      arr[j][0]=tx; arr[j][1]=ty;
    }
  }
  return arr;
}
