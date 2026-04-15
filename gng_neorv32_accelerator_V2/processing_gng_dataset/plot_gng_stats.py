"""
plot_gng_stats.py
Reads the latest GNG CSV logs and plots:
  Left   : Network Growth  (node count + edge count vs epoch)
  Middle : Convergence     (quantization error vs epoch)
  Right  : Topological Err (TE vs epoch)

Usage:
  python plot_gng_stats.py                       # auto-detect latest log
  python plot_gng_stats.py 20260413_145711       # specific timestamp
  python plot_gng_stats.py 20260413_145711 30    # specific timestamp + max epochs
"""

import os, sys, glob, csv, math
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

# -------------------------------------------------------
# Config — must match VHDL generics
# -------------------------------------------------------
LOGS_PATH  = os.path.join(os.path.dirname(__file__), "logs")
SNAP_EVERY = 50    # iterations per snapshot  (VHDL: SNAP_EVERY)
DATA_WORDS = 100   # samples per epoch        (VHDL: DATA_WORDS)
ERR_SHIFT  = 4     # d² right-shift before add to err (VHDL: ERR_SHIFT)
SCALE      = 1000.0
MAX_EPOCHS = 64

SNAPS_PER_EPOCH = DATA_WORDS // SNAP_EVERY   # = 2

# -------------------------------------------------------
# Find log timestamp
# -------------------------------------------------------
def find_latest(logs_path):
    files = glob.glob(os.path.join(logs_path, "dataset_*.csv"))
    if not files:
        raise FileNotFoundError(f"No dataset_*.csv in {logs_path}")
    return os.path.basename(max(files)).replace("dataset_","").replace(".csv","")

ts = sys.argv[1] if len(sys.argv) > 1 else find_latest(LOGS_PATH)
if len(sys.argv) > 2:
    MAX_EPOCHS = int(sys.argv[2])
print(f"Log set: {ts}  (max epochs: {MAX_EPOCHS})")

dataset_file = os.path.join(LOGS_PATH, f"dataset_{ts}.csv")
nodes_file   = os.path.join(LOGS_PATH, f"gng_nodes_{ts}.csv")
edges_file   = os.path.join(LOGS_PATH, f"gng_edges_{ts}.csv")
dbg_file     = os.path.join(LOGS_PATH, f"gng_dbg_{ts}.csv")

# -------------------------------------------------------
# Load dataset (for TE computation)
# -------------------------------------------------------
dataset = []
with open(dataset_file, newline="") as f:
    for row in csv.DictReader(f):
        dataset.append((float(row["x_norm"]), float(row["y_norm"])))

# -------------------------------------------------------
# 1. Node counts + positions per snap_idx
# -------------------------------------------------------
node_counts = {}                # snap_idx -> active node count
nodes_by_snap = {}              # snap_idx -> {node_id: (x, y)}
with open(nodes_file, newline="") as f:
    for row in csv.DictReader(f):
        sid = int(row["snap_idx"])
        if row["active"] == "1":
            node_counts[sid] = node_counts.get(sid, 0) + 1
            nid = int(row["node_id"])
            x = float(row["x_norm"])
            y = float(row["y_norm"])
            nodes_by_snap.setdefault(sid, {})[nid] = (x, y)

# -------------------------------------------------------
# 2. Edge counts + edge sets per snap_idx
# -------------------------------------------------------
edge_counts = {}                # snap_idx -> active edge count
edges_by_snap = {}              # snap_idx -> set((a,b))
with open(edges_file, newline="") as f:
    for row in csv.DictReader(f):
        sid = int(row["snap_idx"])
        edge_counts[sid] = edge_counts.get(sid, 0) + 1
        a = int(row["node_a"])
        b = int(row["node_b"])
        edges_by_snap.setdefault(sid, set()).add((min(a, b), max(a, b)))

# -------------------------------------------------------
# 3. Compute TE per snapshot
# -------------------------------------------------------
def compute_te(nodes_dict, edges_set, samples):
    if len(nodes_dict) < 2:
        return float("nan")
    items = list(nodes_dict.items())  # [(nid, (x, y)), ...]
    misses = 0
    for sx, sy in samples:
        d1 = d2 = float("inf")
        s1 = s2 = -1
        for nid, (nx, ny) in items:
            d = (sx - nx)**2 + (sy - ny)**2
            if d < d1:
                d2, s2 = d1, s1
                d1, s1 = d, nid
            elif d < d2:
                d2, s2 = d, nid
        if s2 < 0:
            continue
        key = (min(s1, s2), max(s1, s2))
        if key not in edges_set:
            misses += 1
    return misses / len(samples)

