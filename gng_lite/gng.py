import numpy as np
import matplotlib.pyplot as plt

# ======================================================
# Two Moons Dataset (manual, no sklearn)
# ======================================================
def make_two_moons(n_samples=1000, noise=0.05, seed=0):
    np.random.seed(seed)
    n = n_samples // 2

    theta = np.linspace(0, np.pi, n)

    # Moon 1 (upper)
    x1 = np.cos(theta)
    y1 = np.sin(theta)

    # Moon 2 (lower + shift)
    x2 = 1 - np.cos(theta)
    y2 = -np.sin(theta) - 0.5

    X = np.vstack([
        np.stack([x1, y1], axis=1),
        np.stack([x2, y2], axis=1)
    ])

    X += noise * np.random.randn(*X.shape)
    return X


# ======================================================
# Growing Neural Gas (Fritzke-style)
# ======================================================
class GrowingNeuralGas:
    def __init__(
        self,
        max_nodes=50,
        max_age=30,
        eps_b=0.05,
        eps_n=0.005,
        alpha=0.5,
        beta=0.995,
        lam=100
    ):
        self.max_nodes = max_nodes
        self.max_age = max_age
        self.eps_b = eps_b
        self.eps_n = eps_n
        self.alpha = alpha
        self.beta = beta
        self.lam = lam

        self.W = []        # node positions
        self.error = []    # accumulated error
        self.edges = {}   # (i,j) -> age
        self.step = 0

    # --------------------------------------------------
    def initialize(self, x1, x2):
        self.W = [x1.copy(), x2.copy()]
        self.error = [0.0, 0.0]
        self.edges = {}

    # --------------------------------------------------
    def _dist(self, a, b):
        d = a - b
        return np.sqrt(d @ d)

    def _neighbors(self, i):
        return [j for (a, b) in self.edges
                for j in ([b] if a == i else [a] if b == i else [])]

    # --------------------------------------------------
    def _winner_runnerup(self, x):
        d = [self._dist(x, w) for w in self.W]
        s1 = np.argmin(d)
        d[s1] = np.inf
        s2 = np.argmin(d)
        return s1, s2

    # --------------------------------------------------
    def update(self, x):
        self.step += 1
        s1, s2 = self._winner_runnerup(x)

        # age edges
        for k in list(self.edges):
            if s1 in k:
                self.edges[k] += 1

        # accumulate error
        self.error[s1] += self._dist(x, self.W[s1]) ** 2

        # adapt winner
        self.W[s1] += self.eps_b * (x - self.W[s1])

        # adapt neighbors
        for n in self._neighbors(s1):
            self.W[n] += self.eps_n * (x - self.W[n])

        # connect s1 - s2
        key = tuple(sorted((s1, s2)))
        self.edges[key] = 0

        # remove old edges
        for k in list(self.edges):
            if self.edges[k] > self.max_age:
                del self.edges[k]

        # remove isolated nodes
        used = set(i for e in self.edges for i in e)
        for i in reversed(range(len(self.W))):
            if i not in used:
                self.W.pop(i)
                self.error.pop(i)
                self.edges = {
                    (a - (a > i), b - (b > i)): age
                    for (a, b), age in self.edges.items()
                    if a != i and b != i
                }

        # insert node
        if self.step % self.lam == 0 and len(self.W) < self.max_nodes:
            self._insert_node()

        # global error decay
        self.error = [e * self.beta for e in self.error]

    # --------------------------------------------------
    def _insert_node(self):
        q = np.argmax(self.error)
        nbs = self._neighbors(q)
        if not nbs:
            return

        f = nbs[np.argmax([self.error[n] for n in nbs])]
        r = len(self.W)

        self.W.append(0.5 * (self.W[q] + self.W[f]))
        self.error.append(0.0)

        self.edges.pop(tuple(sorted((q, f))), None)
        self.edges[(q, r)] = 0
        self.edges[(r, f)] = 0

        self.error[q] *= self.alpha
        self.error[f] *= self.alpha

    # --------------------------------------------------
    def train(self, X, epochs=1):
        for _ in range(epochs):
            for x in X:
                self.update(x)

    # --------------------------------------------------
    def plot(self, X):
        W = np.array(self.W)
        plt.figure(figsize=(6, 6))
        plt.scatter(X[:, 0], X[:, 1], s=8, alpha=0.3)
        plt.scatter(W[:, 0], W[:, 1], c="red", s=30)

        for (a, b), _ in self.edges.items():
            plt.plot([W[a, 0], W[b, 0]],
                     [W[a, 1], W[b, 1]], "k-", lw=1)

        plt.title(f"GNG | nodes = {len(self.W)}")
        plt.axis("equal")
        plt.show()


# ======================================================
# MAIN
# ======================================================
if __name__ == "__main__":
    X = make_two_moons(n_samples=1000, noise=0.06)

    gng = GrowingNeuralGas(
        max_nodes=40,
        max_age=25,
        eps_b=0.05,
        eps_n=0.006,
        lam=100
    )

    gng.initialize(X[0], X[1])
    gng.train(X, epochs=5)
    gng.plot(X)
