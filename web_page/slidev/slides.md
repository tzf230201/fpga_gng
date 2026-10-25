---
theme: default
title: Growing Neural Gas Algorithm for Embedded and FPGA
info: |
  GNG, FPGA fundamentals, and the Tang Nano 9K implementation.
  Based on the supplied conference presentation, with current project results.
class: cover-slide
layout: default
highlighter: shiki
colorSchema: light
transition: fade
mdc: true
canvasWidth: 1280
aspectRatio: 16/9
fonts:
  sans: Arial
  serif: Georgia
  mono: Consolas
  provider: none
defaults:
  layout: default
  class: gng-slide
---

<img class="cover-bg" src="/reference/cover.png" alt="Circuit board background from the reference presentation">
<div class="cover-content">
  <div class="cover-university">Tokyo Metropolitan University</div>
  <h1>Growing Neural Gas Algorithm<br>for Embedded and FPGA</h1>
  <div class="cover-subtitle">Online topology learning on the Tang Nano 9K</div>
  <div class="cover-authors">
    Teuku Zikri Fatahillah, Raditya Artha Rochmanto, Achmad Fahrul Aji,<br>
    Anhar Risnumawan, Adnan Rachmat Anom Besari, Naoyuki Kubota
  </div>
</div>

<!--
Reference presentation: FPGA GNG.pptx, slide 1. The title and author list follow the supplied presentation.
Experimental implementation and figures follow web_page/index.html and the accompanying main.tex.
-->

---

# Outline

<div class="outline-list">
  <div><span>01</span><section><h2>Growing Neural Gas</h2><p>Topology learning, applications, and developments in Kubota Lab</p></section></div>
  <div><span>02</span><section><h2>FPGA and parallel computation</h2><p>Logic resources, instruction dependencies, and specialized hardware</p></section></div>
  <div><span>03</span><section><h2>GNG on FPGA</h2><p>Memory representation, arithmetic, implementation, and experiments</p></section></div>
</div>

<!-- Reference presentation: slides 2, 11, 65, and 91. Repeated outline slides are combined here. -->

---

# What is Growing Neural Gas?

<div class="columns align-center">
  <video class="video square" src="/reference/gng-learning.mp4" poster="/reference/gng-learning-poster.jpg" controls playsinline preload="metadata" aria-label="Growing Neural Gas learning demonstration"></video>
  <div>
    <p class="lead">A graph that learns the structure of an unlabeled data distribution.</p>
    <ul>
      <li><strong>Nodes</strong> represent prototype positions.</li>
      <li><strong>Edges</strong> describe local neighborhood relationships.</li>
      <li>Node insertion and edge aging let the topology change during learning.</li>
    </ul>
  </div>
</div>

<!-- Reference presentation: slide 3 and its embedded video. Algorithmic description: supplied main.tex, Introduction and GNG background. -->

---

# Applications of GNG

<div class="columns wide-left align-center">
  <div>
    <h2>Healthcare</h2><p class="small">Clustering and segmentation in mammogram and dermatology data</p>
    <h2>Surveillance</h2><p class="small">Anomaly detection from learned patterns</p>
    <h2>Art and engineering</h2><p class="small">Topology extraction, data compression, and semantic mapping</p>
  </div>
  <figure class="figure"><img src="/reference/gng-art.png" alt="Portrait reconstructed as a topology graph"><figcaption>Topology extraction for a visual representation</figcaption></figure>
</div>

<!--
Reference presentation: slides 4–5. Image extracted unchanged from that presentation.
Application references supplied there: doi:10.1016/j.bdr.2021.100254; doi:10.1016/j.patcog.2016.09.016; neupy.com/2018/03/26/making_art_with_growing_neural_gas.html; doi:10.1038/s41598-022-19599-2.
-->

---

# GNG variations in Kubota Lab

<img class="full-figure" src="/reference/gng-variants.png" alt="Research lineage of GNG variants, including dynamic density, utility, batch, and multiscale methods">

<div class="footnote">Related directions include density adaptation, utility, batch learning, and multiscale topology extraction.</div>

<!-- Reference presentation: slides 6–10. The supplied lineage figure is preserved. Progressive highlights are combined into one overview. -->

---

# Dynamic density and topology mapping

<video class="video" src="/reference/dynamic-density.mp4" poster="/reference/dynamic-density.png" controls playsinline preload="metadata" aria-label="Dynamic Density Growing Neural Gas mapping demonstration"></video>

<div class="footnote">Dynamic Density GNG example: object and environment structure from spatial observations</div>

<!-- Reference presentation: slide 7 and its embedded DD-GNG video. Separate from the two static FPGA benchmark experiments. -->

---

# What is an FPGA?

<p class="lead">A Field Programmable Gate Array implements digital hardware that can be reconfigured after manufacturing.</p>

<img src="/reference/architectures.png" alt="Conceptual CPU, GPU, FPGA, and ASIC architectures" style="width:100%;height:285px;object-fit:contain;margin-top:24px">

<p class="small muted">The FPGA configuration defines logic functions and the connections between them.</p>

<!-- Reference presentation: slides 12–18 and 92. Architecture illustration extracted from the source deck. -->

---

# Logic cells, LUTs, and routing

<div class="columns align-center">
  <div>
    <h2>Logic cells</h2><p>LUTs implement logic functions. Registers hold state between clock edges.</p>
    <h2>Routing fabric</h2><p>Configurable interconnect joins the cells into datapaths and control logic.</p>
    <p class="statement small">Replicating computation consumes logic and routing resources.</p>
  </div>
  <figure class="figure"><img src="/reference/logic-cell.png" alt="Illustrative Boolean logic feeding a logic gate"><figcaption>Illustrative logic function within the configurable fabric</figcaption></figure>
