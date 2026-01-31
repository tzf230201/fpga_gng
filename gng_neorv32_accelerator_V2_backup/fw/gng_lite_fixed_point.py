"""
GNG-Lite: Memory-Efficient Fixed-Point Implementation
=====================================================
Optimized for microcontrollers and FPGA implementations.

Key Features:
- Fixed-point arithmetic (Q16.16 format)
- Minimal memory footprint
- Integer-only operations
- Configurable precision vs memory trade-off

References:
[1] Fritzke, B. (1995). A growing neural gas network learns topologies.
    Advances in Neural Information Processing Systems, 7, 625-632.
[2] Marsland, S., Shapiro, J., & Nehmzow, U. (2002). A self-organising 
    network that grows when required. Neural Networks, 15(8-9), 1041-1058.
"""

import numpy as np
from dataclasses import dataclass
from typing import Tuple, List
import struct


# ============================================================
# Fixed-Point Arithmetic Configuration
# ============================================================
FIXED_POINT_BITS = 16  # Q16.16 format (16 integer bits, 16 fractional bits)
FIXED_POINT_SCALE = 1 << FIXED_POINT_BITS
FIXED_POINT_MAX = (1 << 31) - 1
FIXED_POINT_MIN = -(1 << 31)


def float_to_fixed(x: float) -> int:
    """Convert float to Q16.16 fixed-point integer."""
    val = int(x * FIXED_POINT_SCALE)
    return max(FIXED_POINT_MIN, min(FIXED_POINT_MAX, val))


def fixed_to_float(x: int) -> float:
    """Convert Q16.16 fixed-point integer to float."""
    return x / FIXED_POINT_SCALE


def fixed_mul(a: int, b: int) -> int:
    """Multiply two fixed-point numbers with overflow protection."""
    # Use int64 to prevent overflow in intermediate multiplication
    result = (np.int64(a) * np.int64(b)) >> FIXED_POINT_BITS
    return int(max(FIXED_POINT_MIN, min(FIXED_POINT_MAX, result)))


def fixed_div(a: int, b: int) -> int:
    """Divide two fixed-point numbers."""
    if b == 0:
        return FIXED_POINT_MAX if a >= 0 else FIXED_POINT_MIN
    result = (a << FIXED_POINT_BITS) // b
    return max(FIXED_POINT_MIN, min(FIXED_POINT_MAX, result))


def normalize_data(data: np.ndarray, scale: float = 1.0) -> np.ndarray:
    """Normalize data to [-scale, scale] range for fixed-point.
    
    For Q16.16, safe range is approximately -100 to 100 to avoid overflow.
    """
    data_min = np.min(data, axis=0)
    data_max = np.max(data, axis=0)
    data_range = data_max - data_min
    data_range = np.where(data_range == 0, 1, data_range)  # Avoid division by zero
    
    # Normalize to [0, 1] then scale to [-scale, scale]
    normalized = (data - data_min) / data_range  # [0, 1]
    normalized = (normalized * 2 - 1) * scale    # [-scale, scale]
    return normalized.astype(np.float32)


def fixed_sqrt(x: int) -> int:
    """Integer square root for fixed-point (Q16.16)."""
    if x <= 0:
        return 0
    
    # Newton-Raphson method in fixed-point
    guess = x >> 1
    if guess == 0:
        guess = 1
    
    for _ in range(10):  # 10 iterations sufficient for Q16.16
        new_guess = (guess + fixed_div(x, guess)) >> 1
        if abs(new_guess - guess) < 2:
            break
        guess = new_guess
    
    return guess


# ============================================================
# Memory-Efficient Data Structures
# ============================================================
@dataclass
class GNGLiteConfig:
    """Configuration for memory-efficient GNG."""
    max_nodes: int = 32          # Maximum nodes (reduced for MCU)
    max_edges: int = 64          # Maximum edges
    feature_dim: int = 2         # Feature dimension
    
    # Learning parameters (matching original GNG paper: Fritzke 1995)
    epsilon_winner: float = 0.05  # Learning rate for winner (eb)
    epsilon_neighbor: float = 0.0006  # Learning rate for neighbors (en)
    alpha: float = 0.5           # Error decay factor for new node split
    beta: float = 0.995          # Global error decay per step (close to 1.0)
    
    # Topology control
    max_age: int = 88            # Maximum edge age (amax)
    lambda_: int = 300           # New node insertion frequency (iterations)
    
    # Fixed-point precision
    use_fixed_point: bool = True


