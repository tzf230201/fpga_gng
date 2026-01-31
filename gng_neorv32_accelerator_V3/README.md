             ┌────────────────────────────┐
             │        PC / Processing      │
             │  - generate dataset (x,y)   │
             │  - visualize nodes/edges    │
             └─────────────┬──────────────┘
                           │ UART (binary frames)
                           ▼
┌──────────────────────────────────────────────────────────┐
│                    NEORV32 (CPU firmware)                │
│  - receive dataset (x,y)                                 │
│  - GNG update (Fritzke):                                 │
│      age edges, error, move nodes, connect edges, prune, │
│      insert node, decay error                             │
│  - maintain edges + ages + errors (CPU side)             │
│  - mirror node positions to CFS node_mem (write regs)     │
│  - call CFS to get winners (s1,s2, min1/min2)            │
└───────────────┬───────────────────────────────┬──────────┘
                │ XBUS / IO bus (CFS registers)  │ UART TX frames
                ▼                                ▼
┌──────────────────────────────────────────────────────────┐
│                 NEORV32 CFS (FPGA accelerator)           │
│  - node_mem[0..39] : (x,y) Q1.15 packed 32-bit           │
│  - input regs: XIN, YIN, NODE_COUNT, ACT_LO/HI           │
│  - compute: dist2 to all active nodes (1 node / clock)   │
│  - output regs: OUT_S12 (s1,s2), OUT_MIN1, OUT_MIN2      │
│  - status: BUSY/DONE (via REG_CTRL bits)                 │
└──────────────────────────────────────────────────────────┘


CPU (main.c)                                     CFS (VHDL)
────────────────────────────────────────────────────────────────
[1] Take a sample ξ = (x, y) from the dataset

[2] Synchronize updated nodes to the CFS
    (minimum: s1 & neighbors from the previous step;
     or full sync when inserting a node)

[3] ==== CALL CFS: find winners =================================>
    - write XIN, YIN, NODE_COUNT, ACT_LO/HI
    - CTRL.START
    - poll CTRL.DONE
    <=============================================================
    - read OUT_S12  => s1, s2
    - read OUT_MIN1 (optional) => d1

[4] Age edges connected to s1                (CPU)
[5] error[s1] += d1                          (CPU)

[6] Move s1 using ε_b                         (CPU)  -> then write node s1 to CFS
[7] Move neighbors of s1 using ε_n            (CPU)  -> then write neighbor nodes to CFS

[8] Connect / reset the edge (s1, s2)         (CPU)
[9] Delete old edges (age > a_max)            (CPU)
[10] Prune isolated nodes                     (CPU)

[11] Every λ steps: insert a new node         (CPU)  -> full sync nodes to CFS
[12] Decay all errors: error *= d             (CPU)

[13] Stream nodes + edges to PC (UART)        (CPU)




sequenceDiagram
  participant CPU as NEORV32 (main.c)
  participant CFS as CFS Winner Finder (VHDL)

  Note over CPU: (Optional) update node_mem in CFS (NODE_BASE+i)<br/>Minimal updates: s1 and its neighbors (from the previous step)
  CPU->>CFS: write NODE_BASE+s1 = pack(x_s1, y_s1)
  CPU->>CFS: write NODE_BASE+nb = pack(x_nb, y_nb) (for each neighbor)

  Note over CPU: Full sync when inserting a new node (write all active nodes)

  Note over CPU,CFS: Winner search transaction (register protocol)
  CPU->>CFS: write REG_XIN        = x_q15
  CPU->>CFS: write REG_YIN        = y_q15
  CPU->>CFS: write REG_NODE_COUNT = 40
  CPU->>CFS: write REG_ACT_LO     = mask[0..31]
  CPU->>CFS: write REG_ACT_HI     = mask[32..39]
  CPU->>CFS: write REG_CTRL       = START

  loop Poll until DONE
    CPU->>CFS: read REG_CTRL
    CFS-->>CPU: BUSY/DONE status bits
  end

  CPU->>CFS: read REG_OUT_S12
  CFS-->>CPU: s1, s2

  CPU->>CFS: read REG_OUT_MIN1
  CFS-->>CPU: min1 (distance)
