# packages/SimCore/src/hardware_planner.jl
#
# Phase 4: Whole-Machine Hardware Assessment & Multi-Paradigm Resource Arbitrator.
# Provides zero-allocation / sub-millisecond hardware probing, scene workload profiling,
# and contention-aware execution planning across DES, ABM, Fluid, Stats, and Replications.

"""
    HardwareProfile

Snapshot of the host machine's compute and memory resources, plus whether an interactive
3D visualization viewport is currently active on the same machine.
"""
struct HardwareProfile
    cpu_logical_threads :: Int
    cpu_physical_cores  :: Int
    julia_threads       :: Int
    total_ram_bytes     :: UInt64
    free_ram_bytes      :: UInt64
    has_cuda            :: Bool
    gpu_name            :: String
    gpu_sm_count        :: Int
    gpu_total_vram      :: UInt64
    gpu_free_vram       :: UInt64
    is_interactive_viz  :: Bool
    cpu_fast_cores      :: Int
    l1d_cache_bytes     :: Int
    l2_cache_bytes      :: Int
    l3_cache_bytes      :: Int
    cpu_thread_wake_us  :: Float64
    cpu_mem_bw_gbps     :: Float64
    gpu_launch_us       :: Float64
    gpu_mem_bw_gbps     :: Float64
    pcie_bw_gbps        :: Float64
end

# 11-argument positional constructor for backward compatibility
function HardwareProfile(
    cpu_logical_threads :: Int,
    cpu_physical_cores  :: Int,
    julia_threads       :: Int,
    total_ram_bytes     :: UInt64,
    free_ram_bytes      :: UInt64,
    has_cuda            :: Bool,
    gpu_name            :: String,
    gpu_sm_count        :: Int,
    gpu_total_vram      :: UInt64,
    gpu_free_vram       :: UInt64,
    is_interactive_viz  :: Bool,
)
    phys = max(1, cpu_physical_cores)
    return HardwareProfile(
        max(1, cpu_logical_threads),
        phys,
        max(1, julia_threads),
        total_ram_bytes,
        free_ram_bytes,
        has_cuda,
        gpu_name,
        max(0, gpu_sm_count),
        gpu_total_vram,
        gpu_free_vram,
        is_interactive_viz,
        phys,
        32 * 1024,
        1024 * 1024,
        16 * 1024 * 1024,
        5.5,
        24.0,
        has_cuda ? 8.5 : 0.0,
        has_cuda ? 220.0 : 0.0,
        has_cuda ? 11.5 : 0.0,
    )
end

function HardwareProfile(;
    cpu_logical_threads :: Int = Sys.CPU_THREADS,
    cpu_physical_cores  :: Int = max(1, Sys.CPU_THREADS ÷ 2),
    julia_threads       :: Int = Threads.nthreads(),
    total_ram_bytes     :: UInt64 = Sys.total_memory(),
    free_ram_bytes      :: UInt64 = Sys.free_memory(),
    has_cuda            :: Bool = false,
    gpu_name            :: String = "none",
    gpu_sm_count        :: Int = 0,
    gpu_total_vram      :: UInt64 = UInt64(0),
    gpu_free_vram       :: UInt64 = UInt64(0),
    is_interactive_viz  :: Bool = false,
    cpu_fast_cores      :: Int = max(1, cpu_physical_cores),
    l1d_cache_bytes     :: Int = 32 * 1024,
    l2_cache_bytes      :: Int = 1024 * 1024,
    l3_cache_bytes      :: Int = 16 * 1024 * 1024,
    cpu_thread_wake_us  :: Float64 = 5.5,
    cpu_mem_bw_gbps     :: Float64 = 24.0,
    gpu_launch_us       :: Float64 = has_cuda ? 8.5 : 0.0,
    gpu_mem_bw_gbps     :: Float64 = has_cuda ? 220.0 : 0.0,
    pcie_bw_gbps        :: Float64 = has_cuda ? 11.5 : 0.0,
)
    phys = max(1, cpu_physical_cores)
    return HardwareProfile(
        max(1, cpu_logical_threads),
        phys,
        max(1, julia_threads),
        total_ram_bytes,
        free_ram_bytes,
        has_cuda,
        gpu_name,
        max(0, gpu_sm_count),
        gpu_total_vram,
        gpu_free_vram,
        is_interactive_viz,
        clamp(cpu_fast_cores, 1, phys),
        max(16 * 1024, l1d_cache_bytes),
        max(128 * 1024, l2_cache_bytes),
        max(1024 * 1024, l3_cache_bytes),
        max(0.1, cpu_thread_wake_us),
        max(1.0, cpu_mem_bw_gbps),
        max(0.0, gpu_launch_us),
        max(0.0, gpu_mem_bw_gbps),
        max(0.0, pcie_bw_gbps),
    )
end

const _CACHED_PHYSICAL_CORES = Ref{Int}(0)
const _CACHED_CACHE_SIZES    = Ref{Tuple{Int, Int, Int}}((0, 0, 0))
const _CACHED_CPU_ROOFLINE   = Ref{Tuple{Float64, Float64}}((0.0, 0.0))