</div>

<!-- Reference presentation: slides 15–18 and 49. The gate illustration is conceptual, rather than a schematic of a particular LUT. -->

---

# What does a processor do?

<div class="columns wide-left">
  <div>
    <p>A compiled program becomes a sequence of machine instructions.</p>

```c
int distance2(int x, int y, int z,
              int nx, int ny, int nz) {
    int dx = x - nx;
    int dy = y - ny;
    int dz = z - nz;
    return dx*dx + dy*dy + dz*dz;
}
```

  </div>
  <div>
    <img src="/reference/processors.png" alt="Examples of processor packages" style="width:100%;height:185px;object-fit:contain;margin-bottom:30px">
    <p class="small">Loads, subtraction, multiplication, and addition implement the distance calculation.</p>
    <p class="small muted">The FPGA experiment later in this deck uses two coordinates.</p>
  </div>
</div>

<!-- Reference presentation: slides 19–21. This 3D C example is pedagogical, rather than the measured 2D benchmark. Exact instructions depend on the compiler and ISA. -->

---

# An algorithm as a recipe

<div class="columns wide-left align-center">
  <div>
    <p class="lead">A processor follows instructions, much like a cook follows a recipe.</p>
    <ol class="small">
      <li>Prepare the ingredients.</li>
      <li>Cook and season the rice.</li>
      <li>Cook the egg.</li>
      <li>Combine the prepared parts.</li>
    </ol>
    <p class="statement small">Some tasks can overlap. Others must wait for earlier results.</p>
  </div>
  <figure class="figure"><img src="/reference/omurice.jpeg" alt="Omurice used as a cooking analogy for program instructions"></figure>
</div>

<!-- Reference presentation: slide 22. Supplied omurice photograph preserved. -->

---

# A squared-distance instruction sequence

$$D = X^2 + Y^2 + Z^2$$

<table>
  <thead><tr><th>Operation</th><th>Instruction</th><th>Meaning</th></tr></thead>
  <tbody>
    <tr><td>1</td><td><code>mul R0, X, X</code></td><td>Compute X²</td></tr>
    <tr><td>2</td><td><code>mul R1, Y, Y</code></td><td>Compute Y²</td></tr>
    <tr><td>3</td><td><code>mul R2, Z, Z</code></td><td>Compute Z²</td></tr>
    <tr><td>4</td><td><code>add R0, R0, R1</code></td><td>Form the partial sum</td></tr>
    <tr><td>5</td><td><code>add D, R0, R2</code></td><td>Form the final sum</td></tr>
  </tbody>
</table>

<div class="footnote">Illustrative instructions. The next schedules assume one operation per lane per step.</div>

<!-- Reference presentation: slides 20–24. Instruction count alone does not establish elapsed CPU clock cycles. -->

---
clicks: 5
---

# One arithmetic lane

<p>All five operations use the same execution resource.</p>

<table class="schedule">
  <thead><tr><th>Step</th><th>Lane 1</th></tr></thead>
  <tbody>
    <tr v-click="1"><td>1</td><td class="operation">X²</td></tr>
    <tr v-click="2"><td>2</td><td class="operation">Y²</td></tr>
    <tr v-click="3"><td>3</td><td class="operation">Z²</td></tr>
    <tr v-click="4"><td>4</td><td class="operation">X² + Y²</td></tr>
    <tr v-click="5"><td>5</td><td class="operation">D = (X² + Y²) + Z²</td></tr>
  </tbody>
</table>

<div class="footnote">Simplified schedule: five steps. Real CPU timing also depends on pipelines, instruction latency, and memory access.</div>

<!-- Reference presentation: slides 24–30, combined into five click steps. Lanes describe execution resources in a simplified model, not separate CPU cores sharing registers. -->

---
clicks: 3
---

# Two arithmetic lanes

<p>Independent multiplications can execute at the same time.</p>

<table class="schedule">
  <thead><tr><th>Step</th><th>Lane 1</th><th>Lane 2</th></tr></thead>
  <tbody>
    <tr v-click="1"><td>1</td><td class="operation">X²</td><td class="operation">Y²</td></tr>
    <tr v-click="2"><td>2</td><td class="operation">Z²</td><td class="operation">X² + Y²</td></tr>
    <tr v-click="3"><td>3</td><td class="operation">D = (X² + Y²) + Z²</td><td>Available</td></tr>
  </tbody>
</table>

<p class="statement">The additions must wait for their input values.</p>

<div class="footnote">Simplified schedule with unit-latency operations and no communication overhead</div>

<!-- Reference presentation: slides 31–36. The two-core analogy becomes a two-lane execution model with explicit dependency assumptions. -->

---
clicks: 3
---

# Three arithmetic lanes

<p>More lanes expose the dependency limit of this expression.</p>

<table class="schedule">
  <thead><tr><th>Step</th><th>Lane 1</th><th>Lane 2</th><th>Lane 3</th></tr></thead>
  <tbody>
    <tr v-click="1"><td>1</td><td class="operation">X²</td><td class="operation">Y²</td><td class="operation">Z²</td></tr>
    <tr v-click="2"><td>2</td><td class="operation">X² + Y²</td><td>Available</td><td>Available</td></tr>
    <tr v-click="3"><td>3</td><td class="operation">D = (X² + Y²) + Z²</td><td>Available</td><td>Available</td></tr>
  </tbody>
</table>

<p class="statement">The critical path still contains a multiplication and two additions.</p>

<div class="footnote">Three steps in this model, even though all three squares start together</div>

<!-- Reference presentation: slides 37–42. Illustrative operation schedule, not a benchmark of an FPGA pipeline. -->

---

