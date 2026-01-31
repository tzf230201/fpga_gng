# gng_visual_tk.py
# Pure-Python (no numpy) Two-Moons + GNG (Fritzke 1995) with Tkinter visualization

import math
import random
import time
import tkinter as tk
from dataclasses import dataclass

# ===============================
# GNG parameters (match your firmware)
# ===============================
GNG_LAMBDA    = 100
GNG_EPSILON_B = 0.3
GNG_EPSILON_N = 0.001
GNG_ALPHA     = 0.5
GNG_A_MAX     = 50
GNG_D         = 0.995

MAX_NODES = 40
MAX_EDGES = 80

# ===============================
# Two-moons dataset options (match Processing)
# ===============================
MOONS_N            = 100
MOONS_RANDOM_ANGLE = False
MOONS_SEED         = 1234
MOONS_NOISE_STD    = 0.06
MOONS_SHUFFLE      = True
MOONS_NORMALIZE01  = True

# ===============================
# Visualization settings
# ===============================
WIN_W, WIN_H = 1000, 600
PANEL_W = 500
MARGIN = 50
SCALE = 400  # same style as your Processing

BG_COLOR = "#1e1e1e"
DATA_COLOR = "#ffffff"
EDGE_COLOR = "#ffffff"
NODE_COLOR = "#00b4ff"

# Update policy:
STEPS_PER_TICK = 200   # how many training steps per GUI tick
DRAW_EVERY_N   = 5     # redraw every N training steps (like STREAM_EVERY_N)


# ===============================
# Data structures
# ===============================
@dataclass
class Node:
    x: float = 0.0
    y: float = 0.0
    error: float = 0.0
    active: bool = False

@dataclass
class Edge:
    a: int = 0
    b: int = 0
    age: int = 0
    active: bool = False


# ===============================
# Dataset: Two Moons
# ===============================
def generate_moons(N=100, random_angle=False, noise_std=0.06, seed=1234,
                   shuffle=True, normalize01=True):
    rnd = random.Random(seed)
    arr = [[0.0, 0.0] for _ in range(N)]
    half = N // 2

    for i in range(half):
        if random_angle:
            t = rnd.random() * math.pi
        else:
            t = (i / max(1, half - 1)) * math.pi
        arr[i][0] = math.cos(t)
        arr[i][1] = math.sin(t)

    for i in range(half, N):
        j = i - half
        if random_angle:
            t = rnd.random() * math.pi
        else:
            t = (j / max(1, half - 1)) * math.pi
        arr[i][0] = 1.0 - math.cos(t)
        arr[i][1] = -math.sin(t) + 0.5

    if noise_std > 0.0:
        for i in range(N):
            arr[i][0] += rnd.gauss(0.0, noise_std)
            arr[i][1] += rnd.gauss(0.0, noise_std)

    if normalize01:
        minx = min(p[0] for p in arr); maxx = max(p[0] for p in arr)
        miny = min(p[1] for p in arr); maxy = max(p[1] for p in arr)
        dx = max(maxx - minx, 1e-9)
        dy = max(maxy - miny, 1e-9)
        for i in range(N):
            arr[i][0] = (arr[i][0] - minx) / dx
            arr[i][1] = (arr[i][1] - miny) / dy

    if shuffle:
        rnd.shuffle(arr)

    return arr


# ===============================
# GNG core (Fritzke 1995)
# ===============================
def dist2(x1, y1, x2, y2):
    dx = x1 - x2
    dy = y1 - y2
    return dx*dx + dy*dy

def find_free_node(nodes):
    for i, n in enumerate(nodes):
        if not n.active:
            return i
    return -1

def find_winners(nodes, x, y):
    s1, s2 = -1, -1
    d1, d2 = float("inf"), float("inf")
    for i, n in enumerate(nodes):
        if not n.active:
            continue
        d = dist2(x, y, n.x, n.y)
        if d < d1:
            d2, s2 = d1, s1
            d1, s1 = d, i
        elif d < d2:
            d2, s2 = d, i
    return s1, s2, d1

def find_edge(edges, a, b):
    aa, bb = (a, b) if a <= b else (b, a)
    for i, e in enumerate(edges):
        if not e.active:
            continue
        ea, eb = (e.a, e.b) if e.a <= e.b else (e.b, e.a)
        if ea == aa and eb == bb:
            return i
    return -1

def connect_or_reset_edge(edges, a, b):
    ei = find_edge(edges, a, b)
    if ei >= 0:
        edges[ei].a = a
        edges[ei].b = b
        edges[ei].age = 0
        edges[ei].active = True
        return

    for e in edges:
        if not e.active:
            e.a = a
            e.b = b
            e.age = 0
            e.active = True
            return
    # if full, drop silently (matches "limited edges" behavior)

def remove_edge_pair(edges, a, b):
    ei = find_edge(edges, a, b)
    if ei >= 0:
        edges[ei].active = False

