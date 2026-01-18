import numpy as np
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
from matplotlib.collections import LineCollection


# =========================================================
# Two-moons generator (mirip gaya Processing kamu)
# =========================================================
def generate_moons(
    N=100,
    random_angle=False,
    noise_std=0.06,
    seed=1234,
    shuffle=True,
    normalize01=True,
):
    rng = np.random.default_rng(seed)
    X = np.zeros((N, 2), dtype=np.float64)
    half = N // 2

    # moon 1
    if random_angle:
        t = rng.random(half) * np.pi
    else:
        t = np.linspace(0.0, np.pi, half)
    X[:half, 0] = np.cos(t)
    X[:half, 1] = np.sin(t)

    # moon 2
    m2 = N - half
    if random_angle:
        t2 = rng.random(m2) * np.pi
    else:
        t2 = np.linspace(0.0, np.pi, m2)
    X[half:, 0] = 1.0 - np.cos(t2)
    X[half:, 1] = -np.sin(t2) + 0.5

    # noise
    if noise_std > 0.0:
        X += rng.normal(0.0, noise_std, size=X.shape)

    # normalize 0..1 (per-axis)
    if normalize01:
        mn = X.min(axis=0)
        mx = X.max(axis=0)
        d = np.maximum(1e-9, mx - mn)
        X = (X - mn) / d

    # shuffle
    if shuffle:
        idx = np.arange(N)
        rng.shuffle(idx)
        X = X[idx]

    return X


# =========================================================
# GNG "biasa" (Fritzke), tapi winner pakai dist2 (L2^2)
# =========================================================
class GNG_Dist2Winner:
    def __init__(
        self,
        max_nodes=40,
        a_max=50,
        lamb=50,
        eps_b=0.05,
        eps_n=0.006,
        alpha=0.5,
        beta=0.0005,
        init_nodes=((0.2, 0.2), (0.8, 0.8)),
        seed=0,
    ):
        self.max_nodes = int(max_nodes)
        self.a_max = int(a_max)
        self.lamb = int(lamb)

        self.eps_b = float(eps_b)  # winner learning rate
        self.eps_n = float(eps_n)  # neighbor learning rate
        self.alpha = float(alpha)  # error reduction on insertion (q,f)
        self.beta = float(beta)    # global error decay

        rng = np.random.default_rng(seed)

        # nodes: list of np.array([x,y])
        self.nodes = [np.array(init_nodes[0], dtype=np.float64),
                      np.array(init_nodes[1], dtype=np.float64)]

        # errors
        self.err = [0.0, 0.0]

        # adjacency: list of dict {neighbor_id: age}
        self.adj = [dict(), dict()]

        self.step_count = 0
        self.rng = rng

    def _dist2(self, x: np.ndarray) -> np.ndarray:
        W = np.vstack(self.nodes)  # (M,2)
        d = W - x[None, :]
        return (d * d).sum(axis=1)

    def _euclid_sq(self, w: np.ndarray, x: np.ndarray) -> float:
        d = x - w
        return float(d[0] * d[0] + d[1] * d[1])

    def _neighbors(self, i: int):
        return list(self.adj[i].keys())

    def _remove_edge(self, i: int, j: int):
        if j in self.adj[i]:
            del self.adj[i][j]
        if i in self.adj[j]:
            del self.adj[j][i]

    def _add_or_reset_edge(self, i: int, j: int):
        self.adj[i][j] = 0
        self.adj[j][i] = 0

    def _remove_node(self, k: int):
        # remove all edges connected to k
        for nb in list(self.adj[k].keys()):
            self._remove_edge(k, nb)

        # pop node k
        self.nodes.pop(k)
        self.err.pop(k)
        self.adj.pop(k)

        # reindex adjacency (all indices > k shift down by 1)
        for i in range(len(self.adj)):
            newd = {}
            for nb, age in self.adj[i].items():
                nb2 = nb - 1 if nb > k else nb
                newd[nb2] = age
            self.adj[i] = newd

    def _age_edges_of(self, s1: int):
        # increase ages of edges from s1 and prune old ones
        for nb in list(self.adj[s1].keys()):
            self.adj[s1][nb] += 1
            self.adj[nb][s1] += 1
            if self.adj[s1][nb] > self.a_max:
                self._remove_edge(s1, nb)

    def _insert_node(self):
        # q = argmax error
        q = int(np.argmax(self.err))
        if len(self.adj[q]) == 0:
            return  # no neighbor -> cannot insert

        # f = neighbor of q with max error
        f = max(self.adj[q].keys(), key=lambda j: self.err[j])

        # new node r at midpoint
        r_pos = 0.5 * (self.nodes[q] + self.nodes[f])

        # add r
        r = len(self.nodes)
        self.nodes.append(r_pos.copy())
        self.err.append(self.err[q])
        self.adj.append(dict())

        # remove edge q-f
        self._remove_edge(q, f)

        # connect q-r and r-f
        self._add_or_reset_edge(q, r)
        self._add_or_reset_edge(r, f)

        # decrease errors of q and f
        self.err[q] *= self.alpha
        self.err[f] *= self.alpha

        # if exceed max_nodes, you can stop growing or prune lowest-error node
        if len(self.nodes) > self.max_nodes:
            # prune node with smallest error that is NOT q/f/r if possible
            idx = int(np.argmin(self.err))
            # avoid deleting the newest one immediately
            if idx == r and len(self.nodes) > 3:
                idx = int(np.argsort(self.err)[1])
            self._remove_node(idx)

    def step(self, x: np.ndarray):
        M = len(self.nodes)
        if M < 2:
            return

        # 1) find s1,s2 using dist2 (L2^2)
        d1 = self._dist2(x)
        s1 = int(np.argmin(d1))
        d1[s1] = np.inf
        s2 = int(np.argmin(d1))

        # 2) age edges from s1, prune
        self._age_edges_of(s1)

        # 3) connect s1-s2 (age reset)
        self._add_or_reset_edge(s1, s2)

        # 4) accumulate error at s1 (GNG biasa pakai L2^2)
        self.err[s1] += self._euclid_sq(self.nodes[s1], x)

        # (kalau kamu mau error juga ikut Manhattan: ganti jadi:)
        # self.err[s1] += float(np.abs(self.nodes[s1] - x).sum())

        # 5) move s1 toward x
        self.nodes[s1] += self.eps_b * (x - self.nodes[s1])

        # 6) move neighbors of s1 toward x
        for nb in self._neighbors(s1):
            self.nodes[nb] += self.eps_n * (x - self.nodes[nb])

        # 7) remove isolated nodes
        # (loop careful karena index bisa berubah saat remove)
        k = 0
        while k < len(self.nodes):
            if len(self.adj[k]) == 0:
                self._remove_node(k)
                # do not increment k (items shifted)
            else:
                k += 1

        # 8) insert every lambda steps
        self.step_count += 1
        if self.lamb > 0 and (self.step_count % self.lamb == 0) and (len(self.nodes) >= 2):
            self._insert_node()

        # 9) global error decay
        if self.beta > 0.0:
            for i in range(len(self.err)):
                self.err[i] *= (1.0 - self.beta)

    def get_segments(self):
        """Return line segments for edges (unique)."""
        segs = []
        for i in range(len(self.nodes)):
            for j, age in self.adj[i].items():
                if j > i:
                    segs.append([self.nodes[i], self.nodes[j]])
        return segs


