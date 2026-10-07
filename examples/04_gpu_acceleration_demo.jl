# 04_gpu_acceleration_demo.jl — Vectorized Statistics on CPU/GPU
# Demonstrates hardware acceleration boundaries using SimCoreGPUExt

using SimCore
using Random
using Statistics

println("=== SimCore Example 4: Hardware-Accelerated Statistics ===")

# Generate 1,000,000 synthetic simulation metric samples
n_samples = 1_000_000
rng = MersenneTwister(99)
samples = randn(rng, Float64, n_samples) .* 2.5 .+ 10.0 # true mean = 10.0, true var = 6.25

println("Generated $(n_samples) post-simulation observable samples.")

# Check if hardware-accelerated extension is active
if SimCore._accel_available()
    println("\nHardware acceleration active (SimCoreGPUExt loaded via AcceleratedKernels & KernelAbstractions):")
    # Parallel reduction of mean and variance (works on CPU threads as well as CuArray / ROCArray / MtlArray)
    μ, var_val = gpu_mean_var(samples)
    println("  Accelerated Mean:     ", round(μ, digits=4), " (Target: 10.0)")
    println("  Accelerated Variance: ", round(var_val, digits=4), " (Target: 6.25)")

    # Parallel multi-bin histogram
    edges, counts = gpu_histogram(samples, 10; lo=0.0, hi=20.0)
    println("\nParallel Multi-Bin Histogram (gpu_histogram):")
    println("  Number of bins:        ", length(counts))
    println("  Total elements binned: ", sum(counts))
    println("  Bin counts sample:     ", counts[1:min(5, length(counts))])
else
    println("\nNotice: AcceleratedKernels/KernelAbstractions not in active standalone environment.")
    println("Standard CPU statistics execution:")
    println("  Sample Mean:     ", round(mean(samples), digits=4), " (Target: 10.0)")
    println("  Sample Variance: ", round(var(samples), digits=4), " (Target: 6.25)")
end

println("\nHardware Acceleration Boundary Takeaway:")
println("  - Discrete-event FEL queue and zone dispatch loops run sequentially on CPU.")
println("  - Post-simulation batch reductions and histogram streaming run on GPU/SIMD via SimCoreGPUExt.")