function _parse_sysfs_size_bytes(raw::AbstractString)::Int
    s = uppercase(strip(raw))
    isempty(s) && return 0
    if endswith(s, "K")
        v = tryparse(Int, s[1:end-1])
        return v !== nothing ? v * 1024 : 0
    elseif endswith(s, "M")
        v = tryparse(Int, s[1:end-1])
        return v !== nothing ? v * 1024 * 1024 : 0
    else
        v = tryparse(Int, s)
        return v !== nothing ? v : 0
    end
end

"""
    detect_cpu_cache_hierarchy() -> (l1d_bytes::Int, l2_bytes::Int, l3_bytes::Int)

Read L1d, L2, and shared L3 cache sizes from OS topology files (cached after first call).
"""
function detect_cpu_cache_hierarchy()::Tuple{Int, Int, Int}
    cached = _CACHED_CACHE_SIZES[]
    cached[3] > 0 && return cached
    l1d = 32 * 1024
    l2  = 1024 * 1024
    l3  = 16 * 1024 * 1024
    try
        if Sys.islinux() && isdir("/sys/devices/system/cpu/cpu0/cache")
            for idx in 0:5
                dir = "/sys/devices/system/cpu/cpu0/cache/index$(idx)"
                isdir(dir) || continue
                lvl_file  = joinpath(dir, "level")
                type_file = joinpath(dir, "type")
                size_file = joinpath(dir, "size")
                (isfile(lvl_file) && isfile(size_file)) || continue
                lvl = something(tryparse(Int, strip(read(lvl_file, String))), 0)
                ctype = isfile(type_file) ? lowercase(strip(read(type_file, String))) : ""
                sz = _parse_sysfs_size_bytes(read(size_file, String))
                sz <= 0 && continue
                if lvl == 1 && (ctype == "data" || ctype == "unified")
                    l1d = sz
                elseif lvl == 2
                    l2 = sz
                elseif lvl == 3
                    l3 = sz
                end
            end
        end
    catch
    end
    res = (l1d, l2, l3)
    _CACHED_CACHE_SIZES[] = res
    return res
end

"""
    calibrate_cpu_roofline() -> (thread_wake_us::Float64, mem_bw_gbps::Float64)

Run a sub-5ms startup micro-benchmark (cached once per Julia session) to measure the host's
actual `Threads.@threads` barrier wake latency and DRAM triad bandwidth.
"""
function calibrate_cpu_roofline()::Tuple{Float64, Float64}
    cached = _CACHED_CPU_ROOFLINE[]
    cached[2] > 0.0 && return cached
    wake_us = 5.5
    bw_gbps = 24.0
    try
        if Threads.nthreads() >= 2
            sink = zeros(Int, Threads.nthreads())
            Threads.@threads :static for i in 1:Threads.nthreads()
                @inbounds sink[i] = i
            end
            t0 = time_ns()
            for _ in 1:32
                Threads.@threads :static for i in 1:Threads.nthreads()
                    @inbounds sink[i] += 1
                end
            end
            wake_us = clamp((time_ns() - t0) / 32.0 / 1e3, 0.5, 50.0)
        end
        n_elem = 262_144 # 1 MiB per vector (3 MiB triad total)
        a = ones(Float32, n_elem)
        b = fill(2.0f0, n_elem)
        c = zeros(Float32, n_elem)
        @inbounds @simd for i in 1:n_elem
            c[i] = a[i] + 0.5f0 * b[i]
        end
        t1 = time_ns()
        for _ in 1:8
            @inbounds @simd for i in 1:n_elem
                c[i] = a[i] + 0.5f0 * b[i]
            end
        end
        dt_s = max(1e-9, (time_ns() - t1) / 8.0 / 1e9)
        bytes_moved = 3.0 * n_elem * sizeof(Float32)
        # Scale single-core streaming bandwidth by min(physical_cores, 4) for multi-channel DRAM saturation
        scale_cores = min(4.0, Float64(max(1, Threads.nthreads())))
        bw_gbps = clamp((bytes_moved / dt_s / 1e9) * max(1.0, 0.65 * scale_cores), 4.0, 400.0)
    catch
    end
    res = (wake_us, bw_gbps)
    _CACHED_CPU_ROOFLINE[] = res
    return res
end

"""
    detect_physical_cores() -> Int

Detect the number of physical CPU cores on the host machine (cached after first call).
Falls back to `max(1, Sys.CPU_THREADS ÷ 2)` if OS topology files are unavailable.
"""
function detect_physical_cores()::Int
    _CACHED_PHYSICAL_CORES[] > 0 && return _CACHED_PHYSICAL_CORES[]
    phys = max(1, Sys.CPU_THREADS ÷ 2)
    try
        if Sys.islinux() && isfile("/proc/cpuinfo")
            pairs = Set{Tuple{Int, Int}}()
            cur_pkg = 0
            cur_core = -1
            for line in eachline("/proc/cpuinfo")
                if startswith(line, "physical id")
                    parts = split(line, ':')
                    length(parts) >= 2 && (cur_pkg = something(tryparse(Int, strip(parts[2])), 0))
                elseif startswith(line, "core id")
                    parts = split(line, ':')
                    if length(parts) >= 2
                        cur_core = something(tryparse(Int, strip(parts[2])), -1)
                        cur_core >= 0 && push!(pairs, (cur_pkg, cur_core))
                    end
                end
            end
            if !isempty(pairs)
                phys = length(pairs)
            end
        end
    catch
    end
    phys = clamp(phys, 1, max(1, Sys.CPU_THREADS))
    _CACHED_PHYSICAL_CORES[] = phys
    return phys
