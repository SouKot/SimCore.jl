# Hardware Acceleration & GPU Scope

## Architectural Scope Boundaries

Discrete-event simulation is inherently sequential and latency-sensitive: the Future Event List (FEL) relies on priority queue heaps where each event mutation depends on the state mutated by the preceding event. Attempting to parallelize discrete-event loops directly on GPUs introduces massive warp divergence and memory latency stalls.

`SimCore.jl` establishes strict, mathematically grounded boundaries:

```mermaid
flowchart LR
    subgraph CPU["CPU Cores & Threads (Low Latency)"]
        direction TB
        FEL["Future Event List (Heap)"] --> Dispatch["Zone Dispatch & Routing"]
        Dispatch --> State["Entity Kinematics & States"]
    end

    subgraph GPU["GPU / SIMD Acceleration (High Throughput)"]
        direction TB
        Reductions["Batch Parallel Reductions (Mean / Var)"]
        Histograms["Multi-Bin Histogram Kernels"]
        Replications["Independent Monte-Carlo Runs"]
    end

    State -.->|"Post-sim observable arrays"| GPU
```

---

## Extension: `SimCoreGPUExt`

Hardware acceleration is decoupled into an optional package extension:
- **Trigger Dependencies:** `KernelAbstractions.jl` and `AcceleratedKernels.jl`.
- **Backend Portability:** Runs across CPU threads, NVIDIA CUDA (`CuArray`), AMD ROCm (`ROCArray`), Apple Silicon Metal (`MtlArray`), and Intel oneAPI (`oneArray`).

### Accelerated Functions

1. **`gpu_mean_var(arr)`**: Computes the mean and unbiased sample variance in a single parallel reduction pass across millions of elements.
2. **`gpu_histogram(samples, nbins; lo, hi)`**: Computes parallel multi-bin frequency histograms directly on device memory without transferring large arrays back to CPU host.

```julia
using SimCore
using KernelAbstractions
using AcceleratedKernels
# using CUDA  # Uncomment to target NVIDIA GPUs

samples = randn(10_000_000)

if SimCore._accel_available()
    μ, var_val = gpu_mean_var(samples)
    edges, counts = gpu_histogram(samples, 20; lo = -3.0, hi = 3.0)
end
```
