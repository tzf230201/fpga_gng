"""
Comprehensive Metrics Evaluation for GNG Implementations
========================================================

This script implements all standard metrics for evaluating GNG performance:
1. Quantization Error (QE) - Average distance to nearest node
2. Topological Error (TE) - Percentage of non-adjacent BMU pairs
3. Memory Usage - Actual bytes used
4. Computation Time - Training and inference time
5. Node Utilization - Percentage of nodes actually used
6. Edge Density - Average edges per node

References:
[1] Fritzke, B. (1995). A growing neural gas network learns topologies.
[2] Martinetz, T., & Schulten, K. (1994). Topology representing networks.
[3] Marsland, S., et al. (2002). A self-organising network that grows when required.
"""

import numpy as np
import time
import matplotlib.pyplot as plt
from typing import Dict, List, Tuple
from dataclasses import dataclass, asdict
import json
import pickle


@dataclass
class MetricsResult:
    """Container for all metrics."""
    quantization_error: float
    topological_error: float
    memory_bytes: int
    training_time_sec: float
    inference_time_ms: float
    n_nodes: int
    n_edges: int
    node_utilization: float
    edge_density: float
    iterations: int
    
    def to_dict(self):
        return asdict(self)
    
    def to_json(self, filename: str):
        with open(filename, 'w') as f:
            json.dump(self.to_dict(), f, indent=2)