# Instruction-level parallelism

<div class="columns align-center">
  <figure class="figure"><img src="/reference/instruction-dependencies.png" alt="Three independent squares followed by two dependent additions"></figure>
  <div>
    <p>The first layer contains three independent operations.</p>
    <p>The next layers each depend on earlier results.</p>
    <p class="statement">Available parallel work changes during execution.</p>
    <p class="small muted">Hardware resources and the dependency graph jointly limit the schedule.</p>
  </div>
</div>

<!-- Reference presentation: slide 43. Original teaching figure retained. -->

---

# A more complex dependency graph

<img class="full-figure" src="/reference/complex-dependencies.png" alt="Program instructions and their dependency graph, including a conditional branch">

<!-- Reference presentation: slide 44. Original example retained with code and dependency graph together. -->

---

# Spatial computation on an FPGA

<p>Dedicated arithmetic units can operate on independent parts of the expression.</p>

<table>
  <thead><tr><th>Conceptual stage</th><th>Concurrent work</th><th>Dependency</th></tr></thead>
  <tbody>
    <tr><td>Square</td><td>X², Y², Z²</td><td>Input coordinates</td></tr>
    <tr><td>Partial sum</td><td>X² + Y²</td><td>Two square results</td></tr>
    <tr><td>Final sum</td><td>(X² + Y²) + Z²</td><td>Partial sum and Z²</td></tr>
  </tbody>
</table>

<p class="statement">Other configured logic can work alongside this datapath.</p>

<div class="footnote">Conceptual datapath. Pipeline depth, clock rate, and throughput depend on the implementation.</div>

<!-- Reference presentation: slides 45–48. Editable stage table represents the teaching content. The measured GNG FSM is described separately. -->

---

# Parallelism has a resource budget

<div class="columns wide-left">
  <div>
    <p>Replicating arithmetic consumes LUTs, DSP blocks, and routing.</p>
    <p>Parallel memory accesses also require enough BRAM ports or replicated memories.</p>
    <p class="statement">The design must fit the target FPGA and meet its timing constraints.</p>
  </div>
  <div>
    <h2>Tang Nano 9K capacity</h2>
    <table><thead><tr><th>Resource</th><th>Available</th></tr></thead><tbody><tr><td>LUT4</td><td>8,640</td></tr><tr><td>Flip-flops</td><td>6,693</td></tr><tr><td>BSRAM</td><td>26</td></tr><tr><td>DSP</td><td>10</td></tr></tbody></table>
  </div>
</div>

<!-- Reference presentation: slides 48–49. Device capacities: main.tex hardware/software configuration table. -->

---

# CPU, GPU, and FPGA trade-offs

<table>
  <thead><tr><th>Aspect</th><th>CPU</th><th>GPU</th><th>FPGA</th></tr></thead>
  <tbody>
    <tr><td>Computation</td><td>General instruction stream</td><td>Many concurrent threads</td><td>Configured datapaths</td></tr>
    <tr><td>Typical strength</td><td>Flexible control</td><td>Large parallel workloads</td><td>Custom dataflow and interfaces</td></tr>
    <tr><td>Development</td><td>Software toolchain</td><td>Parallel programming</td><td>Hardware design and verification</td></tr>
    <tr><td>Power and latency</td><td colspan="3">Depend on the device, workload, precision, and system configuration</td></tr>
  </tbody>
</table>

<p class="statement">Choose the architecture for the constraints of the application.</p>

<!-- Reference presentation: slides 50 and 54. Broad low/medium/high rankings and historical product prices are replaced with workload-dependent trade-offs. No measured CPU/GPU comparison is claimed. -->

---

# Why consider an FPGA for a small robot?

<div class="columns wide-left">
  <div>
    <figure class="figure"><img src="/reference/flapping-robot.png" alt="Lightweight flapping-wing robot" style="height:270px"><figcaption>Payload, energy, and size constrain onboard computing.</figcaption></figure>
    <img src="/reference/gpu.png" alt="Desktop GPU used as a size comparison" style="height:125px;max-width:380px;object-fit:contain;margin:20px auto 0">
  </div>
  <div>
    <figure class="figure"><img src="/reference/board-weight.jpeg" alt="Tang Nano board measured at 9.0 grams"><figcaption>9.0 g board measurement shown in the reference presentation</figcaption></figure>
    <p class="small">The current GNG design operates at <strong>27 MHz</strong> on the Tang Nano 9K.</p>
  </div>
</div>

<!-- Reference presentation: slides 51–54. Mass comes from the supplied scale photograph. Clock: current webpage. Historical power and price values are omitted because no current board-power comparison is supplied. -->

---

# Limits to frequency scaling

<img class="full-figure" src="/reference/frequency-scaling.png" alt="Historical processor trends illustrating limits to frequency scaling and instruction-level parallelism">

<!-- Reference presentation: slide 55. Historical Stanford CS149 teaching figure, credited Fall 2025 inside the supplied image. -->

---

# Specialization at datacenter scale

<div class="columns align-center">
  <figure class="figure"><img src="/reference/supercomputing.png" alt="GPU-accelerated supercomputing example"><figcaption>GPU-accelerated supercomputing</figcaption></figure>
  <figure class="figure"><img src="/reference/tpu-pod.png" alt="Tensor Processing Unit pod example"><figcaption>Specialized tensor computation</figcaption></figure>
</div>

<p class="statement">Large systems combine different processing resources for different tasks.</p>

<!-- Reference presentation: slides 56 and 59. Original Stanford CS149 figures. Specifications inside the figures describe the historical examples shown. -->

---

# Specialization in mobile systems

