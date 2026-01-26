"""
Run Complete GNG Experiments for IJCNN Paper
============================================

This script orchestrates all experiments:
1. Memory efficiency comparison (Fixed vs Float)
2. Accuracy evaluation on multiple datasets
3. Performance benchmarking
4. Generate all figures for paper
5. Export results tables

Run this to reproduce all paper results.
"""

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Circle
from matplotlib.collections import LineCollection
import time
import json
from pathlib import Path

# Import our implementations
from gng_lite_fixed_point import GNGLite, GNGLiteConfig
from experiment_metrics import (
    GNGMetricsEvaluator, 
    MetricsResult,
    generate_test_datasets
)


class IJCNNExperimentRunner:
    """Complete experiment runner for IJCNN paper."""
    
    def __init__(self, output_dir: str = "paper_results"):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(exist_ok=True)
        
        self.evaluator = GNGMetricsEvaluator()
        self.all_results = {}
        
    def run_all_experiments(self):
        """Run all experiments for the paper."""
        print("=" * 70)
        print("IJCNN 2026 - GNG-Lite Experiments")
        print("=" * 70)
        
        # 1. Generate datasets
        print("\n[1/5] Generating test datasets...")
        datasets = generate_test_datasets()
        print(f"✓ Generated {len(datasets)} datasets")
        
        # 2. Memory efficiency comparison
        print("\n[2/5] Running memory efficiency comparison...")
        self.memory_efficiency_experiment(datasets['two_moons'])
        
        # 3. Multi-dataset evaluation
        print("\n[3/5] Evaluating on all datasets...")
        self.multi_dataset_experiment(datasets)
        
        # 4. Hyperparameter sensitivity
        print("\n[4/5] Running hyperparameter sensitivity analysis...")
        self.hyperparameter_sensitivity(datasets['two_moons'])
        
        # 5. Generate all figures and tables
        print("\n[5/5] Generating figures and tables...")
        self.generate_paper_figures()
        self.generate_latex_tables()
        
        print("\n" + "=" * 70)
        print("All experiments completed!")
        print(f"Results saved to: {self.output_dir.absolute()}")
        print("=" * 70)
    
    def memory_efficiency_experiment(self, data: np.ndarray):
        """Compare memory usage: Float32 vs Fixed-Point."""
        print("\n  Memory Efficiency Comparison")
        print("  " + "-" * 60)
        
        results = []
        names = []
        configs = [
            ("Fixed-Point (32 nodes)", GNGLiteConfig(
                max_nodes=32, max_edges=64, use_fixed_point=True, lambda_=50
            )),
            ("Float32 (32 nodes)", GNGLiteConfig(
                max_nodes=32, max_edges=64, use_fixed_point=False, lambda_=50
            )),
            ("Fixed-Point (16 nodes)", GNGLiteConfig(
                max_nodes=16, max_edges=32, use_fixed_point=True, lambda_=50
            )),
        ]
        
        for name, config in configs:
            print(f"\n  Testing: {name}")
            gng = GNGLite(config)
            result = self.evaluator.evaluate_full(gng, data, data, epochs=10)
            results.append(result)
            names.append(name)
            
            print(f"    Memory: {result.memory_bytes} bytes")
            print(f"    QE: {result.quantization_error:.4f}")
            print(f"    Nodes: {result.n_nodes}")
        
        self.all_results['memory_comparison'] = {
            'results': results,
            'names': names
        }
        
        # Save results
        with open(self.output_dir / "memory_comparison.json", 'w') as f:
            json.dump({
                'names': names,
                'memory_bytes': [r.memory_bytes for r in results],
                'qe': [r.quantization_error for r in results],
                'te': [r.topological_error for r in results],
            }, f, indent=2)
        
        print(f"\n  ✓ Memory comparison saved")
    
    def multi_dataset_experiment(self, datasets: dict):
        """Evaluate on all datasets."""
        print("\n  Multi-Dataset Evaluation")
        print("  " + "-" * 60)
        
        results_by_dataset = {}
        
        for dataset_name, data in datasets.items():
            print(f"\n  Dataset: {dataset_name} ({len(data)} samples)")
            
            results_fixed = []
            results_float = []
            
            # Fixed-Point
            config_fixed = GNGLiteConfig(
                max_nodes=32, max_edges=64, use_fixed_point=True, lambda_=50
            )
            gng_fixed = GNGLite(config_fixed)
            result_fixed = self.evaluator.evaluate_full(
                gng_fixed, data, data, epochs=10
            )
            
            # Float32
            config_float = GNGLiteConfig(
                max_nodes=32, max_edges=64, use_fixed_point=False, lambda_=50
            )
            gng_float = GNGLite(config_float)
            result_float = self.evaluator.evaluate_full(
                gng_float, data, data, epochs=10
            )
            
            print(f"    Fixed-Point: QE={result_fixed.quantization_error:.4f}, "
                  f"TE={result_fixed.topological_error*100:.2f}%")
            print(f"    Float32:     QE={result_float.quantization_error:.4f}, "
                  f"TE={result_float.topological_error*100:.2f}%")
            
            # Calculate differences
            qe_diff = ((result_fixed.quantization_error - result_float.quantization_error) 
                      / result_float.quantization_error * 100)
            te_diff = (result_fixed.topological_error - result_float.topological_error) * 100
            mem_saving = ((result_float.memory_bytes - result_fixed.memory_bytes)
                         / result_float.memory_bytes * 100)
            
            print(f"    Difference:  QE={qe_diff:+.2f}%, TE={te_diff:+.2f}pp, "
                  f"Mem=-{mem_saving:.1f}%")
            
            results_by_dataset[dataset_name] = {
                'fixed': result_fixed,
                'float': result_float,
                'data': data,
                'gng_fixed': gng_fixed,
                'gng_float': gng_float,
            }
        
        self.all_results['multi_dataset'] = results_by_dataset
        
        # Save summary
        summary = {}
        for name, res in results_by_dataset.items():
            summary[name] = {
                'fixed_qe': res['fixed'].quantization_error,
                'float_qe': res['float'].quantization_error,
                'fixed_te': res['fixed'].topological_error,
                'float_te': res['float'].topological_error,
                'fixed_mem': res['fixed'].memory_bytes,
                'float_mem': res['float'].memory_bytes,
            }
        
        with open(self.output_dir / "multi_dataset_results.json", 'w') as f:
            json.dump(summary, f, indent=2)
        
        print(f"\n  ✓ Multi-dataset results saved")
    
    def hyperparameter_sensitivity(self, data: np.ndarray):
        """Test different hyperparameter configurations."""
        print("\n  Hyperparameter Sensitivity Analysis")
        print("  " + "-" * 60)
        
        # Test different max_nodes values
        node_counts = [8, 16, 32, 48, 64]
        results = []
        
        for max_nodes in node_counts:
            print(f"\n  Testing max_nodes={max_nodes}")
            config = GNGLiteConfig(
                max_nodes=max_nodes,
                max_edges=max_nodes * 2,
                use_fixed_point=True,
                lambda_=50
            )
            gng = GNGLite(config)
            result = self.evaluator.evaluate_full(gng, data, data, epochs=10)
            results.append(result)
            
            print(f"    Nodes used: {result.n_nodes}/{max_nodes}")
            print(f"    QE: {result.quantization_error:.4f}")
            print(f"    Memory: {result.memory_bytes} bytes")
        
        self.all_results['hyperparameter_sensitivity'] = {
            'node_counts': node_counts,
            'results': results
        }
        
        # Save results
        with open(self.output_dir / "hyperparameter_sensitivity.json", 'w') as f:
            json.dump({
                'max_nodes': node_counts,
                'qe': [r.quantization_error for r in results],
                'te': [r.topological_error for r in results],
                'memory': [r.memory_bytes for r in results],
                'nodes_used': [r.n_nodes for r in results],
            }, f, indent=2)
        
        print(f"\n  ✓ Hyperparameter sensitivity saved")
    
    def generate_paper_figures(self):
        """Generate all figures for the paper."""
        print("\n  Generating Figures")
        print("  " + "-" * 60)
        
        # Figure 1: Network visualization on Two Moons
        self._plot_network_visualization()
        
        # Figure 2: Memory comparison bar chart
        self._plot_memory_comparison()
        
        # Figure 3: Multi-dataset accuracy comparison
        self._plot_multi_dataset_accuracy()
        
        # Figure 4: Hyperparameter sensitivity
        self._plot_hyperparameter_sensitivity()
        
        # Figure 5: Training convergence
        self._plot_training_convergence()
        
        print(f"  ✓ All figures saved to {self.output_dir}")
    
    def _plot_network_visualization(self):
        """Figure 1: Visualize trained GNG network on Two Moons."""
        if 'multi_dataset' not in self.all_results:
            return
        
        res = self.all_results['multi_dataset']['two_moons']
        data = res['data']
        gng = res['gng_fixed']
        
        fig, axes = plt.subplots(1, 2, figsize=(12, 5))
        
        # Fixed-Point
        ax = axes[0]
        ax.scatter(data[:, 0], data[:, 1], alpha=0.3, s=10, c='gray', label='Data')
        weights = gng.get_weights_as_float()
        edges = gng.get_edges_as_list()
        
        # Draw edges
        segments = []
        for e1, e2 in edges:
            segments.append([weights[e1], weights[e2]])
        lc = LineCollection(segments, colors='blue', linewidths=1, alpha=0.6)
        ax.add_collection(lc)
        
        # Draw nodes
        ax.scatter(weights[:, 0], weights[:, 1], c='red', s=100, 
                  marker='o', edgecolors='black', linewidths=1.5,
                  label='Nodes', zorder=10)
        
        ax.set_title(f'Fixed-Point GNG\n({gng.n_nodes} nodes, {gng.n_edges} edges)', 
                    fontsize=12)
        ax.set_xlabel('Feature 1')
        ax.set_ylabel('Feature 2')
        ax.legend()
        ax.grid(True, alpha=0.3)
        ax.set_xlim(-0.1, 1.1)
        ax.set_ylim(-0.1, 1.1)
        
        # Float32
        gng_float = res['gng_float']
        ax = axes[1]
        ax.scatter(data[:, 0], data[:, 1], alpha=0.3, s=10, c='gray', label='Data')
        weights = gng_float.get_weights_as_float()
        edges = gng_float.get_edges_as_list()
        
        # Draw edges
        segments = []
        for e1, e2 in edges:
            segments.append([weights[e1], weights[e2]])
        lc = LineCollection(segments, colors='blue', linewidths=1, alpha=0.6)
        ax.add_collection(lc)
        
        # Draw nodes
        ax.scatter(weights[:, 0], weights[:, 1], c='red', s=100,
                  marker='o', edgecolors='black', linewidths=1.5,
                  label='Nodes', zorder=10)
        
        ax.set_title(f'Float32 GNG (Baseline)\n({gng_float.n_nodes} nodes, {gng_float.n_edges} edges)',
                    fontsize=12)
        ax.set_xlabel('Feature 1')
        ax.set_ylabel('Feature 2')
        ax.legend()
        ax.grid(True, alpha=0.3)
        ax.set_xlim(-0.1, 1.1)
        ax.set_ylim(-0.1, 1.1)
        
        plt.tight_layout()
        plt.savefig(self.output_dir / "fig1_network_visualization.png", dpi=300)
        plt.close()
        print("    ✓ Figure 1: Network visualization")
    
    def _plot_memory_comparison(self):
        """Figure 2: Memory usage comparison."""
        if 'memory_comparison' not in self.all_results:
            return
        
        data = self.all_results['memory_comparison']
        names = data['names']
        results = data['results']
        
        fig, ax = plt.subplots(figsize=(10, 6))
        
        x = np.arange(len(names))
        memory = [r.memory_bytes for r in results]
        
        colors = ['green' if 'Fixed' in n else 'blue' for n in names]
        bars = ax.bar(x, memory, color=colors, alpha=0.7, edgecolor='black')
        
        # Add value labels
        for i, (bar, mem) in enumerate(zip(bars, memory)):
            height = bar.get_height()
            ax.text(bar.get_x() + bar.get_width()/2., height,
                   f'{mem}B\n({mem/1024:.2f}KB)',
                   ha='center', va='bottom', fontsize=10)
        
        ax.set_ylabel('Memory Usage (bytes)', fontsize=12)
        ax.set_title('Memory Footprint Comparison', fontsize=14, fontweight='bold')
        ax.set_xticks(x)
        ax.set_xticklabels(names, rotation=15, ha='right')
        ax.grid(axis='y', alpha=0.3)
        
        plt.tight_layout()
        plt.savefig(self.output_dir / "fig2_memory_comparison.png", dpi=300)
        plt.close()
        print("    ✓ Figure 2: Memory comparison")
    
    def _plot_multi_dataset_accuracy(self):
        """Figure 3: Accuracy across datasets."""
        if 'multi_dataset' not in self.all_results:
            return
        
        datasets = self.all_results['multi_dataset']
        
        fig, axes = plt.subplots(1, 2, figsize=(14, 5))
        
        names = list(datasets.keys())
        qe_fixed = [datasets[n]['fixed'].quantization_error for n in names]
        qe_float = [datasets[n]['float'].quantization_error for n in names]
        te_fixed = [datasets[n]['fixed'].topological_error * 100 for n in names]
        te_float = [datasets[n]['float'].topological_error * 100 for n in names]
        
        x = np.arange(len(names))
        width = 0.35
        
        # QE comparison
        ax = axes[0]
        ax.bar(x - width/2, qe_float, width, label='Float32', color='blue', alpha=0.7)
        ax.bar(x + width/2, qe_fixed, width, label='Fixed-Point', color='green', alpha=0.7)
        ax.set_ylabel('Quantization Error', fontsize=12)
        ax.set_title('Quantization Error by Dataset', fontsize=13, fontweight='bold')
        ax.set_xticks(x)
        ax.set_xticklabels([n.replace('_', ' ').title() for n in names], rotation=20, ha='right')
        ax.legend()
        ax.grid(axis='y', alpha=0.3)
        
        # TE comparison
        ax = axes[1]
        ax.bar(x - width/2, te_float, width, label='Float32', color='blue', alpha=0.7)
        ax.bar(x + width/2, te_fixed, width, label='Fixed-Point', color='green', alpha=0.7)
        ax.set_ylabel('Topological Error (%)', fontsize=12)
        ax.set_title('Topological Error by Dataset', fontsize=13, fontweight='bold')
        ax.set_xticks(x)
        ax.set_xticklabels([n.replace('_', ' ').title() for n in names], rotation=20, ha='right')
        ax.legend()
        ax.grid(axis='y', alpha=0.3)
        
        plt.tight_layout()
        plt.savefig(self.output_dir / "fig3_multi_dataset_accuracy.png", dpi=300)
        plt.close()
        print("    ✓ Figure 3: Multi-dataset accuracy")
    
    def _plot_hyperparameter_sensitivity(self):
        """Figure 4: Hyperparameter sensitivity."""
        if 'hyperparameter_sensitivity' not in self.all_results:
            return
        
        data = self.all_results['hyperparameter_sensitivity']
        node_counts = data['node_counts']
        results = data['results']
        
        fig, axes = plt.subplots(1, 3, figsize=(15, 4))
        
        qe = [r.quantization_error for r in results]
        memory = [r.memory_bytes for r in results]
        nodes_used = [r.n_nodes for r in results]
        
        # QE vs max_nodes
        axes[0].plot(node_counts, qe, marker='o', linewidth=2, markersize=8, color='blue')
        axes[0].set_xlabel('Max Nodes', fontsize=11)
        axes[0].set_ylabel('Quantization Error', fontsize=11)
        axes[0].set_title('Accuracy vs Network Size', fontsize=12, fontweight='bold')
        axes[0].grid(True, alpha=0.3)
        
        # Memory vs max_nodes
        axes[1].plot(node_counts, memory, marker='s', linewidth=2, markersize=8, color='green')
        axes[1].set_xlabel('Max Nodes', fontsize=11)
        axes[1].set_ylabel('Memory (bytes)', fontsize=11)
        axes[1].set_title('Memory vs Network Size', fontsize=12, fontweight='bold')
        axes[1].grid(True, alpha=0.3)
        
        # Nodes actually used
        axes[2].bar(node_counts, nodes_used, color='orange', alpha=0.7, edgecolor='black')
        axes[2].plot(node_counts, node_counts, '--', color='red', label='Maximum', linewidth=2)
        axes[2].set_xlabel('Max Nodes', fontsize=11)
        axes[2].set_ylabel('Nodes Used', fontsize=11)
        axes[2].set_title('Node Utilization', fontsize=12, fontweight='bold')
        axes[2].legend()
        axes[2].grid(True, alpha=0.3)
        
        plt.tight_layout()
        plt.savefig(self.output_dir / "fig4_hyperparameter_sensitivity.png", dpi=300)
        plt.close()
        print("    ✓ Figure 4: Hyperparameter sensitivity")
    
    def _plot_training_convergence(self):
        """Figure 5: Training convergence over epochs."""
        if 'multi_dataset' not in self.all_results:
            return
        
        # Train fresh models and track QE over epochs
        data = generate_test_datasets()['two_moons']
        
        epochs_list = range(1, 21)
        qe_fixed_history = []
        qe_float_history = []
        
        print("    Training models for convergence plot...")
        
        for epoch in epochs_list:
            # Fixed-point
            config_fixed = GNGLiteConfig(
                max_nodes=32, max_edges=64, use_fixed_point=True, lambda_=50
            )
            gng_fixed = GNGLite(config_fixed)
            gng_fixed.train(data, epochs=epoch)
            qe = self.evaluator.quantization_error(gng_fixed, data)
            qe_fixed_history.append(qe)
            
            # Float32
            config_float = GNGLiteConfig(
                max_nodes=32, max_edges=64, use_fixed_point=False, lambda_=50
            )
            gng_float = GNGLite(config_float)
            gng_float.train(data, epochs=epoch)
            qe = self.evaluator.quantization_error(gng_float, data)
            qe_float_history.append(qe)
        
        fig, ax = plt.subplots(figsize=(10, 6))
        
        ax.plot(epochs_list, qe_float_history, marker='o', linewidth=2, 
               markersize=6, label='Float32', color='blue')
        ax.plot(epochs_list, qe_fixed_history, marker='s', linewidth=2,
               markersize=6, label='Fixed-Point', color='green')
        
        ax.set_xlabel('Training Epochs', fontsize=12)
        ax.set_ylabel('Quantization Error', fontsize=12)
        ax.set_title('Training Convergence Comparison', fontsize=14, fontweight='bold')
        ax.legend(fontsize=11)
        ax.grid(True, alpha=0.3)
        
        plt.tight_layout()
        plt.savefig(self.output_dir / "fig5_training_convergence.png", dpi=300)
        plt.close()
        print("    ✓ Figure 5: Training convergence")
    
    def generate_latex_tables(self):
        """Generate LaTeX tables for paper."""
        print("\n  Generating LaTeX Tables")
        print("  " + "-" * 60)
        
        output_file = self.output_dir / "latex_tables.tex"
        
        with open(output_file, 'w') as f:
            f.write("% Auto-generated LaTeX tables for IJCNN paper\n\n")
            
            # Table 1: Multi-dataset comparison
            if 'multi_dataset' in self.all_results:
                f.write(self._generate_multi_dataset_table())
                f.write("\n\n")
            
            # Table 2: Memory efficiency
            if 'memory_comparison' in self.all_results:
                f.write(self._generate_memory_table())
                f.write("\n\n")
            
            # Table 3: Hyperparameter sensitivity
            if 'hyperparameter_sensitivity' in self.all_results:
                f.write(self._generate_hyperparameter_table())
        
        print(f"    ✓ LaTeX tables saved to {output_file}")
    
    def _generate_multi_dataset_table(self) -> str:
        """Generate Table 1: Multi-dataset results."""
        datasets = self.all_results['multi_dataset']
        
        latex = "% Table 1: Accuracy Comparison Across Datasets\n"
        latex += "\\begin{table}[htbp]\n"
        latex += "\\centering\n"
        latex += "\\caption{Quantization and Topological Errors on Standard Benchmarks}\n"
        latex += "\\label{tab:accuracy_comparison}\n"
        latex += "\\begin{tabular}{lccccc}\n"
        latex += "\\hline\n"
        latex += "\\textbf{Dataset} & \\textbf{Float32 QE} & \\textbf{Fixed QE} & \\textbf{QE Diff} & \\textbf{Float32 TE} & \\textbf{Fixed TE} \\\\\n"
        latex += "\\hline\n"
        
        for name, res in datasets.items():
            display_name = name.replace('_', ' ').title()
            qe_float = res['float'].quantization_error
            qe_fixed = res['fixed'].quantization_error
            qe_diff = ((qe_fixed - qe_float) / qe_float * 100)
            te_float = res['float'].topological_error * 100
            te_fixed = res['fixed'].topological_error * 100
            
            latex += f"{display_name} & "
            latex += f"{qe_float:.4f} & {qe_fixed:.4f} & "
            latex += f"{qe_diff:+.2f}\\% & "
            latex += f"{te_float:.1f}\\% & {te_fixed:.1f}\\% \\\\\n"
        
        latex += "\\hline\n"
        latex += "\\end{tabular}\n"
        latex += "\\end{table}\n"
        
        return latex
    
    def _generate_memory_table(self) -> str:
        """Generate Table 2: Memory efficiency."""
        data = self.all_results['memory_comparison']
        
        latex = "% Table 2: Memory Efficiency\n"
        latex += "\\begin{table}[htbp]\n"
        latex += "\\centering\n"
        latex += "\\caption{Memory Footprint Comparison}\n"
        latex += "\\label{tab:memory_comparison}\n"
        latex += "\\begin{tabular}{lcccc}\n"
        latex += "\\hline\n"
        latex += "\\textbf{Configuration} & \\textbf{Nodes} & \\textbf{Edges} & \\textbf{Memory (B)} & \\textbf{Memory (KB)} \\\\\n"
        latex += "\\hline\n"
        
        for name, result in zip(data['names'], data['results']):
            latex += f"{name} & "
            latex += f"{result.n_nodes} & {result.n_edges} & "
            latex += f"{result.memory_bytes} & {result.memory_bytes/1024:.2f} \\\\\n"
        
        latex += "\\hline\n"
        latex += "\\end{tabular}\n"
        latex += "\\end{table}\n"
        
        return latex
    
    def _generate_hyperparameter_table(self) -> str:
        """Generate Table 3: Hyperparameter sensitivity."""
        data = self.all_results['hyperparameter_sensitivity']
        
        latex = "% Table 3: Hyperparameter Sensitivity\n"
        latex += "\\begin{table}[htbp]\n"
        latex += "\\centering\n"
        latex += "\\caption{Effect of Maximum Nodes on Performance}\n"
        latex += "\\label{tab:hyperparameter}\n"
        latex += "\\begin{tabular}{lccccc}\n"
        latex += "\\hline\n"
        latex += "\\textbf{Max Nodes} & \\textbf{Used} & \\textbf{QE} & \\textbf{TE (\\%)} & \\textbf{Memory (B)} & \\textbf{Train (s)} \\\\\n"
        latex += "\\hline\n"
        
        for max_n, result in zip(data['node_counts'], data['results']):
            latex += f"{max_n} & {result.n_nodes} & "
            latex += f"{result.quantization_error:.4f} & "
            latex += f"{result.topological_error*100:.1f} & "
            latex += f"{result.memory_bytes} & "
            latex += f"{result.training_time_sec:.3f} \\\\\n"
        
        latex += "\\hline\n"
        latex += "\\end{tabular}\n"
        latex += "\\end{table}\n"
        
        return latex


if __name__ == "__main__":
    runner = IJCNNExperimentRunner(output_dir="paper_results")
    runner.run_all_experiments()
    
    print("\n" + "=" * 70)
    print("EXPERIMENT SUMMARY")
    print("=" * 70)
    print("\nGenerated Files:")
    print("  • Figures (PNG, 300 DPI):")
    print("    - fig1_network_visualization.png")
    print("    - fig2_memory_comparison.png")
    print("    - fig3_multi_dataset_accuracy.png")
    print("    - fig4_hyperparameter_sensitivity.png")
    print("    - fig5_training_convergence.png")
    print("\n  • Tables (LaTeX):")
    print("    - latex_tables.tex")
    print("\n  • Data (JSON):")
    print("    - memory_comparison.json")
    print("    - multi_dataset_results.json")
    print("    - hyperparameter_sensitivity.json")
    print("\nNext Steps:")
    print("  1. Review generated figures in paper_results/")
    print("  2. Copy LaTeX tables to your paper")
    print("  3. Run on FPGA hardware for hardware validation section")
    print("  4. Update IJCNN_2026_Report.md with actual results")
    print("\n" + "=" * 70)
