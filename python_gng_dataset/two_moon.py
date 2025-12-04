import time
import serial
import numpy as np
from sklearn.datasets import make_moons
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

# =======================
# Konfigurasi UART & data
# =======================
PORT = "COM1"
BAUD = 115200
NUM_SAMPLES = 50

# =======================
# Generate dataset: two-moons
# =======================
X, y = make_moons(n_samples=NUM_SAMPLES, noise=0.05, random_state=0)

# Normalisasi ke [0,1] supaya cocok dengan firmware
xmin, xmax = X[:, 0].min(), X[:, 0].max()
ymin, ymax = X[:, 1].min(), X[:, 1].max()
Xn = np.empty_like(X)
Xn[:, 0] = (X[:, 0] - xmin) / (xmax - xmin)
Xn[:, 1] = (X[:, 1] - ymin) / (ymax - ymin)

print(f"[INFO] Opening serial: {PORT}")
ser = serial.Serial(PORT, BAUD, timeout=0.5)
print("[INFO] Serial opened.")

# =======================
# Kirim dataset ke PicoRV
# =======================
print("[INFO] Sending dataset...")
for i, (xv, yv) in enumerate(Xn, start=1):
    line = f"DATA:{xv:.5f},{yv:.5f};\n"
    ser.write(line.encode("ascii"))
    print(f"[TX] {line.strip()}")

    ack = ser.readline().decode("ascii", errors="ignore").strip()
    if ack:
        print(f"[RX] {ack}")
    else:
        print(f"[WARN] No ACK for sample {i}")

# Beritahu firmware bahwa dataset selesai
ser.write(b"DONE;\n")
print("[TX] DONE;")
print("[INFO] Dataset sent. Switching to LIVE GNG mode...")

# Setelah dataset selesai, pakai non-blocking read
ser.timeout = 0
ser.reset_input_buffer()

# =======================
# Buffer & state GNG (diupdate dari UART)
# =======================
line_buffer = ""          # buffer untuk potongan line UART
latest_nodes = []         # list[(x,y)]
latest_edges = []         # list[(i,j)]


def parse_gng_line(line: str):
    """
    line: string mulai dari 'GNG:...'
    Format payload yang diharapkan:
      GNG:N:0,x0,y0;N:1,x1,y1;...;E:0,1;E:1,2;
    """
    global latest_nodes, latest_edges
    payload = line[4:]  # buang 'GNG:'

    nodes = []
    edges = []

    parts = [p for p in payload.split(';') if p]
    for p in parts:
        if p.startswith("N:"):
            # N:id,x,y
            _, rest = p.split(":", 1)
            _id_str, xs, ys = rest.split(",")
            nodes.append((float(xs), float(ys)))
        elif p.startswith("E:"):
            # E:a,b
            _, rest = p.split(":", 1)
            a_str, b_str = rest.split(",")
            edges.append((int(a_str), int(b_str)))

    # update state global
    latest_nodes = nodes
    latest_edges = edges


def poll_serial():
    """
    Baca semua data yang ada di UART (non-blocking),
    pecah per-baris, dan parse semua line yang diawali 'GNG:'.
    """
    global line_buffer

    while True:
        n = ser.in_waiting
        if n <= 0:
            break

        data = ser.read(n)
        if not data:
            break

        text = data.decode("ascii", errors="ignore")
        line_buffer += text

        # proses semua line yang lengkap
        while "\n" in line_buffer:
            line, line_buffer = line_buffer.split("\n", 1)
            line = line.strip()
            if not line:
                continue
            print(f"[RX] {line}")
            if line.startswith("GNG:"):
                parse_gng_line(line)


# =======================
# Setup plot Matplotlib
# =======================
fig, ax = plt.subplots(figsize=(6, 6))

# Plot dua bulan (background)
mask0 = (y == 0)
mask1 = (y == 1)
ax.scatter(
    Xn[mask0, 0], Xn[mask0, 1],
    s=12, alpha=0.6, label="class 0"
)
ax.scatter(
    Xn[mask1, 0], Xn[mask1, 1],
    s=12, alpha=0.6, label="class 1"
)

# Scatter untuk node GNG (awal kosong)
node_scatter = ax.scatter([], [], s=80, marker="x", c="red",
                          linewidths=2, label="GNG nodes")

# List untuk line objek edge
edge_lines = []

ax.set_title("LIVE GNG on Two-Moons (from PicoRV)")
ax.set_xlabel("x (normalized)")
ax.set_ylabel("y (normalized)")
ax.axis("equal")
ax.grid(True, linestyle="--", alpha=0.4)
ax.legend(loc="upper right")
plt.tight_layout()


def update(frame):
    """
    Dipanggil berkala oleh FuncAnimation.
    - Poll UART
    - Update node_scatter & edge_lines
    """
    # 1) baca semua data UART yang sudah masuk
    poll_serial()

    # 2) update node scatter
    global latest_nodes, latest_edges, edge_lines

    if latest_nodes:
        xs = [p[0] for p in latest_nodes]
        ys = [p[1] for p in latest_nodes]
        offsets = np.column_stack((xs, ys))
    else:
        # penting: kalau kosong, kasih array 0x2 biar tidak error IndexError
        offsets = np.empty((0, 2))
    node_scatter.set_offsets(offsets)

    # hapus semua edge line lama
    for ln in edge_lines:
        ln.remove()
    edge_lines = []

    # 3) gambar edge baru berdasarkan latest_edges
    if latest_edges and latest_nodes:
        for a, b in latest_edges:
            if 0 <= a < len(latest_nodes) and 0 <= b < len(latest_nodes):
                x1, y1 = latest_nodes[a]
                x2, y2 = latest_nodes[b]
                (ln,) = ax.plot(
                    [x1, x2], [y1, y2],
                    linewidth=1.0, color="gray", alpha=0.8
                )
                edge_lines.append(ln)

    # kalau mau, bisa juga kasih label index node:
    # (opsional, kalau terlalu ramai bisa di-comment)
    # pertama hapus semua teks lama dengan cara simple:
    for artist in list(ax.texts):
        artist.remove()
    for idx, (xv, yv) in enumerate(latest_nodes):
        ax.text(
            xv, yv,
            str(idx),
            color="red", fontsize=7,
            ha="center", va="bottom"
        )

    # tidak perlu return apa-apa kalau blit=False
    return node_scatter, *edge_lines


# =======================
# Jalankan animasi
# =======================
ani = FuncAnimation(
    fig, update,
    interval=100,  # ms, boleh diperkecil kalau mau lebih responsif
    blit=False
)

try:
    plt.show()
finally:
    print("[INFO] Closing serial...")
    ser.close()
    print("[INFO] Closed.")