class GNGMetricsEvaluator:
    """
    Comprehensive metrics evaluation for GNG networks.
    
    Compatible with both standard GNG and GNG-Lite implementations.
    """
    
    def __init__(self):
        self.results = []
    
    @staticmethod
    def quantization_error(gng_model, test_data: np.ndarray) -> float:
        """
        Quantization Error (QE): Average distance from data points to their BMU.
        
        Lower is better. Measures representational accuracy.
        
        QE = (1/N) * Σ ||x_i - w_bmu(x_i)||
        
        Reference: Martinetz & Schulten (1994)
        """
        test_data = np.asarray(test_data, dtype=np.float32)
        weights = gng_model.get_weights_as_float()
        
        if len(weights) == 0:
            return float('inf')
        
        total_error = 0.0
        for sample in test_data:
            # Find BMU
            distances = np.linalg.norm(weights - sample, axis=1)
            min_dist = np.min(distances)
            total_error += min_dist
        
        return total_error / len(test_data)
    
    @staticmethod
    def topological_error(gng_model, test_data: np.ndarray) -> float:
        """
        Topological Error (TE): Percentage of samples where BMU and 2nd BMU are not neighbors.
        
        Lower is better. Measures topology preservation.
        
        TE = (1/N) * Σ u(x_i)
        where u(x_i) = 1 if BMU1 and BMU2 are not connected, 0 otherwise
        
        Reference: Martinetz & Schulten (1994)
        """
        test_data = np.asarray(test_data, dtype=np.float32)
        weights = gng_model.get_weights_as_float()
        edges = gng_model.get_edges_as_list()
        
        if len(weights) < 2:
            return 1.0  # Maximum error
        
        # Build adjacency set for O(1) lookup
        adjacency = set()
        for e1, e2 in edges:
            adjacency.add((min(e1, e2), max(e1, e2)))
        
        topological_errors = 0
        for sample in test_data:
            # Find two nearest nodes
            distances = np.linalg.norm(weights - sample, axis=1)
            sorted_indices = np.argsort(distances)
            bmu1, bmu2 = sorted_indices[0], sorted_indices[1]
            
            # Check if they are connected
            edge_key = (min(bmu1, bmu2), max(bmu1, bmu2))
            if edge_key not in adjacency:
                topological_errors += 1
        
        return topological_errors / len(test_data)
    
    @staticmethod
    def memory_usage(gng_model) -> Dict[str, int]:
        """
        Calculate actual memory usage in bytes.
        
        Returns detailed breakdown of memory consumption.
        """
        return gng_model.get_memory_usage()
    
    @staticmethod
    def node_utilization(gng_model, test_data: np.ndarray, threshold: float = 0.01) -> float:
        """
        Node Utilization: Percentage of nodes that are BMU for at least one sample.
        
        Higher is better. Measures how well nodes are distributed.
        """
        test_data = np.asarray(test_data, dtype=np.float32)
        weights = gng_model.get_weights_as_float()
        
        if len(weights) == 0:
            return 0.0
        
        used_nodes = set()
        for sample in test_data:
            distances = np.linalg.norm(weights - sample, axis=1)
            bmu = np.argmin(distances)
            used_nodes.add(bmu)
        
        return len(used_nodes) / len(weights)
    
    @staticmethod
    def edge_density(gng_model) -> float:
        """
        Edge Density: Average number of edges per node.
        
        Measures connectivity of the network topology.
        """
        n_nodes = gng_model.n_nodes
        n_edges = gng_model.n_edges
        
        if n_nodes == 0:
            return 0.0
        
        # Each edge connects 2 nodes
        return (2 * n_edges) / n_nodes
    
    @staticmethod
    def training_time(gng_model, train_data: np.ndarray, epochs: int = 1) -> float:
        """
        Measure training time in seconds.
        """
        start_time = time.perf_counter()
        gng_model.train(train_data, epochs=epochs)
        end_time = time.perf_counter()
        
        return end_time - start_time
    
    @staticmethod
    def inference_time(gng_model, test_data: np.ndarray, n_runs: int = 100) -> float:
        """
        Measure average inference time (finding BMU) in milliseconds.
        """
        test_data = np.asarray(test_data, dtype=np.float32)
        weights = gng_model.get_weights_as_float()
        
        # Warm-up
        for _ in range(10):
            sample = test_data[np.random.randint(len(test_data))]
            distances = np.linalg.norm(weights - sample, axis=1)
            _ = np.argmin(distances)
        
        # Actual measurement
        start_time = time.perf_counter()
        for _ in range(n_runs):
            sample = test_data[np.random.randint(len(test_data))]
            distances = np.linalg.norm(weights - sample, axis=1)
            _ = np.argmin(distances)
        end_time = time.perf_counter()
        
        return ((end_time - start_time) / n_runs) * 1000  # Convert to ms
    
    def evaluate_full(self, gng_model, train_data: np.ndarray, 
                     test_data: np.ndarray, epochs: int = 1) -> MetricsResult:
        """
        Perform full evaluation of GNG model.
        
        Args:
            gng_model: GNG model instance (must have required methods)
            train_data: Training dataset
            test_data: Test dataset for evaluation
            epochs: Number of training epochs
        
        Returns:
            MetricsResult with all computed metrics
        """
        # Training
        train_time = self.training_time(gng_model, train_data, epochs)
        
        # Post-training metrics
        qe = self.quantization_error(gng_model, test_data)
        te = self.topological_error(gng_model, test_data)
        mem = self.memory_usage(gng_model)
        inf_time = self.inference_time(gng_model, test_data)
        util = self.node_utilization(gng_model, test_data)
        density = self.edge_density(gng_model)
        
        result = MetricsResult(
            quantization_error=qe,
            topological_error=te,
            memory_bytes=mem['total_bytes'],
            training_time_sec=train_time,
            inference_time_ms=inf_time,
            n_nodes=gng_model.n_nodes,
            n_edges=gng_model.n_edges,
            node_utilization=util,
            edge_density=density,
            iterations=gng_model.iteration
        )
        
        self.results.append(result)
        return result
    
    def compare_implementations(self, results: List[MetricsResult], 
                               names: List[str]) -> Dict:
        """
        Compare multiple GNG implementations.
        
        Returns comparative statistics.
        """
        comparison = {
            'names': names,
            'quantization_error': [r.quantization_error for r in results],
            'topological_error': [r.topological_error for r in results],
            'memory_bytes': [r.memory_bytes for r in results],
            'training_time_sec': [r.training_time_sec for r in results],
            'inference_time_ms': [r.inference_time_ms for r in results],
        }
        
        return comparison
    
    def plot_comparison(self, results: List[MetricsResult], 
                       names: List[str], save_path: str = None):
        """
        Create comparison plots for multiple implementations.
        """
        fig, axes = plt.subplots(2, 3, figsize=(15, 10))
        fig.suptitle('GNG Implementation Comparison', fontsize=16)
        
        metrics = [
            ('quantization_error', 'Quantization Error', 'lower is better'),
            ('topological_error', 'Topological Error (%)', 'lower is better'),
            ('memory_bytes', 'Memory Usage (bytes)', 'lower is better'),
            ('training_time_sec', 'Training Time (sec)', 'lower is better'),
            ('inference_time_ms', 'Inference Time (ms)', 'lower is better'),
            ('node_utilization', 'Node Utilization', 'higher is better'),
        ]
        
        for idx, (metric, title, note) in enumerate(metrics):
            ax = axes[idx // 3, idx % 3]
            values = [getattr(r, metric) for r in results]
            
            if metric == 'topological_error':
                values = [v * 100 for v in values]  # Convert to percentage
            
            bars = ax.bar(names, values)
            ax.set_title(f'{title}\n({note})')
            ax.set_ylabel(title)
            
            # Color bars (green for best, red for worst)
            if 'lower' in note:
                best_idx = np.argmin(values)
                worst_idx = np.argmax(values)
            else:
                best_idx = np.argmax(values)
                worst_idx = np.argmin(values)
            
            bars[best_idx].set_color('green')
            bars[worst_idx].set_color('red')
            
            # Rotate x labels if needed
            if len(max(names, key=len)) > 10:
                ax.tick_params(axis='x', rotation=45)
        
        plt.tight_layout()
        
        if save_path:
            plt.savefig(save_path, dpi=300, bbox_inches='tight')
            print(f"Comparison plot saved to {save_path}")
        
        plt.show()
    
    def generate_latex_table(self, results: List[MetricsResult], 
                            names: List[str]) -> str:
        """
        Generate LaTeX table for paper publication.
        """
        latex = "\\begin{table}[htbp]\n"
        latex += "\\centering\n"
        latex += "\\caption{Comparison of GNG Implementations}\n"
        latex += "\\label{tab:gng_comparison}\n"
        latex += "\\begin{tabular}{lcccccc}\n"
        latex += "\\hline\n"
        latex += "Implementation & QE & TE (\\%) & Memory (B) & Train (s) & Infer (ms) & Util (\\%) \\\\\n"
        latex += "\\hline\n"
        
        for name, result in zip(names, results):
            latex += f"{name} & "
            latex += f"{result.quantization_error:.4f} & "
            latex += f"{result.topological_error*100:.2f} & "
            latex += f"{result.memory_bytes} & "
            latex += f"{result.training_time_sec:.3f} & "
            latex += f"{result.inference_time_ms:.3f} & "
            latex += f"{result.node_utilization*100:.1f} \\\\\n"
        
        latex += "\\hline\n"
        latex += "\\end{tabular}\n"
        latex += "\\end{table}\n"
        
        return latex


def generate_test_datasets() -> Dict[str, np.ndarray]:
    """
    Generate standard test datasets for GNG evaluation.
    
    Returns:
        Dictionary of dataset name -> data array
    """
    datasets = {}
    
    # 1. Two Moons (classic GNG test)
    np.random.seed(42)
    n_samples = 200
    t = np.linspace(0, np.pi, n_samples // 2)
    moon1_x = np.cos(t)
    moon1_y = np.sin(t)
    moon2_x = 1 - np.cos(t)
    moon2_y = -np.sin(t) + 0.5
    
    noise = 0.1
    moon1 = np.column_stack([moon1_x, moon1_y]) + np.random.randn(n_samples // 2, 2) * noise
    moon2 = np.column_stack([moon2_x, moon2_y]) + np.random.randn(n_samples // 2, 2) * noise
    datasets['two_moons'] = np.vstack([moon1, moon2]).astype(np.float32)
    
    # 2. Gaussian Clusters
    np.random.seed(43)
    cluster1 = np.random.randn(100, 2) * 0.3 + np.array([1.0, 1.0])
    cluster2 = np.random.randn(100, 2) * 0.3 + np.array([-1.0, 1.0])
    cluster3 = np.random.randn(100, 2) * 0.3 + np.array([0.0, -1.0])
    datasets['gaussian_clusters'] = np.vstack([cluster1, cluster2, cluster3]).astype(np.float32)
    
    # 3. Uniform Square
    np.random.seed(44)
    datasets['uniform_square'] = np.random.uniform(-1, 1, (300, 2)).astype(np.float32)
    
    # 4. Ring
    np.random.seed(45)
    theta = np.random.uniform(0, 2*np.pi, 300)
    radius = 1.0 + np.random.randn(300) * 0.1
    ring_x = radius * np.cos(theta)
    ring_y = radius * np.sin(theta)
    datasets['ring'] = np.column_stack([ring_x, ring_y]).astype(np.float32)
    
    # Normalize all datasets to [0, 1]
    for name in datasets:
        data = datasets[name]
        data_min = data.min(axis=0)
        data_max = data.max(axis=0)
        datasets[name] = (data - data_min) / (data_max - data_min + 1e-8)
    
    return datasets


if __name__ == "__main__":
    print("GNG Metrics Evaluation Framework")
    print("=" * 60)
    
    # Import GNG implementations
    try:
        from gng_lite_fixed_point import GNGLite, GNGLiteConfig
        print("✓ GNG-Lite Fixed-Point implementation loaded")
    except ImportError as e:
        print(f"✗ Failed to load GNG-Lite: {e}")
        exit(1)
    
    # Generate test datasets
    print("\nGenerating test datasets...")
    datasets = generate_test_datasets()
    print(f"✓ Generated {len(datasets)} datasets")
    
    # Initialize evaluator
    evaluator = GNGMetricsEvaluator()
    
    # Test on Two Moons dataset
    print("\n" + "=" * 60)
    print("Evaluating on Two Moons Dataset")
    print("=" * 60)
    
    train_data = datasets['two_moons']
    test_data = datasets['two_moons']  # Same for demonstration
    
    results_list = []
    names_list = []
    
    # 1. Fixed-Point Version (memory-optimized)
    print("\n[1/2] Fixed-Point Implementation (Q16.16)")
    config_fixed = GNGLiteConfig(
        max_nodes=32,
        max_edges=64,
        feature_dim=2,
        use_fixed_point=True,
        lambda_=50
    )
    gng_fixed = GNGLite(config_fixed)
    result_fixed = evaluator.evaluate_full(gng_fixed, train_data, test_data, epochs=10)
    results_list.append(result_fixed)
    names_list.append("Fixed-Point")
    
    print(f"  Quantization Error: {result_fixed.quantization_error:.4f}")
    print(f"  Topological Error: {result_fixed.topological_error*100:.2f}%")
    print(f"  Memory Usage: {result_fixed.memory_bytes} bytes")
    print(f"  Training Time: {result_fixed.training_time_sec:.3f} sec")
    print(f"  Inference Time: {result_fixed.inference_time_ms:.3f} ms")
    print(f"  Nodes: {result_fixed.n_nodes}, Edges: {result_fixed.n_edges}")
    
    # 2. Float32 Version (baseline)
    print("\n[2/2] Float32 Implementation (Baseline)")
    config_float = GNGLiteConfig(
        max_nodes=32,
        max_edges=64,
        feature_dim=2,
        use_fixed_point=False,
        lambda_=50
    )
    gng_float = GNGLite(config_float)
    result_float = evaluator.evaluate_full(gng_float, train_data, test_data, epochs=10)
    results_list.append(result_float)
    names_list.append("Float32")
    
    print(f"  Quantization Error: {result_float.quantization_error:.4f}")
    print(f"  Topological Error: {result_float.topological_error*100:.2f}%")
    print(f"  Memory Usage: {result_float.memory_bytes} bytes")
    print(f"  Training Time: {result_float.training_time_sec:.3f} sec")
    print(f"  Inference Time: {result_float.inference_time_ms:.3f} ms")
    print(f"  Nodes: {result_float.n_nodes}, Edges: {result_float.n_edges}")
    
    # Comparison
    print("\n" + "=" * 60)
    print("COMPARISON SUMMARY")
    print("=" * 60)
    
    qe_diff = ((result_fixed.quantization_error - result_float.quantization_error) / 
               result_float.quantization_error * 100)
    mem_saving = ((result_float.memory_bytes - result_fixed.memory_bytes) / 
                  result_float.memory_bytes * 100)
    speed_diff = ((result_fixed.training_time_sec - result_float.training_time_sec) / 
                  result_float.training_time_sec * 100)
    
    print(f"\nAccuracy Impact:")
    print(f"  QE difference: {qe_diff:+.2f}%")
    print(f"  TE difference: {(result_fixed.topological_error - result_float.topological_error)*100:+.2f}%")
    
    print(f"\nResource Efficiency:")
    print(f"  Memory saving: {mem_saving:.1f}%")
    print(f"  Speed difference: {speed_diff:+.2f}%")
    
    # Generate comparison plot
    print("\nGenerating comparison plot...")
    evaluator.plot_comparison(results_list, names_list, 
                             save_path="gng_comparison.png")
    
    # Generate LaTeX table
    print("\nLaTeX Table:")
    print(evaluator.generate_latex_table(results_list, names_list))
    
    # Save results
    result_fixed.to_json("results_fixed_point.json")
    result_float.to_json("results_float32.json")
    print("\n✓ Results saved to JSON files")
    
    # Export trained network to C header
    print("\nExporting trained network to C header...")
    gng_fixed.export_to_c_header("gng_network_trained.h")
    
    print("\n" + "=" * 60)
    print("Evaluation Complete!")
    print("=" * 60)
