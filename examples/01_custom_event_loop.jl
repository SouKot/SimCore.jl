# 01_custom_event_loop.jl — Minimal Raw Event Dispatch Loop
# Demonstrates direct usage of SimCore primitives (SimClock, SimEvent, CancellableEvent)

using SimCore
using DataStructures: PriorityQueue, dequeue_pair!

println("=== SimCore Example 1: Minimal Event Dispatch Loop ===")

# 1. Initialize clock and event queue
clock = SimClock()
set_speed!(clock, Inf)  # Run at maximum simulation speed (no wall-clock throttle)
fel = PriorityQueue{CancellableEvent, Float64}()

# 2. Define helper to schedule events
function schedule_event!(q, ev::SimEvent, t::Float64)
    cev = CancellableEvent(ev, t)
    push!(q, cev => t)
    return cev.id
end

# 3. Schedule some initial events
schedule_event!(fel, EntityArrival(UInt64(101), 1, 1.5), 1.5)
schedule_event!(fel, EntityArrival(UInt64(102), 1, 2.0), 2.0)
cancel_id = schedule_event!(fel, EntityArrival(UInt64(103), 1, 2.5), 2.5)
schedule_event!(fel, ProcessComplete(UInt64(101), 1, 4.0), 4.0)

# Lazily cancel event 103
cancel!(cancel_id)
println("Scheduled 4 events, cancelled event ID: $cancel_id")

# 4. Process event loop
events_processed = 0
while !isempty(fel)
    cev, t = dequeue_pair!(fel)

    # Check if event was lazily cancelled
    if is_cancelled(cev.id)
        println("  [t=$(round(t, digits=2))] SKIPPED cancelled event (ID: $(cev.id))")
        continue
    end

    # Advance virtual simulation clock
    throttle!(clock, t)
    global events_processed += 1

    println("  [t=$(round(sim_time(clock), digits=2))] Dispatched: $(typeof(cev.inner)) (ID: $(cev.id))")
end

println("Done! Processed $events_processed valid events.")