def age_edges_from_winner(edges, w):
    for e in edges:
        if e.active and (e.a == w or e.b == w):
            e.age += 1

def delete_old_edges(edges):
    for e in edges:
        if e.active and e.age > GNG_A_MAX:
            e.active = False

def prune_isolated_nodes(nodes, edges):
    for i, n in enumerate(nodes):
        if not n.active:
            continue
        has_edge = False
        for e in edges:
            if not e.active:
                continue
            if e.a == i or e.b == i:
                has_edge = True
                break
        if not has_edge:
            n.active = False

def insert_node(nodes, edges):
    q = -1
    max_err = -1.0
    for i, n in enumerate(nodes):
        if n.active and n.error > max_err:
            max_err = n.error
            q = i
    if q < 0:
        return -1

    f = -1
    max_err = -1.0
    for e in edges:
        if not e.active:
            continue
        nb = -1
        if e.a == q:
            nb = e.b
        elif e.b == q:
            nb = e.a
        if nb >= 0 and nodes[nb].active and nodes[nb].error > max_err:
            max_err = nodes[nb].error
            f = nb
    if f < 0:
        return -1

    r = find_free_node(nodes)
    if r < 0:
        return -1

    nodes[r].x = 0.5 * (nodes[q].x + nodes[f].x)
    nodes[r].y = 0.5 * (nodes[q].y + nodes[f].y)
    nodes[r].active = True

    remove_edge_pair(edges, q, f)
    connect_or_reset_edge(edges, q, r)
    connect_or_reset_edge(edges, r, f)

    # Fritzke 1995 order
    nodes[q].error *= GNG_ALPHA
    nodes[f].error *= GNG_ALPHA
    nodes[r].error = nodes[q].error

    return r

def train_one_step(nodes, edges, x, y):
    s1, s2, d1 = find_winners(nodes, x, y)
    if s1 < 0 or s2 < 0:
        return False

    age_edges_from_winner(edges, s1)
    nodes[s1].error += d1

    # move winner
    nodes[s1].x += GNG_EPSILON_B * (x - nodes[s1].x)
    nodes[s1].y += GNG_EPSILON_B * (y - nodes[s1].y)

    # move neighbors by scanning edges
    for e in edges:
        if not e.active:
            continue
        if e.a == s1 or e.b == s1:
            nb = e.b if e.a == s1 else e.a
            if 0 <= nb < len(nodes) and nodes[nb].active:
                nodes[nb].x += GNG_EPSILON_N * (x - nodes[nb].x)
                nodes[nb].y += GNG_EPSILON_N * (y - nodes[nb].y)

    connect_or_reset_edge(edges, s1, s2)

    delete_old_edges(edges)
    prune_isolated_nodes(nodes, edges)

    # decay errors
    for n in nodes:
        if n.active:
            n.error *= GNG_D

    return True


def init_gng():
    nodes = [Node() for _ in range(MAX_NODES)]
    edges = [Edge() for _ in range(MAX_EDGES)]

    # same init as your firmware
    nodes[0].x, nodes[0].y, nodes[0].active = 0.2, 0.2, True
    nodes[1].x, nodes[1].y, nodes[1].active = 0.8, 0.8, True

    return nodes, edges


def count_active_nodes(nodes):
    return sum(1 for n in nodes if n.active)

def count_active_edges(edges):
    return sum(1 for e in edges if e.active)