<div class="columns align-center">
  <figure class="figure"><img src="/reference/phone.png" alt="Mobile phone example from the reference lecture"></figure>
  <figure class="figure"><img src="/reference/phone-soc.png" alt="Mobile SoC with CPU, GPU, neural, media, and sensor processing examples"></figure>
</div>

<p class="statement">A mobile system assigns different workloads to specialized hardware blocks.</p>

<!-- Reference presentation: slides 57–58. Historical phone/SoC examples reproduced from the supplied Stanford figures. -->

---

# Specialized hardware for neural computation

<img class="full-figure" src="/reference/dnn-accelerators.png" alt="Examples of specialized hardware for deep neural-network computation">

<!-- Reference presentation: slide 60, credited there to Stanford CS149. -->

---

# Toward a topological processing unit

<p class="lead">Can topology learning also benefit from specialized hardware?</p>

<ul>
  <li>GNG repeatedly searches for nearest nodes.</li>
  <li>It updates node coordinates and graph connectivity for every input.</li>
  <li>A compact graph can represent local spatial structure for an embedded system.</li>
</ul>

<p class="statement">A TopoPU is a research direction motivated by these operations.</p>

<!-- Reference presentation: slides 61–62. TopoPU remains a proposed direction, not a processor demonstrated in these experiments. -->

---

# Challenges for GNG on a small FPGA

<div class="columns">
  <div>
    <h2>Dynamic topology</h2><p class="small">Nodes and edges change during learning, creating irregular control and memory access.</p>
    <h2>Limited memory</h2><p class="small">Dense adjacency duplicates entries for an undirected graph.</p>
    <h2>Arithmetic and logic cost</h2><p class="small">Floating-point arithmetic and wide parallel datapaths compete for limited resources.</p>
  </div>
  <div>
    <p class="lead">How can GNG fit a resource-constrained FPGA while preserving topology learning?</p>
    <p class="statement small">Co-design the graph representation, arithmetic, and update schedule.</p>
  </div>
</div>

<!-- Reference presentation: slides 63–64. Problem framing follows the current webpage. -->

---

# The canonical GNG loop

<div class="columns compact">
  <div>
    <h2>Per sample</h2>
    <ol>
      <li>Find the winner s₁ and runner-up s₂.</li>
      <li>Accumulate winner error and age its edges.</li>
      <li>Move the winner and its neighbors.</li>
      <li>Create or refresh the s₁–s₂ edge.</li>
      <li>Prune old edges and isolated nodes.</li>
    </ol>
  </div>
  <div>
    <h2>Growth and adaptation</h2>
    <ol start="6">
      <li>Every λ samples, find the largest-error node and its largest-error neighbor.</li>
      <li>Insert a node between them and split their edge.</li>
      <li>Reduce the affected error values.</li>
      <li>Decay all accumulated errors.</li>
      <li>Repeat for the next sample.</li>
    </ol>
  </div>
</div>

<div class="footnote">Initialize with two nodes. The next slide describes the measured FPGA's isolated-node policy.</div>

<!-- Reference presentation: slides 66–73. Canonical isolated-node removal differs from the current implementation. Full pseudocode condensed into editable steps. -->

---

# The implemented fused FPGA update

<table class="compact-table">
  <thead><tr><th>FSM phase</th><th>Work in the current implementation</th></tr></thead>
  <tbody>
    <tr><td><code>SAMPLE / WIN_SCAN</code></td><td>Read the input, then scan active node slots for s₁ and s₂</td></tr>
    <tr><td><code>UPDATE</code></td><td>Accumulate winner error, decay it, and move s₁ using Q8</td></tr>
    <tr><td><code>NB_SCAN</code></td><td>Decay other node errors, probe winner-incident edge cells, age/prune active edges, and move neighbors</td></tr>
    <tr><td><code>CONNECT</code></td><td>Create or reset the winner–runner-up edge</td></tr>
    <tr><td><code>INSERT</code></td><td>Insert a node every λ samples when capacity permits</td></tr>
  </tbody>
</table>

<p class="statement small">A sequential single-clock FSM combines related operations in one bounded scan.</p>
<p class="small">Degree counters detect isolated nodes. The FSM keeps them active so they can reconnect.</p>

<!-- Reference presentation: slide 74. Updated from webpage GNG Loop & Fused FPGA Update and main.tex Isolated-Node Handling. UPDATE handles the winner before NB_SCAN. The source's parallelism proposal is not claimed as the implemented design. -->

---

# Quantization and the node word

<p>Coordinates use signed 16-bit integers. Learning-rate coefficients carry the Q-format scaling.</p>

<table>
  <thead><tr><th>Node field</th><th>Width</th><th>Purpose</th></tr></thead>
  <tbody>
    <tr><td>x and y</td><td>16 + 16 bits</td><td>Integer coordinates</td></tr>
    <tr><td>Degree</td><td>8 bits</td><td>Incident-edge count</td></tr>
    <tr><td>Error</td><td>32 bits</td><td>Unsigned accumulated error</td></tr>
    <tr><td>Active flag and padding</td><td>8 bits</td><td>Slot state and alignment</td></tr>
    <tr class="memory-total"><td>Total</td><td>80 bits = 10 bytes</td><td>400 bytes for 40 nodes</td></tr>
  </tbody>
</table>

<!-- Reference presentation: slide 75. Updated from the webpage's actual 80-bit node layout. The source's general Q16.16/Q24.8/Q1.15 alternatives are replaced with the implemented integer coordinates and Q8/Q16 learning coefficients. -->

---

# Data normalization

<p>Normalize each input axis, scale it, and round before UART transmission.</p>

$$x_{\mathrm{int}} = \operatorname{round}\!\left(\frac{x-x_{\min}}{x_{\max}-x_{\min}}\cdot 2S-S\right),\qquad S=1000$$

