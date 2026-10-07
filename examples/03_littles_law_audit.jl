# 03_littles_law_audit.jl — Numerical Verification of Little's Law
# Validates the fundamental queueing invariant L = λ * W using StatsPipeline.

using SimCore
using Random
using Printf

println("=== SimCore Example 3: Little's Law Numerical Audit ===")

function run_littles_law_simulation(n_customers::Int = 50_000; λ::Float64 = 2.0, μ::Float64 = 3.333, seed::Int = 1234)
    pipeline = StatsPipeline(warmup = WARMUP_NONE)
    rng = MersenneTwister(seed)

    current_time = 0.0
    last_time = 0.0
    sys_count = 0

    arrival_timestamps = Float64[]
    next_departure_time = Inf

    next_arrival_time = -log(rand(rng)) / λ
    arrivals_scheduled = 1

    while arrivals_scheduled <= n_customers || sys_count > 0
        if next_arrival_time <= next_departure_time
            # Arrival
            ev_time = next_arrival_time
            dt = ev_time - last_time
            if dt > 0.0
                record_queue_length!(pipeline, sys_count, dt)
                last_time = ev_time
            end

            current_time = ev_time
            sys_count += 1
            record_arrival!(pipeline)
            push!(arrival_timestamps, current_time)

            if sys_count == 1
                service_dur = -log(rand(rng)) / μ
                next_departure_time = current_time + service_dur
            end

            if arrivals_scheduled < n_customers
                arrivals_scheduled += 1
                next_arrival_time = current_time - log(rand(rng)) / λ
            else
                arrivals_scheduled += 1
                next_arrival_time = Inf
            end
        else
            # Departure
            ev_time = next_departure_time
            dt = ev_time - last_time
            if dt > 0.0
                record_queue_length!(pipeline, sys_count, dt)
                last_time = ev_time
            end

            current_time = ev_time
            t_arr = popfirst!(arrival_timestamps)
            sojourn = current_time - t_arr
            wait_time = max(0.0, sojourn - (1.0 / μ))
            record_departure!(pipeline, wait_time, sojourn)

            sys_count -= 1

            if sys_count > 0
                service_dur = -log(rand(rng)) / μ
                next_departure_time = current_time + service_dur
            else
                next_departure_time = Inf
            end
        end
    end

    return sim_summary(pipeline)
end

λ = 2.0
μ = 3.333

summary = run_littles_law_simulation(50_000; λ = λ, μ = μ)

println("\nSimulation Results:")
@printf("  Total Arrivals:       %d\n", summary.total_arrivals)
@printf("  Total Departures:     %d\n", summary.total_departures)
@printf("  Empirical Throughput: %.4f items/sec (Target λ = %.4f)\n", summary.throughput, λ)
@printf("  Mean Sojourn W:       %.4f sec (Theory = %.4f)\n", summary.W, 1.0 / (μ - λ))
@printf("  Mean System Items L:  %.4f (Theory = %.4f)\n", summary.L, (λ / μ) / (1.0 - (λ / μ)))

# Formal check of Little's Law: L ≈ λ_eff * W
is_valid, rel_error = check_littles_law(summary; tol = 0.05)
L_predicted = summary.throughput * summary.W

println("\nLittle's Law Mathematical Audit (L = λ * W):")
@printf("  Predicted L (λ * W):  %.4f\n", L_predicted)
@printf("  Measured L:           %.4f\n", summary.L)
@printf("  Relative Discrepancy: %.2f%%\n", rel_error * 100)
println("  Audit Verification:   ", is_valid ? "PASSED (Little's Law Holds)" : "FAILED")
