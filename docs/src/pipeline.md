# Statistics Pipeline & Streaming Accumulators

## Overview

Traditional discrete-event simulation frameworks collect raw arrays of all observation samples. For simulations with $10^7$ events, storing all sample timestamps causes massive memory allocation and cache thrashing.

`SimCore.jl` implements a zero-allocation, single-pass streaming reduction pipeline (`StatsPipeline`) combining four standard numerical algorithms:

1. **Welford's Algorithm (1962):** Numerically stable streaming mean and variance in $O(1)$ space.
2. **West's Weighted Algorithm (1979):** Time-weighted average system size ($L = \int Q(t) dt / T$) and server utilization.
3. **Rajan's Streaming Extrema:** Online tracking of minimum and maximum values without array storage.
4. **Jain-Chlamtac $P^2$ Algorithm (1985):** Streaming piece-wise parabolic quantile tracking without storing sample arrays.

---

## Streaming Collectors

| Collector | Metric Tracked | Algorithm | Space Complexity |
|---|---|---|---|
| `MeanVarCollector` | Mean, sample variance, std | Welford (1962) | $O(1)$ |
| `WeightedMeanCollector` | Time-weighted mean (L, utilization) | West (1979) | $O(1)$ |
| `ExtremaCollector` | Running min, running max | Online update | $O(1)$ |
| `QuantileCollector` | Dynamic quantiles ($P_{50}, P_{90}, P_{99}$) | Jain-Chlamtac $P^2$ (1985) | $O(1)$ (5 markers) |
| `CounterCollector` | Event counters, blocking totals | Integer register | $O(1)$ |

---

## The Welford Recurrence

For independent observations $x_1, x_2, \dots, x_n$, Welford's recurrence updates mean $M_k$ and sum of squared deviations $S_k$:

$$M_k = M_{k-1} + \frac{x_k - M_{k-1}}{k}$$

$$S_k = S_{k-1} + (x_k - M_{k-1})(x_k - M_k)$$

The sample variance is recovered directly as $s^2 = \frac{S_n}{n - 1}$ with zero loss of numerical precision.

---

## The $P^2$ Quantile Estimator

To estimate quantile $p$ (e.g. 95th percentile, $p = 0.95$) without sorting arrays, the $P^2$ algorithm maintains 5 marker heights $q_1 < q_2 < q_3 < q_4 < q_5$ with desired positions $n_i'$.

When a new observation $x$ arrives:
1. Markers are updated to bracket the new observation.
2. If a marker's actual position deviates from its ideal position $n_i'$ by $\ge 1$, its height is adjusted using piece-wise parabolic interpolation:

$$q_i \leftarrow q_i + \frac{d}{n_{i+1} - n_{i-1}} \left( (n_i - n_{i-1} + d) \frac{q_{i+1} - q_i}{n_{i+1} - n_i} + (n_{i+1} - n_i - d) \frac{q_i - q_{i-1}}{n_i - n_{i-1}} \right)$$

If parabolic interpolation violates monotonicity ($q_{i-1} < q_i < q_{i+1}$), linear interpolation is used as fallback.

---

## Using `StatsPipeline`

```julia
using SimCore

pipeline = StatsPipeline(warmup = WARMUP_FIXED, warmup_n = 5_000)

# In event loop:
record_arrival!(pipeline)
record_queue_length!(pipeline, current_sys_size, dt)
record_departure!(pipeline, wait_time, sojourn_time)

# Extract summary
sm = sim_summary(pipeline)
println("Mean queue length (L):    ", sm.L)
println("Mean sojourn time (W):    ", sm.W)
println("95th percentile sojourn:  ", sm.W_quantile)
println("Server utilization (ρ):   ", sm.utilization)
println("Throughput (λ_eff):       ", sm.throughput)
```