<div class="columns align-center" style="margin-top:38px">
  <div><p class="emphasis">[−1000, 1000]</p><p>Integer coordinate range in the current FPGA experiment</p></div>
  <div><p class="small">The host performs normalization and scaling.</p><p class="small">Plots show coordinates rescaled to [−1, 1].</p><p class="small">The same scaling applies to x and y.</p></div>
</div>

<!-- Reference presentation: slide 76. Updated to S=1000 from the webpage and main.tex Datasets. The supplied PPT's S=10 is superseded. -->

---

# Fixed-point learning updates

<div class="columns">
<div>
<h2>Winner adaptation</h2>

$$\Delta x_w = \left\lfloor\frac{77(\xi_x-x_w)}{2^8}\right\rfloor$$

<p class="small">77 / 256 = <strong>0.30078125</strong></p>
<h2>Neighbor adaptation</h2>

$$\Delta x_n = \left\lfloor\frac{66(\xi_x-x_n)}{2^{16}}\right\rfloor$$

<p class="small">66 / 65536 ≈ <strong>0.00100708</strong></p>
</div>
<div>
<h2>Squared distance</h2>

$$d^2=(\xi_x-x_n)^2+(\xi_y-y_n)^2$$

<p class="small">Wide intermediates preserve the squared-distance result.</p>
<h2>Error decay</h2>
<p><code>err -= err &gt;&gt; 8</code></p>
<p class="small">Nominal decay factor 255 / 256 ≈ <strong>0.9961</strong></p>
</div>
</div>

<div class="footnote">The y coordinate uses the same rule. Error accumulation uses d² &gt;&gt; 4.</div>

<!-- Reference presentation: slide 77. Updated from webpage Fixed-Point Arithmetic. EPS_WIN_Q8=77, EPS_N_Q16=66. Signed arithmetic shifts implement the update. Error decay includes integer truncation. -->

---

# Current GNG parameters

<table class="compact-table">
  <thead><tr><th>Parameter</th><th>Value</th><th>Hardware setting</th></tr></thead>
  <tbody>
    <tr><td>Maximum nodes Nmax</td><td>40</td><td>Fixed node BRAM depth</td></tr>
    <tr><td>Maximum edge age Amax</td><td>50</td><td>A_MAX_STORED = 51</td></tr>
    <tr><td>Insertion interval λ</td><td>100 samples</td><td>Insertion counter</td></tr>
    <tr><td>Winner learning rate</td><td>≈ 0.301</td><td>EPS_WIN_Q8 = 77, shift 8</td></tr>
    <tr><td>Neighbor learning rate</td><td>≈ 0.001</td><td>EPS_N_Q16 = 66, shift 16</td></tr>
    <tr><td>Error split α</td><td>0.5</td><td>INS_ALPHA_SHIFT = 1</td></tr>
    <tr><td>Error decay β</td><td>≈ 0.9961</td><td>ERR_DECAY_SHIFT = 8</td></tr>
    <tr><td>Error accumulation scale</td><td>4 bits</td><td>ERR_SHIFT = 4</td></tr>
  </tbody>
</table>

<!-- Reference presentation: slide 85. Values match the current webpage and main.tex hyperparameters table. Older Nmax=20 and winner rate=0.03 are superseded. -->

---

# Half adjacency for an undirected graph

<div class="columns wide-left align-center">
  <table class="matrix compact-table">
    <thead><tr><th>i / j</th><th>0</th><th>1</th><th>2</th><th>3</th><th>4</th><th>5</th></tr></thead>
    <tbody>
      <tr><th>0</th><td class="unused">–</td><td class="edge">3</td><td class="edge">1</td><td>0</td><td>0</td><td>0</td></tr>
      <tr><th>1</th><td class="unused">–</td><td class="unused">–</td><td>0</td><td class="edge">7</td><td>0</td><td>0</td></tr>
      <tr><th>2</th><td class="unused">–</td><td class="unused">–</td><td class="unused">–</td><td class="edge">2</td><td class="edge">5</td><td>0</td></tr>
      <tr><th>3</th><td class="unused">–</td><td class="unused">–</td><td class="unused">–</td><td class="unused">–</td><td>0</td><td class="edge">1</td></tr>
      <tr><th>4</th><td class="unused">–</td><td class="unused">–</td><td class="unused">–</td><td class="unused">–</td><td class="unused">–</td><td class="edge">4</td></tr>
      <tr><th>5</th><td class="unused">–</td><td class="unused">–</td><td class="unused">–</td><td class="unused">–</td><td class="unused">–</td><td class="unused">–</td></tr>
    </tbody>
  </table>
  <div>
    <p>Store only pairs with <strong>i &lt; j</strong>.</p>
    <p>The lower triangle duplicates the upper triangle.</p>
    <p>The diagonal would describe self-edges and is unused.</p>
    <p class="small muted">Illustrative six-node example from the webpage</p>
  </div>
</div>

<!-- Reference presentation: slide 78. Editable table uses the webpage's example. Zero-valued upper cells are allocated but inactive. Lower-triangle and diagonal cells are not allocated. -->

---

# Edge-cell encoding and storage

<div class="columns align-center">
  <div>
    <table><thead><tr><th>Cell value</th><th>Meaning</th></tr></thead><tbody><tr><td>0</td><td>No edge</td></tr><tr><td>1</td><td>Edge with age 0</td></tr><tr><td>v &gt; 0</td><td>Edge with age v − 1</td></tr></tbody></table>
    <p class="small">One byte holds both edge presence and age.</p>
  </div>
  <div>
    <h2>At Nmax = 40</h2>
    <p>Dense adjacency: 40 × 40 = <strong>1,600 B</strong></p>
    <p>Edge cells: 40 × 39 / 2 = <strong>780 B</strong></p>
    <p class="emphasis">51.25% less edge storage</p>
    <p class="small">Total graph state: 2,000 B to 1,180 B<br><strong>41% reduction</strong></p>
  </div>