class CompactEdge:
    """Memory-efficient edge representation (8 bytes total)."""
    __slots__ = ['n1', 'n2', 'age']
    
    def __init__(self, n1: int, n2: int):
        self.n1 = n1  # 2 bytes (uint16)
        self.n2 = n2  # 2 bytes (uint16)
        self.age = 0  # 2 bytes (uint16)
    
    def to_bytes(self) -> bytes:
        """Pack to 6 bytes."""
        return struct.pack('<HHH', self.n1, self.n2, self.age)
    
    @staticmethod
    def from_bytes(data: bytes) -> 'CompactEdge':
        """Unpack from 6 bytes."""
        n1, n2, age = struct.unpack('<HHH', data)
        edge = CompactEdge(n1, n2)
        edge.age = age
        return edge


class GNGLite:
    """
    Memory-efficient GNG implementation with fixed-point arithmetic.
    
    Memory usage per node (Q16.16):
    - Weights: feature_dim * 4 bytes
    - Error: 4 bytes
    Total per node: (feature_dim * 4) + 4 bytes
    
    Memory usage per edge:
    - Node indices: 2 * 2 bytes
    - Age: 2 bytes
    Total per edge: 6 bytes
    
    Example for 32 nodes, 2D, 64 edges:
    Nodes: 32 * (2*4 + 4) = 384 bytes
    Edges: 64 * 6 = 384 bytes
    Total: ~768 bytes (vs ~1.5KB for float implementation)
    """
    
    def __init__(self, config: GNGLiteConfig):
        self.cfg = config
        self.n_nodes = 0
        self.n_edges = 0
        self.iteration = 0
        
        # Pre-allocate fixed-size arrays
        if config.use_fixed_point:
            # Weights as int32 (Q16.16)
            self.weights = np.zeros((config.max_nodes, config.feature_dim), dtype=np.int32)
            self.errors = np.zeros(config.max_nodes, dtype=np.int32)
            
            # Convert learning rates to fixed-point
            self.eps_w = float_to_fixed(config.epsilon_winner)
            self.eps_n = float_to_fixed(config.epsilon_neighbor)
            self.alpha_fixed = float_to_fixed(config.alpha)
            self.beta_fixed = float_to_fixed(config.beta)
        else:
            # Float32 version for comparison
            self.weights = np.zeros((config.max_nodes, config.feature_dim), dtype=np.float32)
            self.errors = np.zeros(config.max_nodes, dtype=np.float32)
            self.eps_w = config.epsilon_winner
            self.eps_n = config.epsilon_neighbor
            self.alpha_fixed = config.alpha
            self.beta_fixed = config.beta
        
        # Edge list (compact representation)
        self.edges = [None] * config.max_edges
        self.edge_ages = np.zeros(config.max_edges, dtype=np.uint16)
        self.edge_nodes = np.zeros((config.max_edges, 2), dtype=np.uint16)
    
    def initialize(self, data: np.ndarray):
        """Initialize with first two random samples."""
        if len(data) < 2:
            raise ValueError("Need at least 2 samples")
        
        # Pick two random samples
        idx = np.random.choice(len(data), 2, replace=False)
        
        if self.cfg.use_fixed_point:
            # Convert to fixed-point
            for i in range(2):
                for d in range(self.cfg.feature_dim):
                    self.weights[i, d] = float_to_fixed(data[idx[i], d])
        else:
            self.weights[:2] = data[idx].astype(np.float32)
        
        self.n_nodes = 2
        
        # Add initial edge
        self.add_edge(0, 1)
    
    def get_memory_usage(self) -> dict:
        """Calculate actual memory usage in bytes."""
        node_mem = self.n_nodes * (self.cfg.feature_dim * 4 + 4)
        edge_mem = self.n_edges * 6
        overhead = 100  # Approximate overhead
        
        return {
            'nodes_bytes': node_mem,
            'edges_bytes': edge_mem,
            'total_bytes': node_mem + edge_mem + overhead,
            'total_kb': (node_mem + edge_mem + overhead) / 1024
        }
    
    def distance_squared(self, node_idx: int, sample: np.ndarray) -> int:
        """Calculate squared Euclidean distance (fixed-point)."""
        if self.cfg.use_fixed_point:
            dist_sq = 0
            for d in range(self.cfg.feature_dim):
                diff = self.weights[node_idx, d] - float_to_fixed(sample[d])
                # Use int64 to prevent overflow in multiplication
                diff_sq = (np.int64(diff) * np.int64(diff)) >> FIXED_POINT_BITS
                dist_sq += int(diff_sq)
            return dist_sq
        else:
            diff = self.weights[node_idx, :self.cfg.feature_dim] - sample
            return int(np.sum(diff * diff) * FIXED_POINT_SCALE)
    
    def find_two_nearest(self, sample: np.ndarray) -> Tuple[int, int]:
        """Find indices of two nearest nodes."""
        distances = np.array([self.distance_squared(i, sample) for i in range(self.n_nodes)])
        sorted_idx = np.argsort(distances)
        return sorted_idx[0], sorted_idx[1]
    
    def add_edge(self, n1: int, n2: int) -> bool:
        """Add edge between nodes n1 and n2."""
        if n1 == n2:
            return False
        
        # Ensure n1 < n2 for consistency
        if n1 > n2:
            n1, n2 = n2, n1
        
        # Check if edge already exists
        for i in range(self.n_edges):
            if self.edge_nodes[i, 0] == n1 and self.edge_nodes[i, 1] == n2:
                self.edge_ages[i] = 0  # Reset age
                return True
        
        # Add new edge if space available
        if self.n_edges < self.cfg.max_edges:
            self.edge_nodes[self.n_edges] = [n1, n2]
            self.edge_ages[self.n_edges] = 0
            self.n_edges += 1
            return True
        
        return False
    
    def remove_edge(self, edge_idx: int):
        """Remove edge at index."""
        if edge_idx < self.n_edges:
            # Shift remaining edges
            self.edge_nodes[edge_idx:self.n_edges-1] = self.edge_nodes[edge_idx+1:self.n_edges]
            self.edge_ages[edge_idx:self.n_edges-1] = self.edge_ages[edge_idx+1:self.n_edges]
            self.n_edges -= 1
    
    def get_neighbors(self, node_idx: int) -> List[int]:
        """Get all neighbors of a node."""
        neighbors = []
        for i in range(self.n_edges):
            if self.edge_nodes[i, 0] == node_idx:
                neighbors.append(self.edge_nodes[i, 1])
            elif self.edge_nodes[i, 1] == node_idx:
                neighbors.append(self.edge_nodes[i, 0])
        return neighbors
    
    def update_weights(self, node_idx: int, sample: np.ndarray, learning_rate: int):
        """Update node weights towards sample."""
        if self.cfg.use_fixed_point:
            for d in range(self.cfg.feature_dim):
                sample_fixed = float_to_fixed(sample[d])
                delta = sample_fixed - self.weights[node_idx, d]
                self.weights[node_idx, d] += fixed_mul(learning_rate, delta)
        else:
            delta = sample - self.weights[node_idx, :self.cfg.feature_dim]
            self.weights[node_idx, :self.cfg.feature_dim] += learning_rate * delta
    
    def train_step(self, sample: np.ndarray):
        """Single training step with one sample (following Fritzke 1995)."""
        if self.n_nodes < 2:
            return
        
        # Find two nearest nodes (s1=BMU, s2=2nd BMU)
        s1, s2 = self.find_two_nearest(sample)
        
        # Accumulate squared error to winner
        dist_sq = self.distance_squared(s1, sample)
        if self.cfg.use_fixed_point:
            self.errors[s1] += dist_sq
        else:
            self.errors[s1] += dist_sq / FIXED_POINT_SCALE
        
        # Move winner node towards input signal
        self.update_weights(s1, sample, self.eps_w)
        
        # Move neighbors of winner towards input signal
        neighbors = self.get_neighbors(s1)
        for n in neighbors:
            self.update_weights(n, sample, self.eps_n)
        
        # Create/refresh edge between s1 and s2 (reset age to 0)
        self.add_edge(s1, s2)
        
        # Increment age of all edges emanating from s1
        for i in range(self.n_edges):
            if self.edge_nodes[i, 0] == s1 or self.edge_nodes[i, 1] == s1:
                self.edge_ages[i] += 1
        
        # Remove edges with age > max_age
        i = 0
        while i < self.n_edges:
            if self.edge_ages[i] > self.cfg.max_age:
                self.remove_edge(i)
            else:
                i += 1
        
        # Remove nodes without edges (isolated)
        self.remove_isolated_nodes()
        
        # Insert new node periodically (every lambda iterations)
        self.iteration += 1
        if self.iteration % self.cfg.lambda_ == 0 and self.n_nodes < self.cfg.max_nodes:
            self.insert_node()
        
        # Decrease all error variables by factor beta
        if self.cfg.use_fixed_point:
            for i in range(self.n_nodes):
                self.errors[i] = fixed_mul(self.errors[i], self.beta_fixed)
        else:
            self.errors[:self.n_nodes] *= self.beta_fixed
    
    def remove_isolated_nodes(self):
        """Remove nodes without edges."""
        # Build node usage mask
        used = np.zeros(self.cfg.max_nodes, dtype=bool)
        for i in range(self.n_edges):
            used[self.edge_nodes[i, 0]] = True
            used[self.edge_nodes[i, 1]] = True
        
        # Keep only used nodes (compact)
        new_idx = 0
        mapping = np.zeros(self.cfg.max_nodes, dtype=np.int32) - 1
        
        for old_idx in range(self.n_nodes):
            if used[old_idx]:
                if new_idx != old_idx:
                    self.weights[new_idx] = self.weights[old_idx]
                    self.errors[new_idx] = self.errors[old_idx]
                mapping[old_idx] = new_idx
                new_idx += 1
        
        self.n_nodes = new_idx
        
        # Update edge indices
        for i in range(self.n_edges):
            self.edge_nodes[i, 0] = mapping[self.edge_nodes[i, 0]]
            self.edge_nodes[i, 1] = mapping[self.edge_nodes[i, 1]]
    
    def insert_node(self):
        """Insert new node between node with highest error and its neighbor."""
        if self.n_nodes >= self.cfg.max_nodes:
            return
        
        # Find node with maximum error
        q = int(np.argmax(self.errors[:self.n_nodes]))
        
        # Find neighbor with maximum error
        neighbors = self.get_neighbors(q)
        if not neighbors:
            return
        
        f = max(neighbors, key=lambda n: self.errors[n])
        
        # Create new node between q and f
        new_idx = self.n_nodes
        if self.cfg.use_fixed_point:
            for d in range(self.cfg.feature_dim):
                self.weights[new_idx, d] = (self.weights[q, d] + self.weights[f, d]) >> 1
        else:
            self.weights[new_idx] = (self.weights[q] + self.weights[f]) / 2
        
        # Remove edge q-f
        for i in range(self.n_edges):
            if ((self.edge_nodes[i, 0] == q and self.edge_nodes[i, 1] == f) or
                (self.edge_nodes[i, 0] == f and self.edge_nodes[i, 1] == q)):
                self.remove_edge(i)
                break
        
        # Add edges q-new and f-new
        self.add_edge(q, new_idx)
        self.add_edge(f, new_idx)
        
        # Decrease errors
        if self.cfg.use_fixed_point:
            self.errors[q] = fixed_mul(self.errors[q], self.alpha_fixed)
            self.errors[f] = fixed_mul(self.errors[f], self.alpha_fixed)
            self.errors[new_idx] = self.errors[q]
        else:
            self.errors[q] *= self.alpha_fixed
            self.errors[f] *= self.alpha_fixed
            self.errors[new_idx] = self.errors[q]
        
        self.n_nodes += 1
    
    def train(self, data: np.ndarray, epochs: int = 1):
        """Train on dataset for specified epochs."""
        data = np.asarray(data, dtype=np.float32)
        
        if self.n_nodes == 0:
            self.initialize(data)
        
        for epoch in range(epochs):
            # Shuffle data each epoch
            indices = np.random.permutation(len(data))
            for idx in indices:
                self.train_step(data[idx])
    
    def get_weights_as_float(self) -> np.ndarray:
        """Get node weights as float array."""
        if self.cfg.use_fixed_point:
            weights_float = np.zeros((self.n_nodes, self.cfg.feature_dim), dtype=np.float32)
            for i in range(self.n_nodes):
                for d in range(self.cfg.feature_dim):
                    weights_float[i, d] = fixed_to_float(self.weights[i, d])
            return weights_float
        else:
            return self.weights[:self.n_nodes].copy()
    
    def get_edges_as_list(self) -> List[Tuple[int, int]]:
        """Get edge list."""
        return [(int(self.edge_nodes[i, 0]), int(self.edge_nodes[i, 1])) 
                for i in range(self.n_edges)]
    
    def export_to_c_header(self, filename: str):
        """Export network to C header file for embedded deployment."""
        with open(filename, 'w') as f:
            f.write("// Auto-generated GNG network for embedded deployment\n")
            f.write(f"// Generated: {self.n_nodes} nodes, {self.n_edges} edges\n\n")
            f.write("#ifndef GNG_NETWORK_H\n")
            f.write("#define GNG_NETWORK_H\n\n")
            f.write("#include <stdint.h>\n\n")
            
            # Configuration
            f.write(f"#define GNG_N_NODES {self.n_nodes}\n")
            f.write(f"#define GNG_N_EDGES {self.n_edges}\n")
            f.write(f"#define GNG_FEATURE_DIM {self.cfg.feature_dim}\n\n")
            
            # Weights
            f.write("const int32_t gng_weights[GNG_N_NODES][GNG_FEATURE_DIM] = {\n")
            for i in range(self.n_nodes):
                f.write("    {")
                for d in range(self.cfg.feature_dim):
                    if self.cfg.use_fixed_point:
                        f.write(f"{self.weights[i, d]}")
                    else:
                        f.write(f"{float_to_fixed(self.weights[i, d])}")
                    if d < self.cfg.feature_dim - 1:
                        f.write(", ")
                f.write("}")
                if i < self.n_nodes - 1:
                    f.write(",")
                f.write("\n")
            f.write("};\n\n")
            
            # Edges
            f.write("const uint16_t gng_edges[GNG_N_EDGES][2] = {\n")
            for i in range(self.n_edges):
                f.write(f"    {{{self.edge_nodes[i, 0]}, {self.edge_nodes[i, 1]}}}")
                if i < self.n_edges - 1:
                    f.write(",")
                f.write("\n")
            f.write("};\n\n")
            
            f.write("#endif // GNG_NETWORK_H\n")
        
        print(f"Exported to {filename}")


