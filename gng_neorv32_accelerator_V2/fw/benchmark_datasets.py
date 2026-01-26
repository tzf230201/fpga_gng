"""
Comprehensive Dataset Suite for GNG Benchmarking
================================================

15+ diverse datasets covering:
- 2D/3D synthetic patterns
- Real-world data
- High-dimensional embeddings
- Streaming/temporal data
- Imbalanced distributions
- Outlier scenarios

For robust algorithm comparison.
"""

import numpy as np
from typing import Dict, Tuple
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection


class DatasetGenerator:
    """Generate diverse test datasets for GNG evaluation."""
    
    @staticmethod
    def generate_all() -> Dict[str, np.ndarray]:
        """Generate all datasets."""
        datasets = {}
        
        # 2D Datasets
        datasets['two_moons'] = DatasetGenerator.two_moons()
        datasets['swiss_roll_2d'] = DatasetGenerator.swiss_roll_2d()
        datasets['circles'] = DatasetGenerator.concentric_circles()
        datasets['spiral'] = DatasetGenerator.spiral()
        datasets['gaussian_mix'] = DatasetGenerator.gaussian_mixture()
        datasets['grid'] = DatasetGenerator.grid_pattern()
        datasets['uniform'] = DatasetGenerator.uniform_square()
        datasets['anisotropic'] = DatasetGenerator.anisotropic_gaussian()
        
        # 3D Datasets
        datasets['sphere'] = DatasetGenerator.sphere_3d()
        datasets['torus'] = DatasetGenerator.torus_3d()
        
        # High-dimensional
        datasets['mnist_subset'] = DatasetGenerator.mnist_like_highdim()
        datasets['random_highdim'] = DatasetGenerator.random_highdim()
        
        # Special cases
        datasets['outliers'] = DatasetGenerator.with_outliers()
        datasets['imbalanced'] = DatasetGenerator.imbalanced_clusters()
        datasets['temporal'] = DatasetGenerator.temporal_drift()
        
        return datasets
    
    @staticmethod
    def two_moons(n_samples: int = 500, noise: float = 0.1) -> np.ndarray:
        """Classic two moons dataset."""
        np.random.seed(42)
        n_per_moon = n_samples // 2
        
        t = np.linspace(0, np.pi, n_per_moon)
        moon1_x = np.cos(t)
        moon1_y = np.sin(t)
        moon2_x = 1 - np.cos(t)
        moon2_y = -np.sin(t) + 0.5
        
        moon1 = np.column_stack([moon1_x, moon1_y]) + np.random.randn(n_per_moon, 2) * noise
        moon2 = np.column_stack([moon2_x, moon2_y]) + np.random.randn(n_per_moon, 2) * noise
        
        data = np.vstack([moon1, moon2])
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def swiss_roll_2d(n_samples: int = 500) -> np.ndarray:
        """2D projection of Swiss roll."""
        np.random.seed(43)
        t = 1.5 * np.pi * (1 + 2 * np.random.rand(n_samples))
        x = t * np.cos(t)
        y = t * np.sin(t)
        
        data = np.column_stack([x, y])
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def concentric_circles(n_samples: int = 500, n_circles: int = 3) -> np.ndarray:
        """Concentric circles with noise."""
        np.random.seed(44)
        data = []
        
        for i in range(n_circles):
            radius = (i + 1) / n_circles
            n_per_circle = n_samples // n_circles
            theta = np.random.uniform(0, 2*np.pi, n_per_circle)
            
            r = radius + np.random.randn(n_per_circle) * 0.05
            x = r * np.cos(theta)
            y = r * np.sin(theta)
            
            data.append(np.column_stack([x, y]))
        
        data = np.vstack(data)
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def spiral(n_samples: int = 500, n_arms: int = 2) -> np.ndarray:
        """Spiral patterns."""
        np.random.seed(45)
        data = []
        
        for arm in range(n_arms):
            n_per_arm = n_samples // n_arms
            t = np.linspace(0, 4*np.pi, n_per_arm)
            
            angle_offset = arm * 2 * np.pi / n_arms
            x = t * np.cos(t + angle_offset) / (4*np.pi)
            y = t * np.sin(t + angle_offset) / (4*np.pi)
            
            # Add noise
            x += np.random.randn(n_per_arm) * 0.05
            y += np.random.randn(n_per_arm) * 0.05
            
            data.append(np.column_stack([x, y]))
        
        data = np.vstack(data)
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def gaussian_mixture(n_samples: int = 600, n_clusters: int = 5) -> np.ndarray:
        """Gaussian mixture model."""
        np.random.seed(46)
        data = []
        
        # Random cluster centers
        centers = np.random.rand(n_clusters, 2)
        
        for center in centers:
            n_per_cluster = n_samples // n_clusters
            cluster = np.random.randn(n_per_cluster, 2) * 0.1 + center
            data.append(cluster)
        
        data = np.vstack(data)
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def grid_pattern(n_samples: int = 500, grid_size: int = 5) -> np.ndarray:
        """Regular grid with noise."""
        np.random.seed(47)
        
        x = np.linspace(0, 1, grid_size)
        y = np.linspace(0, 1, grid_size)
        xx, yy = np.meshgrid(x, y)
        
        grid_points = np.column_stack([xx.ravel(), yy.ravel()])
        
        # Sample around grid points
        data = []
        n_per_point = n_samples // len(grid_points)
        
        for point in grid_points:
            samples = np.random.randn(n_per_point, 2) * 0.03 + point
            data.append(samples)
        
        data = np.vstack(data)
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def uniform_square(n_samples: int = 500) -> np.ndarray:
        """Uniformly distributed in square."""
        np.random.seed(48)
        data = np.random.rand(n_samples, 2)
        return data
    
    @staticmethod
    def anisotropic_gaussian(n_samples: int = 500) -> np.ndarray:
        """Elongated Gaussian blobs."""
        np.random.seed(49)
        
        # Create correlated Gaussians
        mean = [0.5, 0.5]
        cov = [[0.1, 0.08], [0.08, 0.02]]  # Anisotropic
        
        data = np.random.multivariate_normal(mean, cov, n_samples)
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def sphere_3d(n_samples: int = 500) -> np.ndarray:
        """3D sphere surface."""
        np.random.seed(50)
        
        # Uniform sampling on sphere
        theta = np.random.uniform(0, 2*np.pi, n_samples)
        phi = np.arccos(2 * np.random.rand(n_samples) - 1)
        
        x = np.sin(phi) * np.cos(theta)
        y = np.sin(phi) * np.sin(theta)
        z = np.cos(phi)
        
        data = np.column_stack([x, y, z])
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def torus_3d(n_samples: int = 500, R: float = 1.0, r: float = 0.3) -> np.ndarray:
        """3D torus."""
        np.random.seed(51)
        
        theta = np.random.uniform(0, 2*np.pi, n_samples)
        phi = np.random.uniform(0, 2*np.pi, n_samples)
        
        x = (R + r * np.cos(phi)) * np.cos(theta)
        y = (R + r * np.cos(phi)) * np.sin(theta)
        z = r * np.sin(phi)
        
        data = np.column_stack([x, y, z])
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def mnist_like_highdim(n_samples: int = 500, n_dims: int = 64) -> np.ndarray:
        """Simulate high-dimensional MNIST-like data."""
        np.random.seed(52)
        
        # Create 10 "digit" clusters in high-dimensional space
        n_clusters = 10
        data = []
        
        for i in range(n_clusters):
            n_per_cluster = n_samples // n_clusters
            
            # Random cluster center
            center = np.random.randn(n_dims) * 0.5
            
            # Generate samples with structure
            cluster_samples = np.random.randn(n_per_cluster, n_dims) * 0.3 + center
            
            data.append(cluster_samples)
        
        data = np.vstack(data)
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def random_highdim(n_samples: int = 500, n_dims: int = 128) -> np.ndarray:
        """High-dimensional random data."""
        np.random.seed(53)
        data = np.random.randn(n_samples, n_dims) * 0.5 + 0.5
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def with_outliers(n_samples: int = 500, outlier_ratio: float = 0.05) -> np.ndarray:
        """Dataset with outliers."""
        np.random.seed(54)
        
        # Main cluster
        n_main = int(n_samples * (1 - outlier_ratio))
        main_data = np.random.randn(n_main, 2) * 0.2 + 0.5
        
        # Outliers
        n_outliers = n_samples - n_main
        outliers = np.random.rand(n_outliers, 2)
        
        data = np.vstack([main_data, outliers])
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def imbalanced_clusters(n_samples: int = 500) -> np.ndarray:
        """Clusters with very different sizes."""
        np.random.seed(55)
        
        # Large cluster (80%)
        n_large = int(n_samples * 0.8)
        large_cluster = np.random.randn(n_large, 2) * 0.15 + [0.3, 0.5]
        
        # Small cluster (20%)
        n_small = n_samples - n_large
        small_cluster = np.random.randn(n_small, 2) * 0.1 + [0.7, 0.5]
        
        data = np.vstack([large_cluster, small_cluster])
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def temporal_drift(n_samples: int = 500) -> np.ndarray:
        """Simulated concept drift over time."""
        np.random.seed(56)
        
        data = []
        n_per_segment = n_samples // 3
        
        # Segment 1: cluster at [0.3, 0.3]
        seg1 = np.random.randn(n_per_segment, 2) * 0.1 + [0.3, 0.3]
        
        # Segment 2: transition
        seg2 = np.random.randn(n_per_segment, 2) * 0.1 + [0.5, 0.5]
        
        # Segment 3: cluster at [0.7, 0.7]
        seg3 = np.random.randn(n_samples - 2*n_per_segment, 2) * 0.1 + [0.7, 0.7]
        
        data = np.vstack([seg1, seg2, seg3])
        return DatasetGenerator._normalize(data)
    
    @staticmethod
    def _normalize(data: np.ndarray) -> np.ndarray:
        """Normalize to [0, 1] range per dimension."""
        data_min = data.min(axis=0)
        data_max = data.max(axis=0)
        data_range = data_max - data_min
        data_range[data_range == 0] = 1  # Avoid division by zero
        
        normalized = (data - data_min) / data_range
        return normalized.astype(np.float32)
    
    @staticmethod
    def visualize_all_datasets(datasets: Dict[str, np.ndarray], save_path: str = None):
        """Visualize all 2D datasets."""
        
        # Filter 2D datasets
        datasets_2d = {name: data for name, data in datasets.items() if data.shape[1] == 2}
        
        n_datasets = len(datasets_2d)
        n_cols = 4
        n_rows = (n_datasets + n_cols - 1) // n_cols
        
        fig, axes = plt.subplots(n_rows, n_cols, figsize=(16, 4*n_rows))
        axes = axes.flatten() if n_datasets > 1 else [axes]
        
        for idx, (name, data) in enumerate(datasets_2d.items()):
            ax = axes[idx]
            ax.scatter(data[:, 0], data[:, 1], alpha=0.5, s=10)
            ax.set_title(f'{name.replace("_", " ").title()}\n({len(data)} samples)',
                        fontsize=10)
            ax.set_xlim(-0.05, 1.05)
            ax.set_ylim(-0.05, 1.05)
            ax.grid(True, alpha=0.3)
            ax.set_aspect('equal')
        
        # Hide unused subplots
        for idx in range(n_datasets, len(axes)):
            axes[idx].axis('off')
        
        plt.tight_layout()
        
        if save_path:
            plt.savefig(save_path, dpi=300, bbox_inches='tight')
            print(f"Saved visualization to {save_path}")
        
        plt.show()
    
    @staticmethod
    def get_dataset_statistics(datasets: Dict[str, np.ndarray]) -> Dict:
        """Calculate statistics for all datasets."""
        stats = {}
        
        for name, data in datasets.items():
            stats[name] = {
                'n_samples': len(data),
                'n_dims': data.shape[1],
                'mean': np.mean(data, axis=0).tolist(),
                'std': np.std(data, axis=0).tolist(),
                'min': np.min(data, axis=0).tolist(),
                'max': np.max(data, axis=0).tolist(),
                'memory_kb': data.nbytes / 1024
            }
        
        return stats


