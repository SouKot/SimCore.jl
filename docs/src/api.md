# API Reference

## SimClock & Simulation Time

```@docs
SimClock
set_speed!
unpause!
step_once!
throttle!
sim_time
```

---

## Events & Scheduling

```@docs
SimEvent
EntityArrival
ProcessComplete
ResourceFailure
ScheduledChange
CustomUserEvent
CancellableEvent
cancel!
is_cancelled
```

---

## Warmup Detection

```@docs
WelchDetector
update!
warmup_complete
```

---

## Statistics Pipeline & Collectors

```@docs
StatsPipeline
WarmupPolicy
record_arrival!
record_departure!
record_queue_length!
record_utilization!
record_idle!
record_uptime!
record_blocked!
sim_summary
reset!
```

---

## Output Analysis & Verification

```@docs
check_littles_law
batch_means_ci
replicate
replicate_parallel
gpu_mean_var
gpu_histogram
```