end

"""
    probe_hardware(;
        is_interactive_viz::Bool = false,
        cuda_probe_fn::Union{Nothing, Function} = nothing,
    ) -> HardwareProfile

Probe the host CPU, RAM, and optional CUDA GPU device properties.
If `cuda_probe_fn` is provided, it should return a NamedTuple
`(has_cuda, gpu_name, gpu_sm_count, gpu_total_vram, gpu_free_vram)`.
"""
function probe_hardware(;
    is_interactive_viz::Bool = false,
    cuda_probe_fn::Union{Nothing, Function} = nothing,
)::HardwareProfile
    logical  = max(1, Sys.CPU_THREADS)
    physical = detect_physical_cores()
    jthreads = max(1, Threads.nthreads())
    tot_ram  = Sys.total_memory()
    free_ram = Sys.free_memory()

    has_cuda   = false
    gpu_name   = "none"
    sm_count   = 0
    tot_vram   = UInt64(0)
    free_vram  = UInt64(0)

    if cuda_probe_fn !== nothing
        try
            g = cuda_probe_fn()
            has_cuda  = Bool(g.has_cuda)
            gpu_name  = String(g.gpu_name)
            sm_count  = Int(g.gpu_sm_count)
            tot_vram  = UInt64(g.gpu_total_vram)
            free_vram = UInt64(g.gpu_free_vram)
        catch
        end
    end

    l1d, l2, l3 = detect_cpu_cache_hierarchy()
    wake_us, cpu_bw = calibrate_cpu_roofline()
    gpu_bw = has_cuda ? max(120.0, Float64(max(16, sm_count)) * 7.5) : 0.0

    return HardwareProfile(
        logical,
        physical,
        jthreads,
        tot_ram,
        free_ram,
        has_cuda,
        gpu_name,
        sm_count,
        tot_vram,
        free_vram,
        is_interactive_viz,
        physical,
        l1d,
        l2,
        l3,
        wake_us,
        cpu_bw,
        has_cuda ? 8.5 : 0.0,
        gpu_bw,
        has_cuda ? 11.5 : 0.0,
    )
end

"""
    WorkloadProfile

Extracted computational complexity metrics of a compiled simulation model across all
active paradigms (DES, ABM, Fluid, Stats, and Outer Replications).
"""
struct WorkloadProfile
    n_des_zones         :: Int
    n_submodels         :: Int
    min_cross_promise_s :: Float64
    est_des_events_per_s:: Float64
    has_des_hooks       :: Bool
    n_abm_agents        :: Int
    has_orca            :: Bool
    n_nav_cells         :: Int
    n_fluid_2d_cells    :: Int
    n_sph_particles     :: Int
    n_replications      :: Int
    n_fluid_3d_voxels   :: Int
    n_fluid_sensors     :: Int
    fluid_has_obstacles :: Bool
    fluid_cfl_substeps  :: Float64
    abm_dt              :: Float64
end

# 11-argument positional constructor for backward compatibility
function WorkloadProfile(
    n_des_zones         :: Int,
    n_submodels         :: Int,
    min_cross_promise_s :: Float64,
    est_des_events_per_s:: Float64,
    has_des_hooks       :: Bool,
    n_abm_agents        :: Int,
    has_orca            :: Bool,
    n_nav_cells         :: Int,
    n_fluid_2d_cells    :: Int,
    n_sph_particles     :: Int,
    n_replications      :: Int,
)
    return WorkloadProfile(
        max(0, n_des_zones),
        max(1, n_submodels),
        min_cross_promise_s,
        max(0.0, est_des_events_per_s),
        has_des_hooks,
        max(0, n_abm_agents),
        has_orca,
        max(0, n_nav_cells),
        max(0, n_fluid_2d_cells),
        max(0, n_sph_particles),
        max(1, n_replications),
        0,
        0,
        false,
        3.0,
        0.05,
    )
end

function WorkloadProfile(;
    n_des_zones         :: Int = 0,
    n_submodels         :: Int = 1,
    min_cross_promise_s :: Float64 = 0.0,
    est_des_events_per_s:: Float64 = 0.0,
    has_des_hooks       :: Bool = false,
    n_abm_agents        :: Int = 0,
    has_orca            :: Bool = false,
    n_nav_cells         :: Int = 0,
    n_fluid_2d_cells    :: Int = 0,
    n_sph_particles     :: Int = 0,
    n_replications      :: Int = 1,
    n_fluid_3d_voxels   :: Int = 0,
    n_fluid_sensors     :: Int = 0,
    fluid_has_obstacles :: Bool = false,
    fluid_cfl_substeps  :: Float64 = 3.0,
    abm_dt              :: Float64 = 0.05,
)
    return WorkloadProfile(
        max(0, n_des_zones),
        max(1, n_submodels),
        min_cross_promise_s,
        max(0.0, est_des_events_per_s),
        has_des_hooks,
        max(0, n_abm_agents),
        has_orca,
        max(0, n_nav_cells),
        max(0, n_fluid_2d_cells),
        max(0, n_sph_particles),
        max(1, n_replications),
        max(0, n_fluid_3d_voxels),
        max(0, n_fluid_sensors),
        fluid_has_obstacles,
        max(1.0, fluid_cfl_substeps),
        max(1e-4, abm_dt),
    )