# ===============================
# Tkinter Visualization
# ===============================
class GNGApp:
    def __init__(self, root):
        self.root = root
        root.title("Two Moons → GNG (PC Python, no numpy)")

        self.canvas = tk.Canvas(root, width=WIN_W, height=WIN_H, bg=BG_COLOR, highlightthickness=0)
        self.canvas.pack()

        self.data = generate_moons(
            N=MOONS_N,
            random_angle=MOONS_RANDOM_ANGLE,
            noise_std=MOONS_NOISE_STD,
            seed=MOONS_SEED,
            shuffle=MOONS_SHUFFLE,
            normalize01=MOONS_NORMALIZE01
        )

        self.nodes, self.edges = init_gng()

        self.step_count = 0
        self.data_idx = 0

        # perf tracking
        self.t0 = time.perf_counter()
        self.last_draw_t = self.t0
        self.last_draw_steps = 0
        self.sps = 0.0

        self.running = True

        # Draw static parts once
        self._draw_static()

        # controls
        root.bind("<space>", self.toggle_run)   # space to pause/resume
        root.bind("r", self.reset)             # r to reset

        self._tick()

    def _to_screen_left(self, x, y):
        sx = x * SCALE + MARGIN
        sy = y * SCALE + MARGIN
        return sx, sy

    def _to_screen_right(self, x, y):
        sx = x * SCALE + MARGIN + PANEL_W
        sy = y * SCALE + MARGIN
        return sx, sy

    def _draw_static(self):
        self.canvas.delete("all")

        # titles
        self.canvas.create_text(250, 25, fill="#cfcfcf", text="Two Moons Dataset", font=("Consolas", 14))
        self.canvas.create_text(750, 25, fill="#cfcfcf", text="GNG Output (Nodes + Edges)", font=("Consolas", 14))

        # divider
        self.canvas.create_line(PANEL_W, 0, PANEL_W, WIN_H, fill="#3a3a3a", width=2)

        # dataset points (left)
        for x, y in self.data:
            sx, sy = self._to_screen_left(x, y)
            self.canvas.create_oval(sx-3, sy-3, sx+3, sy+3, fill=DATA_COLOR, outline="")

        # also show same dataset on right faintly (optional)
        for x, y in self.data:
            sx, sy = self._to_screen_right(x, y)
            self.canvas.create_oval(sx-2, sy-2, sx+2, sy+2, fill="#666666", outline="")

        # dynamic tags layers
        self.canvas.create_rectangle(0, WIN_H-110, WIN_W, WIN_H, fill="#000000", outline="", stipple="gray25", tags=("hud",))

    def _draw_gng(self):
        # clear previous dynamic gng drawings
        self.canvas.delete("gng")

        # edges
        for e in self.edges:
            if not e.active:
                continue
            if not (0 <= e.a < MAX_NODES and 0 <= e.b < MAX_NODES):
                continue
            na = self.nodes[e.a]
            nb = self.nodes[e.b]
            if not (na.active and nb.active):
                continue
            x1, y1 = self._to_screen_right(na.x, na.y)
            x2, y2 = self._to_screen_right(nb.x, nb.y)
            self.canvas.create_line(x1, y1, x2, y2, fill=EDGE_COLOR, width=2, tags=("gng",))

        # nodes
        for i, n in enumerate(self.nodes):
            if not n.active:
                continue
            sx, sy = self._to_screen_right(n.x, n.y)
            self.canvas.create_oval(sx-6, sy-6, sx+6, sy+6, fill=NODE_COLOR, outline="", tags=("gng",))
            # optional index label (comment out if clutter)
            # self.canvas.create_text(sx, sy-12, fill="#cfcfcf", text=str(i), font=("Consolas", 9), tags=("gng",))

    def _draw_hud(self):
        self.canvas.delete("hudtext")

        n_nodes = count_active_nodes(self.nodes)
        n_edges = count_active_edges(self.edges)

        line1 = f"steps={self.step_count} | steps/sec≈{self.sps:.1f} | active nodes={n_nodes}/{MAX_NODES} | active edges={n_edges}/{MAX_EDGES}"
        line2 = f"params: λ={GNG_LAMBDA} eps_b={GNG_EPSILON_B} eps_n={GNG_EPSILON_N} α={GNG_ALPHA} a_max={GNG_A_MAX} d={GNG_D}"
        line3 = "Controls: [Space]=Pause/Run, [r]=Reset"

        self.canvas.create_text(10, WIN_H-80, anchor="w", fill="#00ff66", text=line1, font=("Consolas", 12), tags=("hudtext",))
        self.canvas.create_text(10, WIN_H-55, anchor="w", fill="#ffd166", text=line2, font=("Consolas", 11), tags=("hudtext",))
        self.canvas.create_text(10, WIN_H-30, anchor="w", fill="#b3b3ff", text=line3, font=("Consolas", 11), tags=("hudtext",))

    def toggle_run(self, _evt=None):
        self.running = not self.running

    def reset(self, _evt=None):
        self.nodes, self.edges = init_gng()
        self.step_count = 0
        self.data_idx = 0
        self.t0 = time.perf_counter()
        self.last_draw_t = self.t0
        self.last_draw_steps = 0
        self.sps = 0.0
        self._draw_static()

    def _tick(self):
        if self.running:
            # run a bunch of steps per tick
            for _ in range(STEPS_PER_TICK):
                x, y = self.data[self.data_idx]
                self.data_idx += 1
                if self.data_idx >= len(self.data):
                    self.data_idx = 0

                ok = train_one_step(self.nodes, self.edges, x, y)
                if not ok:
                    continue

                self.step_count += 1

                if (self.step_count % GNG_LAMBDA) == 0:
                    insert_node(self.nodes, self.edges)
                    prune_isolated_nodes(self.nodes, self.edges)

            # redraw occasionally
            if (self.step_count % DRAW_EVERY_N) == 0:
                now = time.perf_counter()
                dt = now - self.last_draw_t
                ds = self.step_count - self.last_draw_steps
                if dt > 1e-9:
                    self.sps = ds / dt
                self.last_draw_t = now
                self.last_draw_steps = self.step_count

                self._draw_gng()
                self._draw_hud()

        # schedule next tick
        self.root.after(1, self._tick)


if __name__ == "__main__":
    root = tk.Tk()
    app = GNGApp(root)
    root.mainloop()
