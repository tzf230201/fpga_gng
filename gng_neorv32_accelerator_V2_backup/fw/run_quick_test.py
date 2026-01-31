"""
Quick Test - Verify Fixed GNG-Lite Works
=========================================
Test after parameter fixes to ensure topology is good.
"""

import numpy as np
import matplotlib.pyplot as plt
from gng_lite_fixed_point import GNGLite, GNGLiteConfig, normalize_data
from experiment_metrics import GNGMetricsEvaluator

# Generate two moons dataset
def generate_two_moons(n_samples=200, noise=0.05):
    n = n_samples // 2
    t = np.linspace(0, np.pi, n)
    
    # First moon
    x1 = np.cos(t)
    y1 = np.sin(t)
    moon1 = np.column_stack([x1, y1])
    
    # Second moon
    x2 = 1 - np.cos(t)
    y2 = 0.5 - np.sin(t)
    moon2 = np.column_stack([x2, y2])
    
    data = np.vstack([moon1, moon2])
    data += np.random.randn(*data.shape) * noise
    
    return data.astype(np.float32)

print("=" * 80)
print("QUICK TEST: GNG-Lite Fixed Parameters")
print("=" * 80)

# Generate data
print("\nGenerating Two Moons dataset...")
data_raw = generate_two_moons(400, noise=0.05)
print(f"Generated {len(data_raw)} samples")

# Normalize for fixed-point (important!)
print("Normalizing data to [-10, 10] range for Q16.16...")
data = normalize_data(data_raw, scale=10.0)
print(f"  Range: [{data.min():.2f}, {data.max():.2f}]")

# Test Float32
print("\n[1/2] Testing Float32...")
config_float = GNGLiteConfig(
    max_nodes=32,
    max_edges=100,
    feature_dim=2,
    epsilon_winner=0.05,
    epsilon_neighbor=0.0006,
    alpha=0.5,
    beta=0.995,
    max_age=88,
    lambda_=300,
    use_fixed_point=False
)

gng_float = GNGLite(config_float)
gng_float.train(data, epochs=10)

evaluator = GNGMetricsEvaluator()
qe_float = evaluator.quantization_error(gng_float, data)
te_float = evaluator.topological_error(gng_float, data)
mem_float = gng_float.get_memory_usage()

print(f"  Nodes: {gng_float.n_nodes}")
print(f"  Edges: {gng_float.n_edges}")
print(f"  QE: {qe_float:.4f}")
print(f"  TE: {te_float*100:.2f}%")
print(f"  Memory: {mem_float['total_bytes']} bytes")

# Test Fixed-Point
print("\n[2/2] Testing Fixed-Point Q16.16...")
config_fixed = GNGLiteConfig(
    max_nodes=32,
    max_edges=100,
    feature_dim=2,
    epsilon_winner=0.05,
    epsilon_neighbor=0.0006,
    alpha=0.5,
    beta=0.995,
    max_age=88,
    lambda_=300,
    use_fixed_point=True
)

gng_fixed = GNGLite(config_fixed)
gng_fixed.train(data, epochs=10)

qe_fixed = evaluator.quantization_error(gng_fixed, data)
te_fixed = evaluator.topological_error(gng_fixed, data)
mem_fixed = gng_fixed.get_memory_usage()

print(f"  Nodes: {gng_fixed.n_nodes}")
print(f"  Edges: {gng_fixed.n_edges}")
print(f"  QE: {qe_fixed:.4f}")
print(f"  TE: {te_fixed*100:.2f}%")
print(f"  Memory: {mem_fixed['total_bytes']} bytes")

# Visualize
print("\nGenerating visualization...")
fig, axes = plt.subplots(1, 2, figsize=(12, 5))

for idx, (gng, title) in enumerate([(gng_float, "Float32"), (gng_fixed, "Fixed-Point Q16.16")]):
    ax = axes[idx]
    
    # Plot data
    ax.scatter(data[:, 0], data[:, 1], c='lightgray', s=10, alpha=0.5, label='Data')
    
    # Plot nodes
    weights = gng.weights[:gng.n_nodes]
    ax.scatter(weights[:, 0], weights[:, 1], c='orange', s=100, 
               edgecolors='black', linewidths=2, label='Nodes', zorder=5)
    
    # Plot edges
    for i in range(gng.n_edges):
        n1, n2 = gng.edge_nodes[i]
        if n1 < gng.n_nodes and n2 < gng.n_nodes:
            ax.plot([weights[n1, 0], weights[n2, 0]], 
                   [weights[n1, 1], weights[n2, 1]], 
                   'b-', alpha=0.6, linewidth=1.5)
    
    ax.set_title(f"{title}\n{gng.n_nodes} nodes, {gng.n_edges} edges")
    ax.legend()
    ax.grid(True, alpha=0.3)

plt.tight_layout()
plt.savefig('quick_test_result.png', dpi=300, bbox_inches='tight')
print("Saved: quick_test_result.png")
plt.show()

print("\n" + "=" * 80)
print("TEST COMPLETE!")
print("=" * 80)
print(f"\nSUMMARY:")
print(f"  Float32:  {gng_float.n_nodes} nodes, QE={qe_float:.4f}, TE={te_float*100:.1f}%")
print(f"  Fixed-Pt: {gng_fixed.n_nodes} nodes, QE={qe_fixed:.4f}, TE={te_fixed*100:.1f}%")
print(f"\n  Memory Reduction: {mem_float['total_bytes']} -> {mem_fixed['total_bytes']} bytes")
print(f"  Status: {'PASS' if gng_fixed.n_nodes >= 6 and te_fixed < 0.2 else 'FAIL'}")
print("=" * 80)
