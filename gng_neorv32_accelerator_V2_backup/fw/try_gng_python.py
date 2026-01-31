# dbl_gng_moons_live.py
# DBL-GNG (original-style batch) + live matplotlib visualization
# Dependencies: numpy, matplotlib

from __future__ import annotations
from dataclasses import dataclass
import math
import random
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
from matplotlib.collections import LineCollection


# ======================================================
# Java/Processing RNG to match your moons settings
# ======================================================
class JavaRandom:
    def __init__(self, seed: int):
        self.multiplier = 0x5DEECE66D
        self.addend = 0xB
        self.mask = (1 << 48) - 1
        self.seed = (seed ^ self.multiplier) & self.mask
        self._have_next = False
        self._next_gauss = 0.0

    def next(self, bits: int) -> int:
        self.seed = (self.seed * self.multiplier + self.addend) & self.mask
        return self.seed >> (48 - bits)

    def nextFloat(self) -> float:
        return self.next(24) / float(1 << 24)

    def nextInt(self, bound: int) -> int:
        if bound <= 0:
            raise ValueError("bound must be positive")
        if (bound & (bound - 1)) == 0:
            return (bound * self.next(31)) >> 31
        while True:
            bits = self.next(31)
            val = bits % bound
            if bits - val + (bound - 1) >= 0:
                return val

    def nextGaussian(self) -> float:
        if self._have_next:
            self._have_next = False
            return self._next_gauss
        while True:
            u1 = 2.0 * self.nextFloat() - 1.0
            u2 = 2.0 * self.nextFloat() - 1.0
            s = u1 * u1 + u2 * u2
            if s >= 1.0 or s == 0.0:
                continue
            m = math.sqrt(-2.0 * math.log(s) / s)
            self._next_gauss = u2 * m
            self._have_next = True
            return u1 * m


def generate_moons_processing_exact(
    N: int,
    random_angle: bool,
    noise_std: float,
    seed: int,
    shuffle: bool,
    normalize01: bool,
) -> np.ndarray:
    if N % 2 == 1:
        N -= 1
    rng = JavaRandom(seed)
    arr = np.zeros((N, 2), dtype=np.float32)
    half = N // 2

    for i in range(half):
        t = rng.nextFloat() * math.pi if random_angle else (i / max(1, half - 1)) * math.pi
        arr[i, 0] = math.cos(t)
        arr[i, 1] = math.sin(t)

    for i in range(half, N):
        j = i - half
        t = rng.nextFloat() * math.pi if random_angle else (j / max(1, half - 1)) * math.pi
        arr[i, 0] = 1.0 - math.cos(t)
        arr[i, 1] = -math.sin(t) + 0.5

    if noise_std > 0.0:
        for i in range(N):
            arr[i, 0] += rng.nextGaussian() * noise_std
            arr[i, 1] += rng.nextGaussian() * noise_std

    if normalize01:
        minx, maxx = float(arr[:, 0].min()), float(arr[:, 0].max())
        miny, maxy = float(arr[:, 1].min()), float(arr[:, 1].max())
        dx = max(1e-9, maxx - minx)
        dy = max(1e-9, maxy - miny)
        arr[:, 0] = (arr[:, 0] - minx) / dx
        arr[:, 1] = (arr[:, 1] - miny) / dy

    if shuffle:
        for i in range(N - 1, 0, -1):
            j = rng.nextInt(i + 1)
            tmp = arr[i].copy()
            arr[i] = arr[j]
            arr[j] = tmp

    return arr


# ======================================================
# DBL-GNG (original-style) implementation
# ======================================================
@dataclass
class DBLGNGParams:
    feature_number: int = 2
    max_nodes: int = 68
    L1: float = 0.5          # alpha in original
    L2: float = 0.01         # beta in original
    errorNodeFactor: float = 0.5   # delta
    newNodeFactor: float = 0.5     # rho
    eps: float = 1e-4
    add_quantile: float = 0.85     # quantile for deciding how many nodes to add
    add_prob: float = 1.0          # 1.0 = always try addNewNode each epoch (original code does every epoch)
    cut_quantile: float = 0.15     # for cutEdge()