end

"""
    estimate_fluid_step_cost_us(hw::HardwareProfile, wl::WorkloadProfile, backend::Symbol, n_threads::Int = 1) -> Float64

Machine-independent Roofline cost estimate (in microseconds per coupled step) for a 3D fluid domain.
Accounts for stencil memory traffic, cache-hierarchy residency (L2/L3 vs DRAM), thread barrier wake latency,
and GPU kernel launch + PCIe coupling overhead.
"""
function estimate_fluid_step_cost_us(
    hw::HardwareProfile,
    wl::WorkloadProfile,
    backend::Symbol,
    n_threads::Int = 1,
)::Float64
    voxels = wl.n_fluid_3d_voxels > 0 ? wl.n_fluid_3d_voxels : wl.n_fluid_2d_cells
    voxels <= 0 && return 0.0
    substeps = max(1.0, wl.fluid_cfl_substeps)
    working_set_bytes = Float64(voxels) * 68.0
    # ~1,200 bytes/voxel moved across predictor, TVD scalars, thermodynamics, and Poisson per substep
    bytes_per_substep = Float64(voxels) * 1200.0 + Float64(voxels) * log2(max(2.0, Float64(voxels))) * 24.0
    if backend === :cuda
        !hw.has_cuda && return Inf
        # 24 kernel launches per substep + device memory traffic + small sensor/agent PCIe sync
        launch_cost_us = 24.0 * hw.gpu_launch_us * substeps
        mem_cost_us    = (bytes_per_substep * substeps) / (max(50.0, hw.gpu_mem_bw_gbps) * 1e3)
        pcie_sync_us   = 35.0 + (Float64(wl.n_abm_agents) * 64.0) / (max(4.0, hw.pcie_bw_gbps) * 1e3)
        return launch_cost_us + mem_cost_us + pcie_sync_us
    else
        T = backend === :cpu_serial ? 1 : max(1, n_threads)
        # Effective bandwidth scales up when working set fits in L3 cache
        cache_boost = working_set_bytes <= 1.2 * Float64(hw.l3_cache_bytes) ? 2.4 : 1.0
        eff_bw_gbps = hw.cpu_mem_bw_gbps * cache_boost * min(Float64(T), 4.0) / min(Float64(max(1, hw.cpu_physical_cores)), 4.0)
        wake_cost_us = (T > 1 ? 14.0 * hw.cpu_thread_wake_us * substeps : 0.0)
        mem_cost_us  = (bytes_per_substep * substeps) / (max(4.0, eff_bw_gbps) * 1e3)
        return wake_cost_us + mem_cost_us
    end
end

"""
    ExecutionOverrides

Explicit user or environment-variable overrides for individual subsystem backends and
resource caps. Any field left as `:auto` (or `0` for `max_cpu_threads`) is decided
automatically by `arbitrate_execution_plan`.
"""
struct ExecutionOverrides
    des_backend      :: Symbol
    abm_backend      :: Symbol
    fluid_backend    :: Symbol
    stats_backend    :: Symbol
    replication_mode :: Symbol
    max_cpu_threads  :: Int
    allow_gpu        :: Bool
end

function ExecutionOverrides(;
    des_backend      :: Symbol = :auto,
    abm_backend      :: Symbol = :auto,
    fluid_backend    :: Symbol = :auto,
    stats_backend    :: Symbol = :auto,
    replication_mode :: Symbol = :auto,
    max_cpu_threads  :: Int = 0,
    allow_gpu        :: Bool = true,
)
    return ExecutionOverrides(
        des_backend,
        abm_backend,
        fluid_backend,
        stats_backend,
        replication_mode,
        max(0, max_cpu_threads),
        allow_gpu,
    )
end

"""
    ExecutionPlan

Joint hardware resource assignment across Replications, DES, ABM, Fluid, and Stats,
including thread counts, estimated VRAM usage, and human-readable rationale per solver.
"""
struct ExecutionPlan
    replication_mode      :: Symbol
    replication_workers   :: Int
    des_backend           :: Symbol
    des_threads           :: Int
    des_min_window_events :: Int
    abm_backend           :: Symbol
    abm_threads           :: Int
    fluid_backend         :: Symbol
    fluid_threads         :: Int
    stats_backend         :: Symbol
    estimated_vram_bytes  :: UInt64
    rationale             :: Dict{Symbol, String}
end

