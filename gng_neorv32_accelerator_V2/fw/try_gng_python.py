import numpy as np
from dataclasses import dataclass
from typing import Dict, List, Tuple, Optional


@dataclass
class GNGParams:
    max_nodes: int = 150
    max_age: int = 50
    lam: int = 120
    eps_b: float = 0.05
    eps_n: float = 0.006
    alpha: float = 0.5
    d: float = 0.995
    n_steps: int = 25000
    seed: Optional[int] = 0


class GrowingNeuralGas:
    def __init__(self, params: GNGParams = GNGParams()):
        self.p = params
        self.rng = np.random.default_rng(self.p.seed)

        self.W: np.ndarray = np.empty((0, 0), dtype=float)
        self.err: np.ndarray = np.empty((0,), dtype=float)
        self.edges: Dict[int, Dict[int, int]] = {}
        self.dim: int = 0
        self._fitted: bool = False

    def _add_node(self, w: np.ndarray, err: float = 0.0) -> int:
        if self.W.size == 0:
            self.W = w.reshape(1, -1).astype(float)
            self.err = np.array([err], dtype=float)
        else:
            self.W = np.vstack([self.W, w.reshape(1, -1)])
            self.err = np.append(self.err, err)
        idx = self.W.shape[0] - 1
        self.edges[idx] = {}
        return idx

    def _add_edge(self, u: int, v: int, age: int = 0) -> None:
        if u == v:
            return
        self.edges[u][v] = age
        self.edges[v][u] = age

    def _remove_edge(self, u: int, v: int) -> None:
        if v in self.edges.get(u, {}):
            del self.edges[u][v]
        if u in self.edges.get(v, {}):
            del self.edges[v][u]

    def _increment_neighbor_edge_ages(self, u: int) -> None:
        for v in list(self.edges[u].keys()):
            self.edges[u][v] += 1
            self.edges[v][u] = self.edges[u][v]

    def _prune_old_edges(self) -> None:
        to_remove = []
        for u, nbrs in self.edges.items():
            for v, age in nbrs.items():
                if age > self.p.max_age:
                    to_remove.append((u, v))
        for u, v in to_remove:
            self._remove_edge(u, v)

    def _remove_isolated_nodes(self) -> None:
        isolated = [i for i in range(self.W.shape[0]) if len(self.edges[i]) == 0]
        if not isolated:
            return

        keep = [i for i in range(self.W.shape[0]) if i not in set(isolated)]
        if len(keep) == 0:
            self.W = np.empty((0, self.dim))
            self.err = np.empty((0,))
            self.edges = {}
            return

        new_index = {old: new for new, old in enumerate(keep)}
        newW = self.W[keep]
        newErr = self.err[keep]
        newEdges: Dict[int, Dict[int, int]] = {new_index[old]: {} for old in keep}

        for u_old in keep:
            for v_old, age in self.edges[u_old].items():
                if v_old in new_index:
                    u = new_index[u_old]
                    v = new_index[v_old]
                    if u != v:
                        newEdges[u][v] = age

        for u in list(newEdges.keys()):
            for v, age in list(newEdges[u].items()):
                newEdges[v][u] = age

        self.W, self.err, self.edges = newW, newErr, newEdges

    def _two_nearest(self, x: np.ndarray) -> Tuple[int, int, float]:
        dif = self.W - x.reshape(1, -1)
        dist2 = np.einsum("ij,ij->i", dif, dif)
        s1 = int(np.argmin(dist2))
        d1 = float(dist2[s1])
        dist2[s1] = np.inf
        s2 = int(np.argmin(dist2))
        return s1, s2, d1

    def fit(self, X: np.ndarray) -> "GrowingNeuralGas":
        X = np.asarray(X, dtype=float)
        if X.ndim != 2 or X.shape[0] < 2:
            raise ValueError("X harus shape (N, D) dan N>=2")

        self.dim = X.shape[1]
        self.W = np.empty((0, self.dim))
        self.err = np.empty((0,))
        self.edges = {}

        i, j = self.rng.choice(X.shape[0], size=2, replace=False)
        n0 = self._add_node(X[i], err=0.0)
        n1 = self._add_node(X[j], err=0.0)
        self._add_edge(n0, n1, age=0)

        for t in range(1, self.p.n_steps + 1):
            x = X[self.rng.integers(0, X.shape[0])]

            s1, s2, d1 = self._two_nearest(x)

            self._increment_neighbor_edge_ages(s1)
            self.err[s1] += d1

            self.W[s1] += self.p.eps_b * (x - self.W[s1])
            for nb in self.edges[s1].keys():
                self.W[nb] += self.p.eps_n * (x - self.W[nb])

            self._add_edge(s1, s2, age=0)

            self._prune_old_edges()
            self._remove_isolated_nodes()

            if self.W.shape[0] < 2:
                i, j = self.rng.choice(X.shape[0], size=2, replace=False)
                self.W = np.empty((0, self.dim))
                self.err = np.empty((0,))
                self.edges = {}
                n0 = self._add_node(X[i], err=0.0)
                n1 = self._add_node(X[j], err=0.0)
                self._add_edge(n0, n1, age=0)
                continue

            if (t % self.p.lam == 0) and (self.W.shape[0] < self.p.max_nodes):
                q = int(np.argmax(self.err))
                if len(self.edges[q]) > 0:
                    f = max(self.edges[q].keys(), key=lambda k: self.err[k])
                    r_w = 0.5 * (self.W[q] + self.W[f])
                    r = self._add_node(r_w, err=self.err[q])

                    self._remove_edge(q, f)
                    self._add_edge(q, r, age=0)
                    self._add_edge(r, f, age=0)

                    self.err[q] *= self.p.alpha
                    self.err[f] *= self.p.alpha
                    self.err[r] = self.err[q]

            self.err *= self.p.d

        self._fitted = True
        return self

    def predict(self, X: np.ndarray) -> np.ndarray:
        if not self._fitted or self.W.size == 0:
            raise RuntimeError("Model belum di-fit.")
        X = np.asarray(X, dtype=float)
        dif = X[:, None, :] - self.W[None, :, :]
        dist2 = np.einsum("nkd,nkd->nk", dif, dif)
        return np.argmin(dist2, axis=1)

    def get_graph(self) -> Tuple[np.ndarray, List[Tuple[int, int, int]]]:
        out = []
        for u, nbrs in self.edges.items():
            for v, age in nbrs.items():
                if u < v:
                    out.append((u, v, age))
        return self.W.copy(), out


