//---------------------------------------------------
// CONFIG
//---------------------------------------------------
#define MAXPTS   100
#define MAX_NODES 20
#define MAX_EDGES 40

float dataX[MAXPTS];
float dataY[MAXPTS];
int dataCount = 0;

bool dataDone = false;
bool running = false;

// GNG parameters
float epsilon_b = 0.08;
float epsilon_n = 0.02;
float alpha     = 0.5;
float beta      = 0.995;
int   lambda_it = 20;   // insert node every 20 steps

//---------------------------------------------------
// GNG STRUCTURES
//---------------------------------------------------
struct Node {
  float x, y;
  float error;
  bool active;
};

struct Edge {
  int a, b;
  int age;
  bool active;
};

Node nodes[MAX_NODES];
Edge edges[MAX_EDGES];

int nodeCount = 0;
int stepCount = 0;


//---------------------------------------------------
// UTILITIES
//---------------------------------------------------
float dist2(float x1,float y1,float x2,float y2){
  float dx=x1-x2, dy=y1-y2;
  return dx*dx + dy*dy;
}

int findFreeNode(){
  for(int i=0;i<MAX_NODES;i++){
    if(!nodes[i].active) return i;
  }
  return -1;
}

void connectNodes(int a,int b){
  // If already exist → reset age
  for(int i=0;i<MAX_EDGES;i++){
    if(edges[i].active &&
      ((edges[i].a==a && edges[i].b==b) ||
       (edges[i].a==b && edges[i].b==a)))
    {
      edges[i].age=0;
      return;
    }
  }

  // Create new edge
  for(int i=0;i<MAX_EDGES;i++){
    if(!edges[i].active){
      edges[i].a = a;
      edges[i].b = b;
      edges[i].age = 0;
      edges[i].active = true;
      return;
    }
  }
}

void ageEdgesOfWinner(int winner){
  for(int i=0;i<MAX_EDGES;i++){
    if(edges[i].active &&
      (edges[i].a==winner || edges[i].b==winner))
    {
      edges[i].age++;
      if(edges[i].age > 50)
        edges[i].active = false;
    }
  }
}

//---------------------------------------------------
// INSERT NEW NODE
//---------------------------------------------------
void insertNode(){
  // find q = node with highest error
  int q = -1;
  float maxErr = -1;
  for(int i=0;i<MAX_NODES;i++){
    if(nodes[i].active && nodes[i].error > maxErr){
      q = i;
      maxErr = nodes[i].error;
    }
  }

  if(q < 0) return;

  // find f = neighbor of q with highest error
  int f = -1;
  maxErr = -1;

  for(int i=0;i<MAX_EDGES;i++){
    if(edges[i].active && edges[i].a == q){
      int b = edges[i].b;
      if(nodes[b].error > maxErr){
        maxErr = nodes[b].error;
        f = b;
      }
    }
    else if(edges[i].active && edges[i].b == q){
      int b = edges[i].a;
      if(nodes[b].error > maxErr){
        maxErr = nodes[b].error;
        f = b;
      }
    }
  }

  if(f < 0) return;

  int r = findFreeNode();
  if(r < 0) return;

  // new node at midpoint
  nodes[r].x = 0.5*(nodes[q].x + nodes[f].x);
  nodes[r].y = 0.5*(nodes[q].y + nodes[f].y);
  nodes[r].error = nodes[q].error * 0.5;
  nodes[r].active = true;
  nodeCount++;

  nodes[q].error *= alpha;
  nodes[f].error *= alpha;

  connectNodes(r,q);
  connectNodes(r,f);
}

//---------------------------------------------------
// SEND GNG STATE TO PROCESSING
//---------------------------------------------------
void sendGNG() {
  Serial.print("GNG:");

  // nodes
  for(int i=0;i<MAX_NODES;i++){
    if(nodes[i].active){
      Serial.print("N:");
      Serial.print(i);
      Serial.print(",");
      Serial.print(nodes[i].x, 3);
      Serial.print(",");
      Serial.print(nodes[i].y, 3);
      Serial.print(";");
    }
  }

  // edges
  for(int i=0;i<MAX_EDGES;i++){
    if(edges[i].active){
      Serial.print("E:");
      Serial.print(edges[i].a);
      Serial.print(",");
      Serial.print(edges[i].b);
      Serial.print(";");
    }
  }

  Serial.println();
}

//---------------------------------------------------
// READ SERIAL FROM PROCESSING
//---------------------------------------------------
void readSerial() {
  static String s = "";

  while (Serial.available()) {
    char c = Serial.read();

    if (c == '\n') {

      if (s.equals("DONE;")) {
        dataDone = true;
        Serial.println("OK_DONE");
      }
      else if (s.equals("RUN;")) {
        running = true;
        Serial.println("OK_RUN");
      }
      else if (s.startsWith("DATA:")) {
        int c1 = s.indexOf(",");
        int c2 = s.indexOf(";");

        float x = s.substring(5, c1).toFloat();
        float y = s.substring(c1+1, c2).toFloat();

        if (dataCount < MAXPTS) {
          dataX[dataCount] = x;
          dataY[dataCount] = y;
          dataCount++;
        }
      }

      s = "";
    }
    else {
      s += c;
    }
  }
}

//---------------------------------------------------
// ONE GNG TRAINING STEP
//---------------------------------------------------
void trainOneStep(float x, float y) {

  int s1=-1, s2=-1;
  float d1=99999, d2=99999;

  // find nearest + 2nd nearest
  for(int i=0;i<MAX_NODES;i++){
    if(!nodes[i].active) continue;

    float d = dist2(x,y,nodes[i].x,nodes[i].y);

    if(d < d1){
      d2 = d1; s2 = s1;
      d1 = d;  s1 = i;
    }
    else if(d < d2){
      d2 = d;  s2 = i;
    }
  }

  // move winner
  nodes[s1].x += epsilon_b * (x - nodes[s1].x);
  nodes[s1].y += epsilon_b * (y - nodes[s1].y);

  // move neighbors
  for(int i=0;i<MAX_EDGES;i++){
    if(edges[i].active &&
      (edges[i].a==s1 || edges[i].b==s1))
    {
      int nb = (edges[i].a == s1 ? edges[i].b : edges[i].a);
      nodes[nb].x += epsilon_n * (x - nodes[nb].x);
      nodes[nb].y += epsilon_n * (y - nodes[nb].y);
    }
  }

  // increase error
  nodes[s1].error += d1;

  // connect s1-s2
  connectNodes(s1, s2);

  // age edges
  ageEdgesOfWinner(s1);

  stepCount++;

  // insert new node every λ iterations
  if(stepCount % lambda_it == 0 && nodeCount < MAX_NODES){
    insertNode();
  }

  // decrease all errors
  for(int i=0;i<MAX_NODES;i++){
    if(nodes[i].active)
      nodes[i].error *= beta;
  }
}

//---------------------------------------------------
// MAIN SETUP
//---------------------------------------------------
void setup(){
  Serial.begin(115200);

  // init nodes → 2 initial nodes
  nodes[0] = {0.2, 0.2, 0, true};
  nodes[1] = {0.8, 0.8, 0, true};
  nodeCount = 2;

  Serial.println("READY");
}

//---------------------------------------------------
// MAIN LOOP
//---------------------------------------------------
void loop(){
  readSerial();

  if (!dataDone) return;
  if (!running) return;

  // LOOP THROUGH DATASET
  static int idx = 0;

  float x = dataX[idx];
  float y = dataY[idx];

  idx++;
  if(idx >= dataCount) idx = 0;

  trainOneStep(x, y);
  sendGNG();
}