</div>

<div class="footnote">Analytical allocation comparison with the same 40-node capacity and 400-byte node array</div>

<!-- Reference presentation: slides 78–79 and 87. Memory values: webpage Edge-Cell Encoding and main.tex allocated BRAM footprint. Older 52.7%/1120 B/530 B example superseded. -->

---

# Half-adjacency indexing

$$\operatorname{idx}(i,j)=\frac{i(2N_{\max}-i-1)}{2}+(j-i-1),\qquad i<j$$

<div class="columns align-center">
  <div>
    <p>Flatten the upper triangle row by row.</p>
    <p>Swap i and j before indexing if i &gt; j.</p>
    <p class="statement small">Direct indexing gives constant-time access to a selected edge cell.</p>
  </div>
  <div>
    <h2>Example: Nmax = 4</h2>
    <table class="compact-table"><thead><tr><th>Node pair</th><th>Index</th></tr></thead><tbody><tr><td>(0, 1), (0, 2), (0, 3)</td><td>0, 1, 2</td></tr><tr><td>(1, 2), (1, 3)</td><td>3, 4</td></tr><tr><td>(2, 3)</td><td>5</td></tr></tbody></table>
  </div>
</div>

<!-- Reference presentation: slide 80. Formula matches the webpage. The source's four-node example uses zero-based IDs. -->

---

# Winner-search cost

<p class="lead">For each input sample, the current engine scans the active node slots.</p>

$$d_i^2=(\xi_x-x_i)^2+(\xi_y-y_i)^2$$

<ul>
  <li>Keep the smallest and second-smallest distance.</li>
  <li>The scan cost grows with the node capacity <strong>Nmax</strong>.</li>
  <li>Processing more input samples increases total training work.</li>
</ul>

<p class="statement">The implemented winner scan has O(Nmax) work per sample.</p>

<!-- Reference presentation: slide 81. Corrected the source's attribution of per-sample winner cost to dataset size. Current implementation: webpage WIN_SCAN and main.tex sequential FSM. -->

---

# Parallel winner search as a next step

<table>
  <thead><tr><th>Search lanes</th><th>Node groups for Nmax = 40</th><th>Additional requirement</th></tr></thead>
  <tbody>
    <tr><td>1, current design</td><td>40 node slots</td><td>Sequential BRAM scan</td></tr>
    <tr><td>2, candidate</td><td>20 pairs</td><td>Parallel reads and a top-two merge</td></tr>
    <tr><td>4, candidate</td><td>10 groups of four</td><td>More memory bandwidth and reduction logic</td></tr>
  </tbody>
</table>

<p class="small">Coordinate differences can also be computed independently within a distance unit.</p>
<p class="statement small">Wider search trades latency for logic, DSP use, and BRAM access capacity.</p>

<div class="footnote">Group counts illustrate partitioning. They are not measured cycle counts or speedups.</div>

<!-- Reference presentation: slides 82–83. Two- and four-finder concepts remain future options. The measured implementation is sequential. -->

---

# Experimental setup

<div class="columns align-center">
  <figure class="figure"><img src="/reference/host-laptop.jpeg" alt="Host laptop from the original experimental setup"><figcaption>Host: dataset transfer, visualization, and log collection</figcaption></figure>
  <figure class="figure"><img src="/reference/tang-nano.jpeg" alt="Tang Nano 9K on a breadboard"><figcaption>Tang Nano 9K: single-clock VHDL GNG engine</figcaption></figure>
</div>

<p class="statement small">USB/UART at 1 Mbit/s connects the host and FPGA. The engine runs at 27 MHz.</p>

<div class="footnote">Node, edge, and dataset memories use BRAM. Processing displays snapshots and Python supports analysis.</div>

<!-- Reference presentation: slide 84. Original photographs retained. Platform facts updated from webpage and main.tex. -->

---

# Datasets and evaluation protocol

<table>
  <thead><tr><th>Dataset</th><th>Samples</th><th>Geometry</th><th>Reference result</th></tr></thead>
  <tbody><tr><td>Two Moons</td><td>100</td><td>Interleaving crescents</td><td>Epoch 32</td></tr><tr><td>Concentric Circles</td><td>100</td><td>Two noisy rings</td><td>Epoch 64</td></tr></tbody>
</table>

<ul class="small">
  <li>Normalize each axis and scale to signed integers in [−1000, 1000].</li>
  <li>Use the same 40-node capacity and learning parameters.</li>
  <li>Compute quantization error and topological error from UART snapshots.</li>
</ul>

<p class="small"><a href="../publication_materials/dataset_two_moons.csv" download>Two Moons CSV</a> &nbsp; · &nbsp; <a href="../publication_materials/dataset_concentric_circle.csv" download>Concentric Circles CSV</a></p>

<!-- Reference presentation: slide 85. Updated from current figures and main.tex Datasets and Topology Learning Quality. Both CSVs have 100 records. Dataset labels are not supervised GNG training targets. -->

---

# Learned topology on the FPGA

<div class="columns">
  <figure class="figure"><img src="/images/two_moons_result.png" alt="Current Two Moons topology"><figcaption><strong>Two Moons, epoch 32</strong><br>35 nodes, 33 edges<br>QE 0.1832, TE 0.00</figcaption></figure>
  <figure class="figure"><img src="/images/concentric_circles_result.png" alt="Current Concentric Circles topology"><figcaption><strong>Concentric Circles, epoch 64</strong><br>40 nodes, 39 edges<br>QE 0.1960, TE 0.07</figcaption></figure>
