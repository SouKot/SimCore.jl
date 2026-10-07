# Output Analysis & Little's Law Audit

## Mathematical Verification via Little's Law

In steady state, every discrete-event queueing system must satisfy **Little's Law** (Little 1961):

$$L = \lambda_{\text{eff}} \cdot W$$

where:
- $L$ is the time-average number of entities in the system.
- $\lambda_{\text{eff}}$ is the effective throughput rate (completed departures per unit simulated time).
- $W$ is the mean sojourn time (total time spent in the system).

`SimCore.jl` provides the verification function `check_littles_law(summary; tol = 0.10)` to perform an automated internal consistency check on simulation output.

```julia
using SimCore

summary = sim_summary(pipeline)
ok, rel_err = check_littles_law(summary; tol = 0.05)

if ok
    println("Little's Law verified: relative discrepancy = $(round(rel_err * 100, digits=2))%")
else
    @warn "Simulation violated Little's Law: potential warmup bias or mass leak!"
end
```

---

## Batch Means Confidence Intervals (`batch_means_ci`)

For single long simulation runs, autocorrelation between consecutive departures violates the independence assumption of classical Student's $t$-tests.

The **Method of Batch Means** divides $N$ steady-state observations into $b$ non-overlapping batches of size $m = N / b$. The batch means $\bar{Y}_1, \dots, \bar{Y}_b$ are approximately uncorrelated for sufficiently large $m$.

```julia
ci = batch_means_ci(samples, n_batches = 30, conf_level = 0.95)
println("Estimated Mean: ", ci.mean)
println("95% CI:         [$(ci.ci_lower), $(ci.ci_upper)]")
println("Half-width:     ", ci.half_width)
```

---

## Multi-Replication Studies (`replicate` & `replicate_parallel`)

To obtain strictly independent samples, simulations should be repeated across multiple seeds:

```julia
# Run 20 independent replications across multiple CPU threads
results = replicate_parallel(20) do seed
    # Run simulation with MersenneTwister(seed)
    # Return StatsPipeline or named tuple of metrics
end
```
