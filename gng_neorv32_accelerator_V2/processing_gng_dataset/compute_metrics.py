"""
compute_metrics.py
Computes QE, TE, and runtime metrics from GNG CSV logs.

Usage:
  python compute_metrics.py                       # auto-detect latest
  python compute_metrics.py 20260413_180644       # specific timestamp
  python compute_metrics.py 20260413_180644 20260413_180416   # multiple
"""

import os, sys, csv, math, glob

LOGS_PATH   = os.path.join(os.path.dirname(__file__), "logs")
SCALE       = 1000.0
DATA_WORDS  = 100
SNAP_EVERY  = 50
CLOCK_HZ    = 27_000_000

def find_latest(logs_path):
    files = glob.glob(os.path.join(logs_path, "dataset_*.csv"))
    if not files:
        raise FileNotFoundError(f"No dataset_*.csv in {logs_path}")
    return os.path.basename(max(files)).replace("dataset_","").replace(".csv","")

def load_dataset(ts):
    path = os.path.join(LOGS_PATH, f"dataset_{ts}.csv")
    pts = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            pts.append((float(row["x_norm"]), float(row["y_norm"])))
    return pts

def load_final_nodes(ts):
    path = os.path.join(LOGS_PATH, f"gng_nodes_{ts}.csv")
    snaps = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            sid = int(row["snap_idx"])
            nid = int(row["node_id"])
            active = row["active"] == "1"
            x = float(row["x_norm"])
            y = float(row["y_norm"])
            deg = int(row["degree"])
            if sid not in snaps:
                snaps[sid] = {}
            snaps[sid][nid] = {"x": x, "y": y, "active": active, "deg": deg}
    last_sid = max(snaps.keys())
    return snaps[last_sid], last_sid

def load_final_edges(ts, snap_idx):
    path = os.path.join(LOGS_PATH, f"gng_edges_{ts}.csv")
    edges = set()
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if int(row["snap_idx"]) == snap_idx:
                a, b = int(row["node_a"]), int(row["node_b"])
                edges.add((min(a,b), max(a,b)))
    return edges

def load_dbg(ts):
    path = os.path.join(LOGS_PATH, f"gng_dbg_{ts}.csv")
    rows = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                rows.append({
                    "sample_idx": int(row["sample_idx"]),
                    "fpga_ts_cycles": int(row["fpga_ts_cycles"]),
                    "iter_us": float(row["iter_us"]),
                })
            except (TypeError, ValueError):
                pass
    return rows

def load_meta(ts):
    path = os.path.join(LOGS_PATH, f"meta_{ts}.txt")
    if os.path.exists(path):
        with open(path) as f:
            return f.readline().strip()
    return "Unknown"

def compute_qe(dataset, nodes):
    """QE = mean distance from each sample to its BMU."""
    active_nodes = [(n["x"], n["y"]) for n in nodes.values() if n["active"]]
    total = 0.0
    for sx, sy in dataset:
        min_d = float("inf")
        for nx, ny in active_nodes:
            d = math.sqrt((sx - nx)**2 + (sy - ny)**2)
            if d < min_d:
                min_d = d
        total += min_d
    return total / len(dataset)

def compute_te(dataset, nodes, edges):
    """TE = fraction of samples whose BMU and 2nd BMU are NOT connected."""
    active_nodes = [(nid, n["x"], n["y"]) for nid, n in nodes.items() if n["active"]]
    misses = 0
    for sx, sy in dataset:
        dists = []
        for nid, nx, ny in active_nodes:
            d = (sx - nx)**2 + (sy - ny)**2
            dists.append((d, nid))
        dists.sort()
        s1 = dists[0][1]
        s2 = dists[1][1]
        edge_key = (min(s1, s2), max(s1, s2))
        if edge_key not in edges:
            misses += 1
    return misses / len(dataset)

def compute_runtime(dbg_rows):
    """Compute runtime metrics from DBG rows."""
    # Per-sample cycles: difference between consecutive fpga_ts_cycles
    deltas = []
    for i in range(1, len(dbg_rows)):
        dc = dbg_rows[i]["fpga_ts_cycles"] - dbg_rows[i-1]["fpga_ts_cycles"]
        if dc > 0:
            deltas.append(dc)

    if not deltas:
        return None

    avg_cycles = sum(deltas) / len(deltas)
    avg_us = avg_cycles / (CLOCK_HZ / 1e6)
    throughput = CLOCK_HZ / avg_cycles if avg_cycles > 0 else 0

    # Total training time
    total_cycles = dbg_rows[-1]["fpga_ts_cycles"] - dbg_rows[0]["fpga_ts_cycles"]
    total_s = total_cycles / CLOCK_HZ
    total_iters = len(dbg_rows)
    total_epochs = total_iters / DATA_WORDS

    return {
        "avg_cycles_per_sample": avg_cycles,
        "avg_us_per_sample": avg_us,
        "throughput_samples_s": throughput,
        "total_cycles": total_cycles,
        "total_s": total_s,
        "total_iters": total_iters,
        "total_epochs": total_epochs,
    }

def analyze(ts):
    meta = load_meta(ts)
    print(f"\n{'='*60}")
    print(f"  Dataset: {meta}  |  Log: {ts}")
    print(f"{'='*60}")

    dataset = load_dataset(ts)
    nodes, last_sid = load_final_nodes(ts)
    edges = load_final_edges(ts, last_sid)
    dbg = load_dbg(ts)

    active_count = sum(1 for n in nodes.values() if n["active"])
    edge_count = len(edges)

    qe = compute_qe(dataset, nodes)
    te = compute_te(dataset, nodes, edges)

    print(f"\n  Topology (final snapshot idx={last_sid}):")
    print(f"    Active nodes : {active_count}")
    print(f"    Active edges : {edge_count}")
    print(f"    QE           : {qe:.6f}")
    print(f"    TE           : {te:.4f} ({int(te*len(dataset))}/{len(dataset)} samples)")

    rt = compute_runtime(dbg)
    if rt:
        print(f"\n  Runtime ({int(rt['total_epochs'])} epochs, {rt['total_iters']} iterations):")
        print(f"    Avg cycles/sample : {rt['avg_cycles_per_sample']:.0f}")
        print(f"    Avg µs/sample     : {rt['avg_us_per_sample']:.1f}")
        print(f"    Throughput        : {rt['throughput_samples_s']:.0f} samples/s")
        print(f"    Total FPGA time   : {rt['total_s']:.3f} s")

    print()
    return {"dataset": meta, "qe": qe, "te": te,
            "nodes": active_count, "edges": edge_count, "runtime": rt}

if __name__ == "__main__":
    timestamps = sys.argv[1:] if len(sys.argv) > 1 else [find_latest(LOGS_PATH)]
    results = []
    for ts in timestamps:
        results.append(analyze(ts))

    if len(results) > 1:
        print(f"\n{'='*60}")
        print(f"  Summary Table")
        print(f"{'='*60}")
        print(f"  {'Dataset':<22} {'QE':>8} {'TE':>8} {'Nodes':>6} {'Edges':>6} {'µs/samp':>8} {'samp/s':>8}")
        print(f"  {'-'*22} {'-'*8} {'-'*8} {'-'*6} {'-'*6} {'-'*8} {'-'*8}")
        for r in results:
            rt = r["runtime"]
            print(f"  {r['dataset']:<22} {r['qe']:>8.4f} {r['te']:>8.2f} {r['nodes']:>6} {r['edges']:>6} "
                  f"{rt['avg_us_per_sample']:>8.1f} {rt['throughput_samples_s']:>8.0f}")