# ----------- 3D synthetic dataset -----------
def make_3d_two_shells(n=4000, noise=0.03, seed=0):
    """
    Dua "shell" (bola) 3D: radius kecil dan radius besar.
    Bagus untuk lihat GNG bikin graph mengikuti manifold 3D.
    """
    rng = np.random.default_rng(seed)

    def sample_sphere(m, radius):
        v = rng.normal(size=(m, 3))
        v /= (np.linalg.norm(v, axis=1, keepdims=True) + 1e-12)
        r = radius + rng.normal(scale=noise, size=(m, 1))
        return v * r

    n1 = n // 2
    n2 = n - n1
    X1 = sample_sphere(n1, radius=1.0)
    X2 = sample_sphere(n2, radius=2.0) + np.array([2.5, 0.0, 0.0])  # geser biar terlihat 2 cluster
    X = np.vstack([X1, X2])
    return X


# ----------- Demo + 3D plot -----------
if __name__ == "__main__":
    import matplotlib.pyplot as plt
    from mpl_toolkits.mplot3d import Axes3D  # noqa: F401

    X = make_3d_two_shells(n=4000, noise=0.05, seed=1)

    # normalisasi (opsional, tapi biasanya membantu)
    Xn = (X - X.mean(axis=0)) / (X.std(axis=0) + 1e-12)

    gng = GrowingNeuralGas(GNGParams(
        max_nodes=180,
        max_age=60,
        lam=120,
        eps_b=0.08,
        eps_n=0.015,
        alpha=0.5,
        d=0.995,
        n_steps=25000,
        seed=1
    ))
    gng.fit(Xn)

    W, E = gng.get_graph()

    fig = plt.figure()
    ax = fig.add_subplot(111, projection="3d")

    ax.scatter(Xn[:, 0], Xn[:, 1], Xn[:, 2], s=3, alpha=0.15)

    # edges
    for u, v, age in E:
        p1, p2 = W[u], W[v]
        ax.plot([p1[0], p2[0]], [p1[1], p2[1]], [p1[2], p2[2]], linewidth=1)

    # nodes
    ax.scatter(W[:, 0], W[:, 1], W[:, 2], s=25)

    ax.set_title(f"GNG 3D: nodes={W.shape[0]}, edges={len(E)}")
    plt.show()