</div>

<!-- Reference presentation: slide 86. Current webpage figures and main.tex snapshot table. Two Moons figure is epoch 32, not the epoch-64 result. -->

---

# Two Moons learning dynamics

<img class="full-figure" src="/images/two_moons_training.png" alt="Two Moons network growth, QE, and TE over 32 epochs">

<div class="footnote">Node and edge growth, quantization-error convergence, and topological error over 32 epochs</div>

<!-- Reference presentation: slide 86. Current Two Moons training figure and interpretation: main.tex Results. -->

---

# Concentric Circles learning dynamics

<img class="full-figure" src="/images/concentric_circles_training.png" alt="Concentric Circles network growth, QE, and TE over 64 epochs">

<div class="footnote">After the 40-node budget is reached, QE continues to fall while TE drifts upward.</div>

<!-- Current Concentric Circles figure and interpretation: main.tex Results. The fixed graph capacity limits further topology refinement after saturation. -->

---

# Quantization and topological error

<table class="compact-table">
  <thead><tr><th>Dataset</th><th>Epoch</th><th>Nodes</th><th>Edges</th><th>QE</th><th>TE</th></tr></thead>
  <tbody>
    <tr><td>Two Moons</td><td>16</td><td>19</td><td>22</td><td>0.4750</td><td>0.00</td></tr>
    <tr><td>Two Moons</td><td>32</td><td>35</td><td>33</td><td>0.1832</td><td>0.00</td></tr>
    <tr><td>Two Moons</td><td>48</td><td>40</td><td>37</td><td>0.1461</td><td>0.00</td></tr>
    <tr><td>Two Moons</td><td>64</td><td>40</td><td>34</td><td>0.1455</td><td>0.01</td></tr>
    <tr><td>Concentric Circles</td><td>16</td><td>19</td><td>33</td><td>0.6964</td><td>0.00</td></tr>
    <tr><td>Concentric Circles</td><td>32</td><td>35</td><td>36</td><td>0.2592</td><td>0.00</td></tr>
    <tr><td>Concentric Circles</td><td>48</td><td>40</td><td>40</td><td>0.2000</td><td>0.04</td></tr>
    <tr><td>Concentric Circles</td><td>64</td><td>40</td><td>39</td><td>0.1960</td><td>0.07</td></tr>
  </tbody>
</table>

<p class="small">Lower QE means closer prototypes. TE counts samples whose first two winners are not connected.</p>

<!-- Source: main.tex table tab:qe_te. Selected snapshots, not an average across repeated trials. Lower QE alone does not establish topology preservation after saturation. -->

---

# Hardware resource utilization

<table>
  <thead><tr><th>Resource</th><th>Used</th><th>Available</th><th>Reported utilization</th></tr></thead>
  <tbody>
    <tr><td>LUT / ALU / ROM16</td><td>3,205</td><td>8,640</td><td>38%</td></tr>
    <tr><td>Flip-flops</td><td>1,408</td><td>6,693</td><td>22%</td></tr>
    <tr><td>CLS</td><td>2,225</td><td>4,320</td><td>52%</td></tr>
    <tr><td>BSRAM</td><td>6</td><td>26</td><td>24%</td></tr>
    <tr><td>DSP</td><td>5</td><td>10</td><td>50%</td></tr>
  </tbody>
</table>

<p class="statement">The full design fits on the GW1NR-9C with Nmax = 40.</p>

<!-- Reference presentation: slide 87. Updated from the webpage (~38% LUT) and main.tex tab:synthesis. Percentages retained as reported in the paper, rather than recalculated from capacity ratios. Older 1,900-LUT result superseded. -->

---

# Measured runtime at 27 MHz

<table>
  <thead><tr><th>Dataset</th><th>Cycles/sample</th><th>µs/sample</th><th>Samples/s</th></tr></thead>
  <tbody><tr><td>Two Moons</td><td>16,852</td><td>624.1</td><td>1,602</td></tr><tr><td>Concentric Circles</td><td>16,931</td><td>627.1</td><td>1,595</td></tr></tbody>
</table>

<div class="columns" style="margin-top:38px">
  <div><p class="emphasis">About 625 µs/sample</p><p class="small">Similar observed latency on both datasets</p></div>
  <div><p class="emphasis">About 1,600 samples/s</p><p class="small">Measured from the FPGA cycle counter in the debug stream</p></div>
</div>

<p class="statement small">Measurements include per-sample UART debug transmission. The FSM computation alone takes fewer cycles.</p>

<!-- Source: webpage headline metrics and main.tex tab:runtime plus Computational Performance. Per-sample UART pacing contributes to latency. These are not isolated arithmetic-kernel timings or CPU/GPU speedup comparisons. -->

---

# Conclusion

<ul>
  <li><strong>Dynamic topology fits a small FPGA.</strong><br>Integer GNG learns both benchmark geometries on the Tang Nano 9K.</li>
  <li><strong>Graph-state allocation falls by 41%.</strong><br>Edge cells reduce total state from 2,000 B to 1,180 B.</li>
  <li><strong>The datapath uses integer arithmetic.</strong><br>Signed coordinates and Q8/Q16 updates avoid a floating-point unit.</li>
  <li><strong>Latency stays near 625 µs per sample.</strong><br>The measured sequential engine reaches about 1,600 samples/s.</li>
</ul>

<!-- Reference presentation: slide 87. Updated conclusions follow the webpage. Two static 2D benchmarks demonstrate feasibility, not live robot deployment or distribution-shift adaptation. -->

---

# Future work