@inline function _normalize_backend_override(sym::Symbol, allowed::Tuple)::Symbol
    sym in allowed && return sym
    if sym === :gpu
        return :cuda in allowed ? :cuda : (:gpu_ak in allowed ? :gpu_ak : :auto)
    elseif sym === :cpu
        return :cpu_threads in allowed ? :cpu_threads : (:cpu_serial in allowed ? :cpu_serial : (:serial in allowed ? :serial : :auto))
    end
    return :auto
end

"""
    arbitrate_execution_plan(
        hw::HardwareProfile,
        wl::WorkloadProfile,
        overrides::ExecutionOverrides = ExecutionOverrides(),
    ) -> ExecutionPlan

Compute the optimal, contention-free execution plan across all active simulation paradigms:
1. **Viewport & Thread Headroom:** Reserves `1.5 GiB` VRAM and `1` physical core when an
   interactive 3D viewport is active (`hw.is_interactive_viz == true`), or `256 MiB` VRAM
   and `0` cores in headless mode. Caps CPU compute threads to physical cores unless
   overridden by `overrides.max_cpu_threads`.
2. **Rule 1 — Outer Replication Dominance:** When `wl.n_replications > 1`, assigns CPU cores
   to the outer replication pool (`:cpu_outer_parallel`) and forces inner CPU solvers
   (`DES`, `CPU ABM`, `CPU Fluid`) to `1` thread per replication to prevent `N_rep * T`
   thread oversubscription.
3. **Rule 2 — GPU Allocation Priority (`Fluid > ABM > Stats`):**
   - `Fluid` gets first claim on GPU VRAM when `n_fluid_2d_cells >= 4,096` or `n_sph_particles >= 2,000`.
   - `ABM` gets second claim on GPU VRAM when `n_abm_agents >= 2,500` (or `>= 1,000` when
     `Fluid` is already on `:cuda`, keeping coupled fire/crowd fields device-resident without
     PCIe transfers).
   - Falls back gracefully to `:cpu_threads` or `:cpu_serial` if GPU VRAM is exhausted or
     disabled (`overrides.allow_gpu == false`).
4. **Rule 3 — DES `:serial` vs. `:pdes` & Thread Scaling:**
   - Computes expected events per safe window `N_win = Lambda_est * tau_min`.
   - Assigns `T_des = min(K_submodels, T_avail, floor(N_win / 24))`.
   - Chooses `:pdes` only when `K >= 2`, `tau_min > 0`, `!wl.has_des_hooks`,
     `replication_mode == :serial`, and `T_des >= 2`; otherwise chooses `:serial`
     (`1` thread, zero barrier overhead).
"""
function arbitrate_execution_plan(
    hw::HardwareProfile,
    wl::WorkloadProfile,
    overrides::ExecutionOverrides = ExecutionOverrides(),
)::ExecutionPlan
    rationale = Dict{Symbol, String}()

    # ── 0. Compute CPU Thread Budget & GPU VRAM Headroom ──────────────────────
    viz_thread_reserve = (hw.is_interactive_viz && hw.cpu_physical_cores >= 4 && hw.julia_threads >= 4) ? 1 : 0
    t_sim_max = if overrides.max_cpu_threads > 0
        max(1, min(hw.julia_threads, overrides.max_cpu_threads))
    else
        max(1, min(hw.julia_threads, max(1, hw.cpu_physical_cores)) - viz_thread_reserve)
    end

    vram_headroom = hw.is_interactive_viz ? UInt64(1536) * UInt64(1024^2) : UInt64(256) * UInt64(1024^2)
    gpu_usable = hw.has_cuda && overrides.allow_gpu
    vram_avail = (gpu_usable && hw.gpu_free_vram > vram_headroom) ? (hw.gpu_free_vram - vram_headroom) : UInt64(0)
    vram_used  = UInt64(0)

    # ── 1. Rule 1: Outer Replication Arbitration ──────────────────────────────
    rep_override = _normalize_backend_override(overrides.replication_mode, (:auto, :serial, :cpu_outer_parallel))
    replication_mode = :serial
    replication_workers = 1
    if rep_override === :serial
        replication_mode = :serial
        replication_workers = 1
        rationale[:replication] = "User override :serial (1 worker)"
    elseif rep_override === :cpu_outer_parallel
        replication_mode = :cpu_outer_parallel
        replication_workers = max(1, min(wl.n_replications, t_sim_max))
        rationale[:replication] = "User override :cpu_outer_parallel ($replication_workers workers)"
    elseif wl.n_replications > 1 && t_sim_max >= 2
        replication_mode = :cpu_outer_parallel
        replication_workers = min(wl.n_replications, t_sim_max)
        rationale[:replication] = "Outer replication parallelism across $replication_workers CPU threads for $(wl.n_replications) replications (zero inner barrier overhead)"
    else
        replication_mode = :serial
        replication_workers = 1
        rationale[:replication] = "Single run (1 outer worker)"
    end

    # Inner per-run CPU thread budget (1 when outer replication pool saturates CPU cores)
    t_inner_max = if replication_mode === :cpu_outer_parallel && wl.n_replications >= max(2, t_sim_max ÷ 2)
        1
    elseif replication_mode === :cpu_outer_parallel
        max(1, t_sim_max ÷ replication_workers)
    else
        t_sim_max
    end

    # ── 2. Rule 2a: Fluid Backend Arbitration (First GPU Priority + 3D Roofline) ──
    fluid_override = _normalize_backend_override(overrides.fluid_backend, (:auto, :cpu_serial, :cpu_threads, :cuda))
    effective_fluid_cells = max(wl.n_fluid_3d_voxels, wl.n_fluid_2d_cells)
    has_fluid_work = (effective_fluid_cells > 0 || wl.n_sph_particles > 0)
    fluid_vram_est = has_fluid_work ?
        (UInt64(effective_fluid_cells) * UInt64(wl.n_fluid_3d_voxels > 0 ? 68 : 64) + UInt64(wl.n_sph_particles) * UInt64(128) + UInt64(64 * 1024^2)) :
        UInt64(0)

    fluid_backend = :cpu_serial
    fluid_threads = 1
    if fluid_override === :cuda
        if gpu_usable
            fluid_backend = :cuda
            fluid_threads = 1
            vram_used += fluid_vram_est
            vram_avail = vram_avail > fluid_vram_est ? (vram_avail - fluid_vram_est) : UInt64(0)
            rationale[:fluid] = "User override :cuda on $(hw.gpu_name)"
        else
            fluid_backend = t_inner_max >= 2 ? :cpu_threads : :cpu_serial
            fluid_threads = t_inner_max
            rationale[:fluid] = "Requested :cuda unavailable/disabled; fallback to $fluid_backend ($fluid_threads threads)"
        end
    elseif fluid_override in (:cpu_serial, :cpu_threads)
        fluid_backend = fluid_override
        fluid_threads = fluid_override === :cpu_threads ? max(1, t_inner_max) : 1
        rationale[:fluid] = "User override $fluid_backend ($fluid_threads threads)"
    elseif !has_fluid_work
        fluid_backend = :cpu_serial
        fluid_threads = 1
        rationale[:fluid] = "No active fluid domain (idle)"
    elseif wl.n_fluid_3d_voxels > 0
        # 3D Low-Mach Fire/Fluid Roofline Arbitration:
        # Compare L3-cache-aware multi-threaded CPU cost vs GPU launch + bandwidth cost
        cpu_cost_us = estimate_fluid_step_cost_us(hw, wl, t_inner_max >= 2 ? :cpu_threads : :cpu_serial, t_inner_max)
        gpu_cost_us = estimate_fluid_step_cost_us(hw, wl, :cuda, 1)
        if wl.n_fluid_3d_voxels >= 125_000 && gpu_usable && vram_avail >= fluid_vram_est && gpu_cost_us < cpu_cost_us
            fluid_backend = :cuda
            fluid_threads = 1
            vram_used += fluid_vram_est
            vram_avail -= fluid_vram_est
            rationale[:fluid] = "GPU priority #1 (3D Roofline): voxels=$(wl.n_fluid_3d_voxels) ($(round(gpu_cost_us, digits=0))us GPU < $(round(cpu_cost_us, digits=0))us CPU) on $(hw.gpu_name)"
        elseif wl.n_fluid_3d_voxels >= 512 && t_inner_max >= 2
            fluid_backend = :cpu_threads
            fluid_threads = wl.n_fluid_3d_voxels < 8_000 ? min(2, t_inner_max) : t_inner_max
            rationale[:fluid] = "Multi-threaded CPU 3D stencil/FFT ($fluid_threads threads; voxels=$(wl.n_fluid_3d_voxels) fits L3 cache / below GPU Roofline crossover)"
        else
            fluid_backend = :cpu_serial
            fluid_threads = 1
            rationale[:fluid] = "Small 3D fluid domain (voxels=$(wl.n_fluid_3d_voxels)); serial CPU avoids launch overhead"
        end
    elseif (wl.n_fluid_2d_cells >= 4_096 || wl.n_sph_particles >= 2_000) && gpu_usable && vram_avail >= fluid_vram_est
        fluid_backend = :cuda
        fluid_threads = 1
        vram_used += fluid_vram_est
        vram_avail -= fluid_vram_est
        rationale[:fluid] = "GPU priority #1: 2D cells=$(wl.n_fluid_2d_cells), SPH=$(wl.n_sph_particles) exceeds GPU crossover on $(hw.gpu_name)"
    elseif (wl.n_fluid_2d_cells >= 512 || wl.n_sph_particles >= 256) && t_inner_max >= 2
        fluid_backend = :cpu_threads
        fluid_threads = t_inner_max
        rationale[:fluid] = "Multi-threaded CPU stencil/SPH ($fluid_threads threads; grid/VRAM below GPU threshold)"
    else
        fluid_backend = :cpu_serial
        fluid_threads = 1
        rationale[:fluid] = "Small fluid domain (2D cells=$(wl.n_fluid_2d_cells), SPH=$(wl.n_sph_particles)); serial CPU avoids launch overhead"
    end

    # ── 3. Rule 2b: ABM Backend Arbitration (Second GPU Priority + Co-Location)
    abm_override = _normalize_backend_override(overrides.abm_backend, (:auto, :cpu_serial, :cpu_threads, :cuda))
    has_abm_work = (wl.n_abm_agents > 0)
    abm_vram_est = has_abm_work ?
        (UInt64(wl.n_abm_agents) * UInt64(256) + UInt64(wl.n_nav_cells) * UInt64(32) + UInt64(64 * 1024^2)) :
        UInt64(0)
    # Co-location rule: lower GPU threshold from 2,500 -> 1,000 when Fluid is already on CUDA
    abm_gpu_thresh = (fluid_backend === :cuda) ? 1_000 : 2_500

    abm_backend = :cpu_serial
    abm_threads = 1
    if abm_override === :cuda
        if gpu_usable
            abm_backend = :cuda
            abm_threads = 1
            vram_used += abm_vram_est
            vram_avail = vram_avail > abm_vram_est ? (vram_avail - abm_vram_est) : UInt64(0)
            rationale[:abm] = "User override :cuda on $(hw.gpu_name)"
        else
            abm_backend = t_inner_max >= 2 ? :cpu_threads : :cpu_serial
            abm_threads = t_inner_max
            rationale[:abm] = "Requested :cuda unavailable/disabled; fallback to $abm_backend ($abm_threads threads)"
        end
    elseif abm_override in (:cpu_serial, :cpu_threads)
        abm_backend = abm_override
        abm_threads = abm_override === :cpu_threads ? max(1, t_inner_max) : 1
        rationale[:abm] = "User override $abm_backend ($abm_threads threads)"
    elseif !has_abm_work
        abm_backend = :cpu_serial
        abm_threads = 1
        rationale[:abm] = "No active ABM crowd agents (idle)"
    elseif wl.n_abm_agents >= abm_gpu_thresh && gpu_usable && vram_avail >= abm_vram_est
        abm_backend = :cuda
        abm_threads = 1
        vram_used += abm_vram_est
        vram_avail -= abm_vram_est
        coloc_note = (fluid_backend === :cuda) ? " (co-located with GPU Fluid)" : ""
        rationale[:abm] = "N_agents=$(wl.n_abm_agents) >= $abm_gpu_thresh threshold$coloc_note on $(hw.gpu_name)"
    elseif wl.n_abm_agents >= 250 && t_inner_max >= 2
        abm_backend = :cpu_threads
        abm_threads = t_inner_max
        if wl.n_abm_agents >= abm_gpu_thresh && gpu_usable && vram_avail < abm_vram_est
            rationale[:abm] = "VRAM headroom insufficient for GPU ABM; fallback to :cpu_threads ($abm_threads threads)"
        else
            rationale[:abm] = "Medium crowd (N_agents=$(wl.n_abm_agents) in 250..$(abm_gpu_thresh-1)); :cpu_threads ($abm_threads threads)"
        end
    else
        abm_backend = :cpu_serial
        abm_threads = 1
        rationale[:abm] = "Small crowd (N_agents=$(wl.n_abm_agents) < 250); :cpu_serial avoids thread/kernel launch overhead"
    end

    # ── 4. Rule 2c: Stats Backend Arbitration ─────────────────────────────────
    stats_override = _normalize_backend_override(overrides.stats_backend, (:auto, :cpu_streaming, :cpu_threads, :gpu_ak))
    stats_backend = if stats_override !== :auto
        stats_override
    else
        :cpu_streaming
    end
    rationale[:stats] = stats_override !== :auto ?
        "User override $stats_backend" :
        "Inline O(1) Welford streaming accumulators (:cpu_streaming)"

    # ── 5. Rule 3: DES `:serial` vs. `:pdes` & Worker Thread Count ────────────
    des_override = _normalize_backend_override(overrides.des_backend, (:auto, :serial, :pdes))
    # Contention check: if both ABM and Fluid are heavily multi-threaded on a low-core CPU (< 8 cores),
    # cap DES worker threads to avoid oversubscribing the CPU cache hierarchy.
    cpu_heavy_co_solvers = (abm_backend === :cpu_threads && fluid_backend === :cpu_threads)
    t_des_cap = if cpu_heavy_co_solvers && t_inner_max < 8
        max(1, t_inner_max ÷ 2)
    else
        t_inner_max
    end

    valid_promise = isfinite(wl.min_cross_promise_s) && wl.min_cross_promise_s > 0.0
    est_win_events = valid_promise ? (wl.est_des_events_per_s * wl.min_cross_promise_s) : 0.0
    # Each PDES worker thread needs ~24 expected events per window (or >= 8 zones per worker) to amortize barrier overhead
    density_workers = max(
        Int(floor(est_win_events / 24.0)),
        wl.n_des_zones >= 24 ? (wl.n_des_zones ÷ 6) : 1,
    )
    optimal_pdes_workers = clamp(min(wl.n_submodels, t_des_cap, max(1, density_workers)), 1, max(1, t_des_cap))

    des_backend = :serial
    des_threads = 1
    des_min_win = max(24, 16 * optimal_pdes_workers)

    if des_override === :serial
        des_backend = :serial
        des_threads = 1
        rationale[:des] = "User override :serial (1 thread, FlatBinaryMinHeap)"
    elseif des_override === :pdes
        if wl.has_des_hooks
            des_backend = :serial
            des_threads = 1
            rationale[:des] = "Requested :pdes downgraded to :serial because active ZoneHooks closures require global world state"
        else
            des_backend = :pdes
            des_threads = max(1, min(wl.n_submodels, t_inner_max))
            des_min_win = max(24, 16 * des_threads)
            rationale[:des] = "User override :pdes ($des_threads threads across K=$(wl.n_submodels) SubModels)"
        end
    else
        # Automatic DES arbitration
        if wl.n_des_zones == 0
            des_backend = :serial
            des_threads = 1
            rationale[:des] = "No DES zones in scene"
        elseif replication_mode === :cpu_outer_parallel && t_inner_max == 1
            des_backend = :serial
            des_threads = 1
            rationale[:des] = "Outer replication parallelism active; inner DES set to :serial (1 thread/rep)"
        elseif wl.has_des_hooks
            des_backend = :serial
            des_threads = 1
            rationale[:des] = "ZoneHooks active; using :serial (1 thread) for global hook state safety"
        elseif wl.n_submodels < 2 || !valid_promise
            des_backend = :serial
            des_threads = 1
            rationale[:des] = "K=$(wl.n_submodels) SubModel after zero-promise contraction; :serial FlatBinaryMinHeap is optimal"
        elseif optimal_pdes_workers < 2
            des_backend = :serial
            des_threads = 1
            rationale[:des] = "Low window event density (est. $(round(est_win_events, digits=1)) ev/win, $(wl.n_des_zones) zones); :serial avoids thread barrier overhead"
        else
            des_backend = :pdes
            des_threads = optimal_pdes_workers
            des_min_win = max(24, 16 * des_threads)
            rationale[:des] = "Auto-selected :pdes ($des_threads threads across K=$(wl.n_submodels) SubModels, tau_min=$(round(wl.min_cross_promise_s, digits=3))s, est. $(round(est_win_events, digits=1)) ev/win)"
        end
    end

    return ExecutionPlan(
        replication_mode,
        replication_workers,
        des_backend,
        des_threads,
        des_min_win,
        abm_backend,
        abm_threads,
        fluid_backend,
        fluid_threads,
        stats_backend,
        vram_used,
        rationale,
    )
