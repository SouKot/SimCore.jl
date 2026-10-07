# SimCore.jl

*Foundational discrete-event simulation engine, streaming statistics, and transient warmup detection in Julia.*

[![CI](https://github.com/SouKot/SimCore.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/SouKot/SimCore.jl/actions/workflows/CI.yml)
[![Version](https://juliahub.com/docs/packages/SimCore/version.svg)](https://juliahub.com/ui/Packages/SimCore/0.1.0)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

---

## Overview

`SimCore.jl` provides the core event scheduling, clock synchronization, online statistical accumulators, and output analysis primitives for scientific simulation. It serves as the independent foundational engine for [`SimDES.jl`](https://github.com/SouKot/SimDES.jl) and hybrid agent-based systems.

### Scope & Design Boundaries

- **Discrete-Event Scheduling:** Future Event List (FEL) management, unique event dispatch, cancellation, and simulation clock throttle (`SimClock`).
- **Streaming Mathematical Accumulators:** Single-pass Welford online variance, Rajan running extrema, and Jain-Chlamtac $P^2$ streaming quantiles.
- **Warmup Detection:** Automated initialization bias detection via Welch moving-average smoothing (Welch 1983).
- **Statistical Pipeline:** Composable, multi-metric accumulation pipeline (`StatsPipeline`) with Little's Law verification.
- **Hardware Acceleration Boundaries:** Discrete event loops execute strictly on CPU threads. Post-simulation batch reductions and histograms are parallelized via the `SimCoreGPUExt` package extension (`KernelAbstractions.jl` / `AcceleratedKernels.jl`).

---

## Installation

```julia
using Pkg
Pkg.add("SimCore")
```

---

## Early Stage Advisory (`v0.1.0`)

> **Notice:** `SimCore.jl` is in active early-stage development (`v0.1.0`). While all mathematical accumulators and test suites undergo continuous numerical verification, APIs may evolve prior to `v1.0.0`. Numerical bugs, edge cases, or documentation inaccuracies should be reported on [GitHub Issues](https://github.com/SouKot/SimCore.jl/issues).

---

## AI Collaboration Disclosure

This codebase was developed with the assistance of **Google DeepMind Antigravity**, an agentic AI pair programmer. All mathematical formulations, statistical invariants (Welford recurrence, $P^2$ quantile parabolic interpolation, Welch windowing), and test suites have been verified through empirical unit tests and analytical queueing theory benchmarks.

---

## Runnable Verification Examples

`SimCore.jl` provides 4 standalone examples in its `examples/` directory:

| Script | Algorithmic Focus |
| :--- | :--- |
| `01_custom_event_loop.jl` | Minimal raw event dispatch loop with $O(1)$ lazy cancellation and speed throttling. |
| `02_welch_warmup_detection.jl` | Numerical transient bias elimination via Welch's moving average. |
| `03_littles_law_audit.jl` | Riemann time-average queue length vs $\lambda_{\text{eff}} W$ verified to 0.00% discrepancy. |
| `04_gpu_acceleration_demo.jl` | Parallel array statistics reduction via `AcceleratedKernels.jl`. |

### Running from the Terminal
```bash
julia --project=. examples/01_custom_event_loop.jl
```

### Running from the Julia REPL
```julia
using Pkg; Pkg.activate(".")
include("examples/01_custom_event_loop.jl")
include("examples/03_littles_law_audit.jl")
```

---

---

## Environment & Local Documentation Build

* **Operating System**: **Ubuntu 26.04.1 LTS** (`x86_64`)
* **Julia Compatibility**: Julia 1.10.12 LTS and Julia 1.13.0 (all 396 tests passing clean, 100%)
* **CI/CD Status**: Automated GitHub Actions workflows are currently **paused** (manual trigger via `workflow_dispatch` only).
* **Building Documentation Locally**:
  ```bash
  julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate(); include("docs/make.jl")'
  ```

---

## Manual Contents

```@contents
Pages = [
    "architecture.md",
    "warmup.md",
    "pipeline.md",
    "analysis.md",
    "gpu.md",
    "api.md",
]
Depth = 2
```