<ul>
  <li><strong>Parallel winner search</strong><br>Evaluate wider distance units and top-two reduction under BRAM constraints.</li>
  <li><strong>Continual learning</strong><br>Test non-stationary sensor streams and adaptation without restarting.</li>
  <li><strong>Precision and node management</strong><br>Explore configurable learning rates and utility-based capacity management.</li>
  <li><strong>System integration</strong><br>Connect sensing pipelines and measure application-level power and latency.</li>
</ul>

<!-- Reference presentation: slide 88. Updated from main.tex Limitations and Future Works and webpage Future Prospects. Proposed directions, not measured outcomes. -->

---

# Prospective applications

<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:28px;margin-top:35px">
  <figure class="figure"><img class="application-photo" src="/images/future-aerial-robot.png" alt="Lightweight flapping robot"><figcaption><strong>Lightweight aerial robots</strong><br>Payload and energy constraints</figcaption></figure>
  <figure class="figure"><img class="application-photo" src="/images/future-bio-inspired-robot.jpg" alt="Bio-inspired robot"><figcaption><strong>Bio-inspired robots</strong><br>Strict body and compute limits</figcaption></figure>
  <figure class="figure"><img class="application-photo" src="/images/future-swarm-robot.jpg" alt="Swarm of small robots"><figcaption><strong>Swarm devices</strong><br>Distributed local topology</figcaption></figure>
  <figure class="figure"><img class="application-photo" src="/images/future-exploration-robot.png" alt="Exploration robot"><figcaption><strong>Exploration robots</strong><br>Long missions with local learning</figcaption></figure>
</div>

<p class="statement small" style="margin-top:35px">The current work establishes the hardware foundation. Deployment requires sensor-stream validation.</p>

<!--
Reference presentation: slide 89. Application images follow the current webpage.
Credits: EPFL / Raphael Zufferey; Hillary Sanctuary & BioRob (Pleurobot); Mike Rubenstein and Science/AAAS, Harvard SEAS (Kilobot); Canadian Space Agency.
-->

---
class: gng-slide thanks
---

# Thank you

<p class="lead">Questions and discussion</p>
<p>Teuku Zikri Fatahillah<br><span class="muted">Tokyo Metropolitan University</span></p>

<div class="resources">
  <a href="../">Project webpage</a>
  <a href="https://github.com/tzf230201/fpga_gng">Source code</a>
  <a href="../publication_materials/main.pdf">Paper PDF</a>
  <a href="../publication_materials/wcci2026-poster-a0-portrait.pptx">Poster PPTX</a>
  <a href="../publication_materials/dataset_two_moons.csv" download>Two Moons CSV</a>
  <a href="../publication_materials/dataset_concentric_circle.csv" download>Concentric Circles CSV</a>
</div>

<div class="footnote">Supported by JST Moonshot R&amp;D Program, grant JPMJMS2034</div>

<!-- Reference presentation: slide 90. Resource links and acknowledgment follow the webpage. Supplementary demonstrations follow. -->

---

# Supplementary demo: UART visualization

<video class="video" src="/reference/uart-demo.mp4" poster="/reference/demo-uart.png" controls playsinline preload="metadata" aria-label="UART host visualization demonstration"></video>

<div class="footnote">Host visualization demonstration from the conference presentation</div>

<!-- Reference presentation: slide 93 and its embedded video. Historical screen values are not the current experimental measurements. -->

---

# Supplementary demo: firmware and host

<video class="video" src="/reference/firmware-demo.mp4" poster="/reference/demo-firmware.png" controls playsinline preload="metadata" aria-label="Firmware and host demonstration"></video>

<div class="footnote">Firmware and host workflow demonstration</div>

<!-- Reference presentation: slide 94 and its embedded video. Demonstration, not the source of the updated result tables. -->

---

# Supplementary demo: side-by-side runs

<video class="video" src="/reference/comparison-demo.mp4" poster="/reference/demo-comparison.png" controls playsinline preload="metadata" aria-label="Side-by-side host runs from the supplied PowerPoint"></video>

<div class="footnote">Illustrative side-by-side execution from the conference presentation</div>

<!-- Reference presentation: slide 95. MOV converted to browser-compatible MP4. No quantitative speedup is inferred. -->

---

# References

<div class="columns compact">
  <div>
    <h2>Algorithm and implementation</h2>
    <p>Fritzke, <em>A Growing Neural Gas Network Learns Topologies</em>, NeurIPS 7.</p>
    <p>Fatahillah et al., <em>Edge-Cell Graph Encoding and Fixed-Point Arithmetic for FPGA Growing Neural Gas</em>, IJCNN 2026.</p>
    <p><a href="https://doi.org/10.1109/IJCNN69854.2026.11728420">doi:10.1109/IJCNN69854.2026.11728420</a></p>
    <h2>Parallel computation</h2>
    <p>Stanford CS149, Lecture 1: <em>Why Parallelism? Why Efficiency?</em></p>
  </div>
  <div>
    <h2>Applications cited in the PPT</h2>
    <p><a href="https://doi.org/10.1016/j.bdr.2021.100254">Healthcare and clustering</a></p>
    <p><a href="https://doi.org/10.1016/j.patcog.2016.09.016">Anomaly detection</a></p>
    <p><a href="http://neupy.com/2018/03/26/making_art_with_growing_neural_gas.html">Topology extraction for art</a></p>
    <p><a href="https://www.nature.com/articles/s41598-022-19599-2">Engineering and semantic mapping</a></p>
    <p class="muted">Figure credits appear in the relevant speaker notes.</p>
  </div>
</div>

<!-- Reference presentation: slides 4 and 96. Paper citation from repository README.md. Application sources supplied in the reference deck. -->