end

"""
    execution_plan_to_dict(plan::ExecutionPlan, hw::HardwareProfile, wl::WorkloadProfile) -> Dict{String, Any}

Serialize an `ExecutionPlan`, `HardwareProfile`, and `WorkloadProfile` into a JSON/MsgPack-ready
dictionary for telemetry and UI inspection.
"""
function execution_plan_to_dict(
    plan::ExecutionPlan,
    hw::HardwareProfile,
    wl::WorkloadProfile,
)::Dict{String, Any}
    return Dict{String, Any}(
        "replication_mode"      => String(plan.replication_mode),
        "replication_workers"   => plan.replication_workers,
        "des_backend"           => String(plan.des_backend),
        "des_threads"           => plan.des_threads,
        "des_min_window_events" => plan.des_min_window_events,
        "abm_backend"           => String(plan.abm_backend),
        "abm_threads"           => plan.abm_threads,
        "fluid_backend"         => String(plan.fluid_backend),
        "fluid_threads"         => plan.fluid_threads,
        "stats_backend"         => String(plan.stats_backend),
        "estimated_vram_bytes"  => Int64(plan.estimated_vram_bytes),
        "rationale"             => Dict{String, String}(String(k) => v for (k, v) in plan.rationale),
        "hardware" => Dict{String, Any}(
            "cpu_logical_threads" => hw.cpu_logical_threads,
            "cpu_physical_cores"  => hw.cpu_physical_cores,
            "julia_threads"       => hw.julia_threads,
            "total_ram_bytes"     => Int64(hw.total_ram_bytes),
            "free_ram_bytes"      => Int64(hw.free_ram_bytes),
            "has_cuda"            => hw.has_cuda,
            "gpu_name"            => hw.gpu_name,
            "gpu_sm_count"        => hw.gpu_sm_count,
            "gpu_total_vram"      => Int64(hw.gpu_total_vram),
            "gpu_free_vram"       => Int64(hw.gpu_free_vram),
            "is_interactive_viz"  => hw.is_interactive_viz,
        ),
        "workload" => Dict{String, Any}(
            "n_des_zones"          => wl.n_des_zones,
            "n_submodels"          => wl.n_submodels,
            "min_cross_promise_s"  => wl.min_cross_promise_s,
            "est_des_events_per_s" => wl.est_des_events_per_s,
            "has_des_hooks"        => wl.has_des_hooks,
            "n_abm_agents"         => wl.n_abm_agents,
            "has_orca"             => wl.has_orca,
            "n_nav_cells"          => wl.n_nav_cells,
            "n_fluid_2d_cells"     => wl.n_fluid_2d_cells,
            "n_sph_particles"      => wl.n_sph_particles,
            "n_replications"       => wl.n_replications,
        ),
    )
end
