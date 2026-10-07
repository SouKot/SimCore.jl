# 02_welch_warmup_detection.jl — Welch Moving-Average Warmup Detection
# Demonstrates statistical detection of steady state to eliminate initialization bias.

using SimCore
using Random

println("=== SimCore Example 2: Welch Warmup Detection ===")

# Create a WelchDetector with window size w = 50 and convergence threshold
detector = WelchDetector(window_size = 50, threshold = 0.05)

rng = MersenneTwister(42)
t_warmup = 0
n_samples = 2_000

println("Feeding transient signal (decaying exponential bias + steady-state noise)...")

for i in 1:n_samples
    # Signal: transient decay 10.0 * exp(-i / 150) + steady-state mean 2.0 + noise
    transient_bias = 10.0 * exp(-i / 150.0)
    steady_val = 2.0 + randn(rng) * 0.5
    y_i = transient_bias + steady_val

    # Update Welch detector with observation
    update!(detector, y_i)

    if warmup_complete(detector) && t_warmup == 0
        global t_warmup = i
        println(">>> Steady state detected at observation $(i)! <<<")
        break
    end
end

if t_warmup > 0
    println("Transient warmup duration: $t_warmup observations.")
    println("Observations before $t_warmup can be discarded to prevent initialization bias.")
else
    println("Warmup not completed within $n_samples samples.")
end