if __name__ == "__main__":
    print("=" * 80)
    print("COMPREHENSIVE DATASET GENERATION")
    print("=" * 80)
    
    print("\nGenerating all datasets...")
    datasets = DatasetGenerator.generate_all()
    print(f"✓ Generated {len(datasets)} datasets")
    
    print("\nDataset Statistics:")
    print("-" * 80)
    print(f"{'Dataset':<20} {'Samples':>10} {'Dims':>8} {'Memory':>12}")
    print("-" * 80)
    
    for name, data in datasets.items():
        print(f"{name:<20} {len(data):>10} {data.shape[1]:>8} {data.nbytes/1024:>10.2f} KB")
    
    total_samples = sum(len(d) for d in datasets.values())
    total_memory = sum(d.nbytes for d in datasets.values()) / 1024
    
    print("-" * 80)
    print(f"{'TOTAL':<20} {total_samples:>10} {'-':>8} {total_memory:>10.2f} KB")
    print("-" * 80)
    
    print("\nVisualizing 2D datasets...")
    DatasetGenerator.visualize_all_datasets(datasets, 'all_datasets_visualization.png')
    
    print("\n" + "=" * 80)
    print("DATASET CHARACTERISTICS")
    print("=" * 80)
    print("""
    EASY (Good for testing basic functionality):
    - uniform, grid
    
    MEDIUM (Standard benchmarks):
    - two_moons, gaussian_mix, circles, spiral
    
    HARD (Challenge algorithms):
    - swiss_roll_2d, anisotropic, outliers, imbalanced
    
    3D (Spatial reasoning):
    - sphere, torus
    
    HIGH-DIM (Scalability):
    - mnist_subset (64D), random_highdim (128D)
    
    SPECIAL (Edge cases):
    - temporal (concept drift)
    - outliers (robustness)
    - imbalanced (class imbalance)
    """)
    
    print("=" * 80)
    print("Ready for comprehensive algorithm benchmarking!")
    print("=" * 80)
