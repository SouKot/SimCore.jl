# Warmup & Transient Detection

## The Initialization Bias Problem

Discrete-event simulations typically initialize in an empty and idle state ($L(0) = 0$). For steady-state analysis, observations collected during the transient phase bias estimators away from their true ergodic means.

Discarding transient observations is standard practice. `SimCore.jl` provides both fixed-horizon warmup and automated online steady-state detection based on **Welch's Moving Average Procedure** (Welch 1983).

---

## Welch Detector (`WelchDetector`)

The `WelchDetector` computes a moving average of window size $w$ across streaming observations $y_i$. It monitors the relative change across successive windows:

$$\bar{y}_k = \frac{1}{w} \sum_{j=(k-1)w+1}^{kw} y_j$$

Steady state is flagged when the relative change across consecutive windows falls below threshold $\epsilon$:

$$\frac{|\bar{y}_k - \bar{y}_{k-1}|}{\max(|\bar{y}_{k-1}|, 10^{-6})} < \epsilon$$

```julia
using SimCore

# Window size w = 100, threshold ε = 0.05 (5%), min observations = 500
detector = WelchDetector(window_size = 100, threshold = 0.05, min_samples = 500)

for (i, y) in enumerate(observations)
    update!(detector, y)
    if warmup_complete(detector)
        println("Steady state reached at observation $i")
        break
    end
end
```

---

## Warmup Policies in Pipelines

`StatsPipeline` supports three warmup modes via `WarmupPolicy`:

1. `WARMUP_NONE`: No warmup exclusion; all observations contribute to statistics immediately.
2. `WARMUP_FIXED`: Discards the first `warmup_n` events or time units before accumulating statistics.
3. `WARMUP_AUTO`: Evaluates online `WelchDetector` on queue length or sojourn times; streaming statistical accumulators begin once the detector signals steady state.

```julia
# Discard initial 5,000 customers
p_fixed = StatsPipeline(warmup = WARMUP_FIXED, warmup_n = 5_000)

# Discard automatically using Welch detector
p_auto  = StatsPipeline(warmup = WARMUP_AUTO)
```