# =========================================================
# Demo + matplotlib animation (no file output)
# =========================================================
def main():
    # dataset params (match Processing style)
    MOONS_N = 100
    MOONS_RANDOM_ANGLE = False
    MOONS_SEED = 1234
    MOONS_NOISE_STD = 0.06
    MOONS_SHUFFLE = True
    MOONS_NORMALIZE01 = True

    X = generate_moons(
        N=MOONS_N,
        random_angle=MOONS_RANDOM_ANGLE,
        noise_std=MOONS_NOISE_STD,
        seed=MOONS_SEED,
        shuffle=MOONS_SHUFFLE,
        normalize01=MOONS_NORMALIZE01,
    )

    # GNG params (feel free to tune)
    gng = GNG_Dist2Winner(
        max_nodes=40,
        a_max=50,
        lamb=50,
        eps_b=0.05,
        eps_n=0.006,
        alpha=0.5,
        beta=0.0005,
        init_nodes=((0.2, 0.2), (0.8, 0.8)),
        seed=0,
    )

    # fixed axis like viewer
    pad = 0.15
    xmin, ymin = X.min(axis=0) - pad
    xmax, ymax = X.max(axis=0) + pad

    fig, ax = plt.subplots()
    ax.set_title("GNG (standard) + dist2 winner (s1/s2 by L2^2)")
    ax.set_xlim(xmin, xmax)
    ax.set_ylim(ymin, ymax)
    ax.set_aspect("equal", adjustable="box")
    ax.grid(True, alpha=0.2)

    # plot dataset
    ax.scatter(X[:, 0], X[:, 1], s=20, alpha=0.6)

    # nodes scatter (updated)
    nodes_sc = ax.scatter([], [], s=80)

    # edges as LineCollection
    lc = LineCollection([], linewidths=1.0, alpha=0.8)
    ax.add_collection(lc)

    txt = ax.text(0.01, 0.99, "", transform=ax.transAxes, va="top")

    # animation settings
    steps_per_frame = 10
    total_frames = 400

    idx = 0  # sample pointer

    def init():
        nodes_sc.set_offsets(np.empty((0, 2)))
        lc.set_segments([])
        txt.set_text("")
        return nodes_sc, lc, txt

    def update(frame):
        nonlocal idx
        for _ in range(steps_per_frame):
            gng.step(X[idx])
            idx = (idx + 1) % len(X)

        W = np.vstack(gng.nodes) if len(gng.nodes) > 0 else np.empty((0, 2))
        nodes_sc.set_offsets(W)

        segs = gng.get_segments()
        lc.set_segments(segs)

        txt.set_text(
            f"step={gng.step_count}  nodes={len(gng.nodes)}  edges={len(segs)}"
        )
        return nodes_sc, lc, txt

    ani = FuncAnimation(
        fig,
        update,
        frames=total_frames,
        init_func=init,
        interval=30,
        blit=True,
    )

    plt.show()


if __name__ == "__main__":
    main()
