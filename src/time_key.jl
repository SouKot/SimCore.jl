"""
    time_key.jl — Exact Integer Picosecond Time Quantization & Total-Order EventKey

Provides:
- `PICOSECONDS_PER_SEC`: `Int64(1_000_000_000_000)` (`10^12` ticks per simulated second).
- `to_picoseconds(t)` / `from_picoseconds(t_ps)`: deterministic conversion between `Float64`
  seconds and `Int64` picosecond ticks, eliminating 1-ULP IEEE-754 representation drift
  (e.g., `0.1 + 0.1 + 0.1` vs `0.3`).
- `EventKey`: 24-byte immutable total-order priority key `(t_ps, priority_eps, source_zone, seq)`
  that guarantees deterministic tie-breaking across both serial and multi-threaded PDES runs.
"""

const PICOSECONDS_PER_SEC = Int64(1_000_000_000_000)
const SEC_PER_PICOSECOND  = 1.0e-12

"""
    to_picoseconds(t::Real) -> Int64

Convert a simulated timestamp `t` (in seconds) to the nearest integer picosecond tick (`10^-12 s`).
Non-finite values (`Inf`, `-Inf`) map to `typemax(Int64)` / `typemin(Int64)`.
"""
@inline function to_picoseconds(t::Real)::Int64
    tf = Float64(t)
    isnan(tf) && return typemax(Int64)
    tf >= 9.0e6  && return typemax(Int64)   # > ~104 days in ps; clamp safely before Int64 overflow
    tf <= -9.0e6 && return typemin(Int64)
    return round(Int64, tf * 1.0e12)
end

"""
    from_picoseconds(t_ps::Int64) -> Float64

Convert an integer picosecond tick back to `Float64` simulated seconds.
"""
@inline function from_picoseconds(t_ps::Int64)::Float64
    t_ps == typemax(Int64) && return Inf
    t_ps == typemin(Int64) && return -Inf
    return Float64(t_ps) * SEC_PER_PICOSECOND
end

"""
    EventKey

Immutable 24-byte total-order key for the Future Event List (`FlatBinaryMinHeap`) and
Conservative PDES engines.

# Fields
- `t_ps::Int64`: Simulated event time quantized to integer picoseconds (`10^-12 s`).
- `priority_eps::Int32`: Micro-step phase tie-breaker at identical timestamps
  (e.g. `-20` resource release, `-10` process completion/exit, `0` default, `+10` arrival).
- `source_zone::Int32`: Originating zone / logical process ID (`0` in unpartitioned serial mode).
- `seq::UInt64`: Monotonic event sequence number (`cev.id` in serial mode, or per-zone
  monotonic sequence counter in partitioned PDES mode).
"""
struct EventKey
    t_ps         :: Int64
    priority_eps :: Int32
    source_zone  :: Int32
    seq          :: UInt64
end

@inline function EventKey(t::Real, seq::UInt64; priority_eps::Integer=Int32(0), source_zone::Integer=Int32(0))
    return EventKey(to_picoseconds(t), Int32(priority_eps), Int32(source_zone), seq)
end

@inline function Base.isless(a::EventKey, b::EventKey)::Bool
    a.t_ps != b.t_ps                 && return a.t_ps < b.t_ps
    a.priority_eps != b.priority_eps && return a.priority_eps < b.priority_eps
    a.source_zone != b.source_zone   && return a.source_zone < b.source_zone
    return a.seq < b.seq
end

@inline Base.:(==)(a::EventKey, b::EventKey)::Bool =
    a.t_ps == b.t_ps && a.priority_eps == b.priority_eps &&
    a.source_zone == b.source_zone && a.seq == b.seq

"""
    default_event_priority_eps(ev::SimEvent) -> Int32

Return canonical micro-step phase priority for tie-breaking simultaneous events across zones:
- `-20`: Resource repair / capacity restoration (`ScheduledChange`)
- `-10`: Service / transport completion (`ProcessComplete`, `TransferOut`, `UnloadingComplete`, `LoadingComplete`)
- `  0`: General / user events (`CustomUserEvent`, `ResourceFailure`, `LoadingStart`, `UnloadingStart`)
- `+10`: New entity arrival (`EntityArrival`)
"""
@inline default_event_priority_eps(::SimEvent)::Int32          = Int32(0)
@inline default_event_priority_eps(::ScheduledChange)::Int32   = Int32(-20)
@inline default_event_priority_eps(::ProcessComplete)::Int32   = Int32(-10)
@inline default_event_priority_eps(::TransferOut)::Int32       = Int32(-10)
@inline default_event_priority_eps(::UnloadingComplete)::Int32 = Int32(-10)
@inline default_event_priority_eps(::LoadingComplete)::Int32   = Int32(-10)
@inline default_event_priority_eps(::EntityArrival)::Int32     = Int32(10)

"""
    default_event_zone(ev::SimEvent) -> Int32

Extract the target/owning zone ID from a `SimEvent` (`0` if not zone-specific).
"""
@inline default_event_zone(::SimEvent)::Int32              = Int32(0)
@inline default_event_zone(e::EntityArrival)::Int32        = Int32(e.zone_id)
@inline default_event_zone(e::ProcessComplete)::Int32      = Int32(e.station_id)
@inline default_event_zone(e::ResourceFailure)::Int32      = Int32(e.resource_id)
@inline default_event_zone(e::ScheduledChange)::Int32      = Int32(e.zone_id)
@inline default_event_zone(e::TransferOut)::Int32          = Int32(e.dest_zone)
@inline default_event_zone(e::CustomUserEvent)::Int32      = Int32(e.zone_id)
@inline default_event_zone(e::LoadingStart)::Int32         = Int32(e.station_id)
@inline default_event_zone(e::LoadingComplete)::Int32      = Int32(e.station_id)
@inline default_event_zone(e::UnloadingStart)::Int32       = Int32(e.station_id)
@inline default_event_zone(e::UnloadingComplete)::Int32    = Int32(e.station_id)