if __name__ == "__main__":
    # Quick test
    print("Testing GNG-Lite Fixed-Point Implementation")
    print("=" * 50)
    
    # Generate simple test data
    np.random.seed(42)
    data = np.random.randn(100, 2).astype(np.float32) * 0.5
    
    # Fixed-point version
    config_fixed = GNGLiteConfig(
        max_nodes=16,
        max_edges=32,
        feature_dim=2,
        use_fixed_point=True
    )
    gng_fixed = GNGLite(config_fixed)
    gng_fixed.train(data, epochs=5)
    
    mem_fixed = gng_fixed.get_memory_usage()
    print(f"\nFixed-Point Version:")
    print(f"  Nodes: {gng_fixed.n_nodes}")
    print(f"  Edges: {gng_fixed.n_edges}")
    print(f"  Memory: {mem_fixed['total_bytes']} bytes ({mem_fixed['total_kb']:.2f} KB)")
    
    # Float version for comparison
    config_float = GNGLiteConfig(
        max_nodes=16,
        max_edges=32,
        feature_dim=2,
        use_fixed_point=False
    )
    gng_float = GNGLite(config_float)
    gng_float.train(data, epochs=5)
    
    mem_float = gng_float.get_memory_usage()
    print(f"\nFloat32 Version:")
    print(f"  Nodes: {gng_float.n_nodes}")
    print(f"  Edges: {gng_float.n_edges}")
    print(f"  Memory: {mem_float['total_bytes']} bytes ({mem_float['total_kb']:.2f} KB)")
    
    memory_saving = (1 - mem_fixed['total_bytes'] / mem_float['total_bytes']) * 100
    print(f"\nMemory Saving: {memory_saving:.1f}%")
    
    # Export to C header
    gng_fixed.export_to_c_header("gng_network.h")