class DBL_GNG:
    def __init__(self, params: DBLGNGParams, seed: int = 0):
        self.p = params
        self.rng = np.random.default_rng(seed)

        self.W = np.empty((0, self.p.feature_number), dtype=np.float32)  # nodes
        self.C = np.empty((0, 2), dtype=np.int32)                        # edges (pairs)
        self.E = np.zeros((0,), dtype=np.float32)                        # error

        # batch accumulators
        self.Delta_W_1 = None
        self.Delta_W_2 = None
        self.A_1 = None
        self.A_2 = None
        self.S = None  # edge score matrix

    def resetBatch(self):
        self.Delta_W_1 = np.zeros_like(self.W)
        self.Delta_W_2 = np.zeros_like(self.W)
        self.A_1 = np.zeros(len(self.W), dtype=np.float32)
        self.A_2 = np.zeros(len(self.W), dtype=np.float32)
        self.S = np.zeros((len(self.W), len(self.W)), dtype=np.float32)

    def initializeDistributedNode(self, data: np.ndarray, number_of_starting_points: int = 10):
        data = np.asarray(data, dtype=np.float32)[:, : self.p.feature_number].copy()
        self.rng.shuffle(data)

        nodeList = np.empty((0, self.p.feature_number), dtype=np.float32)
        edgeList = np.empty((0, 2), dtype=np.int32)

        tempData = data.copy()
        if len(tempData) < 3:
            raise ValueError("Need at least 3 points for this init (it picks idx[2])")

        batchSize = max(1, len(data) // max(1, number_of_starting_points))

        for i in range(number_of_starting_points):
            if len(tempData) < 3:
                break

            idx = np.arange(len(tempData), dtype=np.int32)
            # pick from far end of current tempData (like original)
            start = max(0, len(idx) - batchSize)
            selectedIndex = int(self.rng.choice(idx[start:]))

            currentNode = tempData[selectedIndex]
            nodeList = np.append(nodeList, [currentNode], axis=0)

            # dist^2 from node to all tempData (vectorized)
            y2 = np.sum(np.square(tempData), axis=1)
            dot_product = 2.0 * np.matmul(currentNode, tempData.T)
            dist2 = y2 - dot_product  # + const omitted, good enough for ranking

            order = np.argsort(dist2)
            # pick 3rd closest (idx[2])
            neighborNode = tempData[order[2]]
            nodeList = np.append(nodeList, [neighborNode], axis=0)

            edgeList = np.append(edgeList, [[i * 2, i * 2 + 1]], axis=0)

            # crop: remove closest batchSize region (like original)
            order = order[batchSize:]
            tempData = tempData[order]

        self.W = nodeList
        self.C = edgeList
        self.E = np.zeros(len(self.W), dtype=np.float32)

    def batchLearning(self, X: np.ndarray):
        X = np.asarray(X, dtype=np.float32)[:, : self.p.feature_number]
        K = len(self.W)
        if K < 2:
            return

        # identity + adjacency (from edges C)
        i_adj = np.eye(K, dtype=np.float32)

        adj = np.zeros((K, K), dtype=np.float32)
        if len(self.C) > 0:
            adj[self.C[:, 0], self.C[:, 1]] = 1.0
            adj[self.C[:, 1], self.C[:, 0]] = 1.0

        batchIndices = np.arange(len(X), dtype=np.int32)

        # distances (original uses sqrt(dist2 + eps))
        x2 = np.sum(np.square(X), axis=1)
        y2 = np.sum(np.square(self.W), axis=1)
        dot = 2.0 * np.matmul(X, self.W.T)
        dist2 = np.expand_dims(x2, 1) + y2 - dot
        dist2 = np.clip(dist2, 0.0, None)
        dist = np.sqrt(dist2 + self.p.eps).astype(np.float32)

        # winners
        temp = dist.copy()
        s1 = np.argmin(temp, axis=1).astype(np.int32)
        temp[batchIndices, s1] = 99999.0
        s2 = np.argmin(temp, axis=1).astype(np.int32)

        # error accumulate (original): E += sum( i_adj[s1] * dist ) * alpha
        self.E += (np.sum(i_adj[s1] * dist, axis=0) * self.p.L1).astype(np.float32)

        # ΔW1 (winner)
        # (I[s1]^T X) - (W^T * sum(I[s1]))^T
        self.Delta_W_1 += (
            (np.matmul(i_adj[s1].T, X) - (self.W.T * np.sum(i_adj[s1], axis=0)).T) * self.p.L1
        ).astype(np.float32)

        # ΔW2 (neighbors)
        self.Delta_W_2 += (
            (np.matmul(adj[s1].T, X) - (self.W.T * adj[s1].sum(0)).T) * self.p.L2
        ).astype(np.float32)

        # activation counts
        self.A_1 += np.sum(i_adj[s1], axis=0).astype(np.float32)
        self.A_2 += np.sum(adj[s1], axis=0).astype(np.float32)

        # edge importance counts (S)
        connectedEdge = np.zeros_like(self.S, dtype=np.float32)
        connectedEdge[s1, s2] = 1.0
        connectedEdge[s2, s1] = 1.0

        t = i_adj[s1] + i_adj[s2]
        connectedEdge *= np.matmul(t.T, t)

        self.S += connectedEdge

    def updateNetwork(self):
        # apply batch deltas (avoid divide by zero)
        self.W = self.W + (
            (self.Delta_W_1.T * (1.0 / (self.A_1 + self.p.eps))).T
            + (self.Delta_W_2.T * (1.0 / (self.A_2 + self.p.eps))).T
        ).astype(np.float32)

        # edges from S (nonzero)
        self.C = np.asarray(self.S.nonzero()).T.astype(np.int32)

        self.removeIsolatedNodes()

        self.E *= self.p.errorNodeFactor

        # original randomly removes non-activated
        if random.random() > 0.9:
            self.removeNonActivatedNodes()

    def removeIsolatedNodes(self):
        K = len(self.W)
        if K == 0:
            return

        adj = np.zeros((K, K), dtype=np.int32)
        if len(self.C) > 0:
            adj[self.C[:, 0], self.C[:, 1]] = 1
            adj[self.C[:, 1], self.C[:, 0]] = 1

        isolated = np.where((np.sum(adj, axis=0) + np.sum(adj, axis=1)) == 0)[0]
        finalDelete = list(np.unique(isolated))
        finalDelete.sort(reverse=True)

        for v in finalDelete:
            # drop edges touching v
            if len(self.C) > 0:
                self.C = self.C[~((self.C[:, 0] == v) | (self.C[:, 1] == v))]
                self.C[self.C[:, 0] > v, 0] -= 1
                self.C[self.C[:, 1] > v, 1] -= 1

        if len(finalDelete) > 0:
            self.S = np.delete(self.S, finalDelete, axis=0)
            self.S = np.delete(self.S, finalDelete, axis=1)
            self.W = np.delete(self.W, finalDelete, axis=0)
            self.E = np.delete(self.E, finalDelete, axis=0)
            self.A_1 = np.delete(self.A_1, finalDelete, axis=0)
            self.A_2 = np.delete(self.A_2, finalDelete, axis=0)

    def removeNonActivatedNodes(self):
        nonActivated = np.where(self.A_1 == 0)[0]
        finalDelete = list(nonActivated)
        finalDelete.sort(reverse=True)

        for v in finalDelete:
            if len(self.C) > 0:
                self.C = self.C[~((self.C[:, 0] == v) | (self.C[:, 1] == v))]
                self.C[self.C[:, 0] > v, 0] -= 1
                self.C[self.C[:, 1] > v, 1] -= 1

        if len(finalDelete) > 0:
            self.S = np.delete(self.S, finalDelete, axis=0)
            self.S = np.delete(self.S, finalDelete, axis=1)
            self.W = np.delete(self.W, finalDelete, axis=0)
            self.E = np.delete(self.E, finalDelete, axis=0)
            self.A_1 = np.delete(self.A_1, finalDelete, axis=0)
            self.A_2 = np.delete(self.A_2, finalDelete, axis=0)

    def addNewNode(self):
        # FIX: use self.E not global gng.E
        if len(self.W) >= self.p.max_nodes:
            return

        if len(self.E) == 0:
            return

        thr = np.quantile(self.E, self.p.add_quantile)
        g = int(np.sum(self.E > thr))

        for _ in range(g):
            if len(self.W) >= self.p.max_nodes:
                return

            q1 = int(np.argmax(self.E))
            if self.E[q1] <= 0:
                return

            # neighbors from C
            if len(self.C) == 0:
                return

            connected = np.unique(np.concatenate((self.C[self.C[:, 0] == q1, 1],
                                                 self.C[self.C[:, 1] == q1, 0])))
            if len(connected) == 0:
                return

            q2 = int(connected[np.argmax(self.E[connected])])
            if self.E[q2] <= 0:
                return

            q3 = len(self.W)
            new_w = (self.W[q1] + self.W[q2]) * 0.5
            self.W = np.vstack((self.W, new_w)).astype(np.float32)
            self.E = np.concatenate((self.E, np.zeros(1, dtype=np.float32)), axis=0)

            # error update (same style as original)
            self.E[q1] *= self.p.newNodeFactor
            self.E[q2] *= self.p.newNodeFactor
            self.E[q3] = (self.E[q1] + self.E[q2]) * 0.5

            # remove original edge both directions if present
            if len(self.C) > 0:
                self.C = self.C[~((self.C[:, 0] == q1) & (self.C[:, 1] == q2))]
                self.C = self.C[~((self.C[:, 0] == q2) & (self.C[:, 1] == q1))]

            # add edges
            self.C = np.vstack((self.C, np.asarray([q1, q3], dtype=np.int32)))
            self.C = np.vstack((self.C, np.asarray([q2, q3], dtype=np.int32)))

            # expand S
            self.S = np.pad(self.S, pad_width=((0, 1), (0, 1)), mode="constant")

            # set edge scores like original
            self.S[q1, q2] = 0
            self.S[q2, q1] = 0
            self.S[q1, q3] = 1
            self.S[q3, q1] = 1
            self.S[q2, q3] = 1
            self.S[q3, q2] = 1

            # expand A
            self.A_1 = np.concatenate((self.A_1, np.ones(1, dtype=np.float32)), axis=0)
            self.A_2 = np.concatenate((self.A_2, np.ones(1, dtype=np.float32)), axis=0)

    def cutEdge(self):
        self.removeNonActivatedNodes()
        mask = self.S > 0
        if not np.any(mask):
            return
        filterV = np.quantile(self.S[mask], self.p.cut_quantile)
        temp = self.S.copy()
        temp[self.S < filterV] = 0
        self.C = np.asarray(temp.nonzero()).T.astype(np.int32)
        self.removeIsolatedNodes()


# ======================================================
# Live matplotlib visualization (Processing-like dark)
# ======================================================
def style_black(ax: plt.Axes):
    ax.figure.patch.set_facecolor("black")
    ax.set_facecolor("black")
    ax.set_aspect("equal", adjustable="box")
    ax.set_xticks([])
    ax.set_yticks([])
    for sp in ax.spines.values():
        sp.set_visible(False)


def run_live():
    # ----- YOUR Processing dataset settings -----
    X = generate_moons_processing_exact(
        N=1000,
        random_angle=False,
        noise_std=0.06,
        seed=1234,
        shuffle=True,
        normalize01=True,
    ).astype(np.float32)

    # ----- DBL-GNG params (match original style) -----
    params = DBLGNGParams(
        feature_number=2,
        max_nodes=68,      # original example
        L1=0.5,
        L2=0.01,
        errorNodeFactor=0.5,
        newNodeFactor=0.5,
        eps=1e-4,
        add_quantile=0.85,
        add_prob=1.0,      # always add
        cut_quantile=0.15,
    )

    gng = DBL_GNG(params, seed=42)
    gng.initializeDistributedNode(X, number_of_starting_points=10)

    fig, ax = plt.subplots(figsize=(6.5, 6.3))
    style_black(ax)

    # dataset points
    ax.scatter(X[:, 0], X[:, 1], s=18, c="white", alpha=1.0, linewidths=0)

    # edges + nodes
    node_scatter = ax.scatter(gng.W[:, 0], gng.W[:, 1], s=70, c="#ff8800", linewidths=0)
    edge_lines = LineCollection([], linewidths=1.5, colors="#ffaa55", alpha=0.9)
    ax.add_collection(edge_lines)

    pad = 0.10
    xmin, ymin = X.min(axis=0) - pad
    xmax, ymax = X.max(axis=0) + pad
    ax.set_xlim(float(xmin), float(xmax))
    ax.set_ylim(float(ymin), float(ymax))

    epoch = {"k": 0}
    interval_ms = 200

    def update_edges():
        if len(gng.C) == 0:
            edge_lines.set_segments([])
            return 0
        W = gng.W
        # C can include both (i,j) and (j,i); keep only i<j
        segs = []
        cnt = 0
        for i, j in gng.C:
            if i < j and i != j:
                segs.append([W[i], W[j]])
                cnt += 1
        edge_lines.set_segments(segs)
        return cnt

    def update(_frame):
        # one epoch = resetBatch + batchLearning + updateNetwork + addNewNode
        gng.resetBatch()
        gng.batchLearning(X)
        gng.updateNetwork()
        if random.random() <= params.add_prob:
            gng.addNewNode()

        # optional: cut edges occasionally (uncomment if you want)
        # if epoch["k"] % 10 == 0 and epoch["k"] > 0:
        #     gng.cutEdge()

        epoch["k"] += 1

        node_scatter.set_offsets(gng.W[:, :2])
        m = update_edges()

        ax.set_title(
            f"DBL-GNG (original-style)  epoch={epoch['k']}  nodes={len(gng.W)}  edges={m}",
            color="white",
            fontsize=11,
            pad=10,
        )
        return node_scatter, edge_lines

    anim = FuncAnimation(fig, update, interval=interval_ms, blit=False)
    return anim


if __name__ == "__main__":
    anim = run_live()  # keep ref
    plt.show()
