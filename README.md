# SimCore.jl

[![CI](https://github.com/SouKot/SimCore.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/SouKot/SimCore.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://SouKot.github.io/SimCore.jl/stable/)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPLv3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Version](https://img.shields.io/badge/version-0.1.0-green.svg)](https://github.com/SouKot/SimCore.jl/releases)

**A minimal, zero-allocation simulation substrate in Julia providing discrete-event clocks, event scheduling, and online statistics.**

---

## 1. Problem Statement & Scope

Simulation models in operations research, industrial engineering, and queueing theory demand lightweight execution engines with predictable computational complexity and minimal memory overhead. `SimCore.jl` provides the core primitives required to construct discrete-event and agent-based simulation engines:

1. **Virtual Time Advancement (`SimClock`)**: Scaled simulation clock supporting stepped advancement, wall-clock synchronization, and real-time playback ratios.
2. **Event Scheduling (`SimEvent`, `CancellableEvent`)**: Base event interface with lazy cancellation support.
3. **Streaming Statistics (`StatsPipeline`)**: Online calculation of numerical moments, quantiles, and warmup convergence in $O(1)$ memory without storing raw trajectory histories.
4. **Hardware Acceleration Boundaries**: Explicit delineation between sequential discrete-event logic (CPU) and vectorized statistical reductions (GPU/SIMD).

---

## 2. Mathematical & Algorithmic Specifications

### 2.1 Online Statistical Moments (Welford's Algorithm)
To eliminate numerical cancellation when computing sample variance $\sigma^2$ across millions of arrivals, `StatsPipeline` implements Welford's one-pass recurrence:

$$\bar{x}_k = \bar{x}_{k-1} + \frac{x_k - \bar{x}_{k-1}}{k}$$

$$M_{2,k} = M_{2,k-1} + (x_k - \bar{x}_{k-1})(x_k - \bar{x}_k)$$

$$s^2 = \frac{M_{2,n}}{n - 1}$$

### 2.2 Streaming Quantile Estimation ($P^2$ Algorithm)
Tracking percentiles ($P_{50}$, $P_{95}$, $P_{99}$) of queue wait times without sorting arrays is implemented using the piecewise-parabolic $P^2$ algorithm (Jain & Chlamtac, 1985). Five marker heights adjust dynamically upon each observation, maintaining $O(1)$ memory footprint and $O(1)$ time per update.

### 2.3 Transient Warmup Detection (Welch Moving Average)
Steady-state queueing simulations require truncation of initialization bias. `WelchDetector` implements Welch's moving-average window procedure (Welch, 1983):

$$\bar{Y}_i(w) = \frac{1}{2w + 1} \sum_{s=-w}^{w} \bar{Y}_{i+s}$$

Warmup is flagged when relative deviation across consecutive moving windows falls below a pre-specified tolerance $\epsilon_{\text{warmup}}$.

---

## 3. Hardware Acceleration & GPU Scope

To prevent ambiguity regarding acceleration claims:

* **What runs on CPU**:
  * Event dispatch loop and priority queue state transitions.
  * Conditional routing logic and discrete state mutations.
  * These structures are inherently sequential and latency-sensitive; executing them on GPUs introduces thread divergence and PCIe overhead.

* **What can be accelerated via `SimCoreGPUExt`**:
  * Vectorized batch reduction of post-simulation observables (`gpu_mean_var`).
  * Parallel histogram generation across large sample buffers (`gpu_histogram`).
  * Monte Carlo batch sweeps executed via `AcceleratedKernels.jl` and `KernelAbstractions.jl`.
  * CPU multithreading fallback is always available when no GPU hardware is present.

---

## 4. Empirical Test Verification

`SimCore.jl` is validated using automated test suites executed across Julia 1.10 LTS through Julia 1.13:

* **Clock Fidelity**: Verified time advancement consistency under fixed and scaled multipliers.
* **Welford Invariance**: Equivalence to two-pass sample statistics within machine precision ($\epsilon < 10^{-14}$).
* **$P^2$ Convergence**: Quantile estimates verified against empirical distributions generated from known parametric samples.
* **Lazy Cancellation**: Verified $O(1)$ removal mechanics and queue stability under heavy cancellation workloads.

---

## 5. Quickstart

```julia
using SimCore

# Initialize a streaming statistics pipeline with Welch warmup detection
pipeline = StatsPipeline(warmup=WARMUP_WELCH, warmup_n=1000)

# Simulate arrival and departure updates
for i in 1:10_000
    record_arrival!(pipeline)
    sojourn_time = rand() * 2.0  # sample duration
    record_departure!(pipeline, 0.0, sojourn_time)
end

summary = sim_summary(pipeline)
println("Mean sojourn time: ", summary.W)
println("Estimated P95:     ", summary.W_p95)
```

---

## 6. Early-Stage Development Advisory (v0.1.0)

`SimCore.jl` is released under Semantic Versioning at **`v0.1.0`**. While core algorithms are mathematically verified and covered by test suites, the public API is under active development and may evolve in response to community usage. Feedback, issue reports, and mathematical validation contributions are welcomed via GitHub issues.

---

## 7. AI Pair-Programming & Human Oversight Disclosure

This package was designed and authored by human engineers in collaborative pair-programming with Google DeepMind's Antigravity assistant. Every algorithm, data structure, and boundary condition is verified against established numerical literature and validated via formal test assertions in [`test/runtests.jl`](test/runtests.jl).

---

## 8. License

`SimCore.jl` is licensed under the [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).