te_by_snap = {}
for sid in sorted(nodes_by_snap.keys()):
    te_by_snap[sid] = compute_te(
        nodes_by_snap[sid],
        edges_by_snap.get(sid, set()),
        dataset,
    )

# -------------------------------------------------------
# Aggregate to epoch level: take last snap of each epoch
# -------------------------------------------------------
node_by_epoch = {}
edge_by_epoch = {}
te_by_epoch   = {}
all_snaps = sorted(set(node_counts) | set(edge_counts))
for sid in all_snaps:
    epoch = sid // SNAPS_PER_EPOCH
    if epoch >= MAX_EPOCHS:
        continue
    node_by_epoch[epoch] = node_counts.get(sid, node_by_epoch.get(epoch, 0))
    edge_by_epoch[epoch] = edge_counts.get(sid, edge_by_epoch.get(epoch, 0))
    if sid in te_by_snap:
        te_by_epoch[epoch] = te_by_snap[sid]

# -------------------------------------------------------
# 4. Quantization error per epoch from DBG CSV
# -------------------------------------------------------
epoch_err = {}
row_idx   = 0
with open(dbg_file, newline="") as f:
    for row in csv.DictReader(f):
        epoch = row_idx // DATA_WORDS
        row_idx += 1
        if epoch >= MAX_EPOCHS:
            break
        try:
            err32 = int(row["err32"])
        except (TypeError, ValueError):
            continue
        d2_approx = max(err32, 0) * (2 ** ERR_SHIFT)
        qe = math.sqrt(d2_approx) / SCALE
        epoch_err.setdefault(epoch, []).append(qe)

qe_by_epoch = {e: sum(v)/len(v) for e, v in epoch_err.items()}

# -------------------------------------------------------
# Build plot arrays
# -------------------------------------------------------
epochs = sorted(set(node_by_epoch) & set(qe_by_epoch) & set(te_by_epoch))

ep  = epochs
nc  = [node_by_epoch[e] for e in epochs]
ec  = [edge_by_epoch.get(e, 0) for e in epochs]
qe  = [qe_by_epoch[e] for e in epochs]
te  = [te_by_epoch[e] for e in epochs]

print(f"Epochs in plot: {min(epochs)} – {max(epochs)}  ({len(epochs)} points)")
print(f"Final TE = {te[-1]:.4f}")

# -------------------------------------------------------
# Plot (1x3)
# -------------------------------------------------------
fig, (ax1, ax2, ax3) = plt.subplots(1, 3, figsize=(11, 3.5))
fig.subplots_adjust(wspace=0.38, bottom=0.18)

# — Left: Network Growth —
ax1.plot(ep, nc, "o-", color="tab:red",  markersize=4, linewidth=1.4, label="Nodes")
ax1.plot(ep, ec, "s-", color="tab:blue", markersize=4, linewidth=1.4, label="Edges")
ax1.set_title("Network Growth", fontsize=11)
ax1.set_xlabel("Epoch", fontsize=10)
ax1.set_ylabel("Count", fontsize=10)
ax1.legend(fontsize=9)
ax1.xaxis.set_major_locator(ticker.MaxNLocator(integer=True))
ax1.yaxis.set_major_locator(ticker.MaxNLocator(integer=True))
ax1.grid(True, linestyle="--", alpha=0.4)
ax1.set_xlim(left=0)
ax1.set_ylim(bottom=0)

# — Middle: Convergence (QE) —
ax2.plot(ep, qe, "o-", color="tab:green", markersize=4, linewidth=1.4)
ax2.set_title("Convergence", fontsize=11)
ax2.set_xlabel("Epoch", fontsize=10)
ax2.set_ylabel("Quantization Error", fontsize=10)
ax2.xaxis.set_major_locator(ticker.MaxNLocator(integer=True))
ax2.grid(True, linestyle="--", alpha=0.4)
ax2.set_xlim(left=0)
ax2.set_ylim(bottom=0)

# — Right: Topological Error —
ax3.plot(ep, te, "o-", color="tab:purple", markersize=4, linewidth=1.4)
ax3.set_title("Topological Error", fontsize=11)
ax3.set_xlabel("Epoch", fontsize=10)
ax3.set_ylabel("TE (fraction)", fontsize=10)
ax3.xaxis.set_major_locator(ticker.MaxNLocator(integer=True))
ax3.grid(True, linestyle="--", alpha=0.4)
ax3.set_xlim(left=0)
ax3.set_ylim(bottom=0)

out_path = os.path.join(LOGS_PATH, f"gng_stats_{ts}.png")
plt.savefig(out_path, dpi=150, bbox_inches="tight")
print(f"Saved: {out_path}")
plt.show()
