# packages/SimCore/src/tables/sim_table.jl
#
# High-performance, general-purpose columnar SimTable with Copy-on-Write mutability,
# O(1) primary-key hash lookup, 2D matrix-style indexing/slicing, and CSV serialization.

"""
    SimTableRow

Lightweight row view over a `SimTable` at row index `row_idx`.
Supports property access (`row.col`), symbol indexing (`row[:col]`),
string indexing (`row["col"]`), and integer column indexing (`row[1]`).
"""
struct SimTableRow{TTable}
    table::TTable
    row_idx::Int
end

"""
    SimTable

General-purpose, column-oriented in-memory table for DES/ABM simulation parameters,
schedules, timetables, and matrices.
"""
mutable struct SimTable
    id::String
    name::String
    columns::Vector{Symbol}
    col_types::Dict{Symbol, DataType}
    data::Dict{Symbol, Vector{Any}}
    primary_key::Union{Nothing, Symbol}
    key_index::Dict{Any, Int}
    version::Int
end

function SimTable(
    id::String,
    name::String = id;
    columns::Vector{Symbol} = Symbol[],
    col_types::Dict{Symbol, DataType} = Dict{Symbol, DataType}(),
    data::Dict{Symbol, Vector{Any}} = Dict{Symbol, Vector{Any}}(),
    primary_key::Union{Nothing, Symbol} = nothing
)
    for col in columns
        if !haskey(col_types, col)
            col_types[col] = Any
        end
        if !haskey(data, col)
            data[col] = Any[]
        end
    end
    tab = SimTable(id, name, columns, col_types, data, primary_key, Dict{Any, Int}(), 1)
    rebuild_key_index!(tab)
    return tab
end

function SimTable(
    id::String,
    raw_cols::AbstractVector,
    raw_rows::AbstractVector;
    name::String = id,
    primary_key::Union{Nothing, Symbol, AbstractString} = nothing
)
    cols = Symbol[]
    col_types = Dict{Symbol, DataType}()
    data = Dict{Symbol, Vector{Any}}()

    for c_def in raw_cols
        if c_def isa AbstractDict
            c_sym = Symbol(get(c_def, "name", get(c_def, :name, "col")))
            t_str = lowercase(string(get(c_def, "type", get(c_def, :type, "any"))))
            c_type = t_str in ("float", "float64", "number") ? Float64 :
                     t_str in ("int", "int64", "integer") ? Int64 :
                     t_str in ("bool", "boolean") ? Bool :
                     t_str == "string" ? String : Any
            push!(cols, c_sym)
            col_types[c_sym] = c_type
            data[c_sym] = Any[]
        else
            c_sym = Symbol(c_def)
            push!(cols, c_sym)
            col_types[c_sym] = Any
            data[c_sym] = Any[]
        end
    end

    # Infer columns from first dictionary row if raw_cols was empty
    if isempty(cols) && !isempty(raw_rows) && first(raw_rows) isa AbstractDict
        for k in keys(first(raw_rows))
            c_sym = Symbol(k)
            push!(cols, c_sym)
            col_types[c_sym] = Any
            data[c_sym] = Any[]
        end
    end

    pk_sym = (primary_key === nothing || isempty(string(primary_key))) ? nothing : Symbol(primary_key)
    tab = SimTable(id, name; columns = cols, col_types = col_types, data = data, primary_key = pk_sym)
    for r in raw_rows
        if r isa AbstractVector || r isa AbstractDict || r isa NamedTuple
            add_row!(tab, r)
        end
    end
    return tab
end

"""
    get_table(container, table_id) -> SimTable

Retrieves a `SimTable` by ID from a simulation instance or dictionary.
"""
function get_table end
get_table(tables::AbstractDict, table_id::AbstractString) = tables[String(table_id)]
get_table(tables::AbstractDict, table_id::Symbol) = tables[String(table_id)]

function Base.copy(tab::SimTable)
    new_cols = copy(tab.columns)
    new_types = copy(tab.col_types)
    new_data = Dict{Symbol, Vector{Any}}(k => copy(v) for (k, v) in tab.data)
    new_idx = copy(tab.key_index)
    return SimTable(tab.id, tab.name, new_cols, new_types, new_data, tab.primary_key, new_idx, tab.version)
end

"""
    nrows(tab::SimTable) -> Int

Returns the number of rows in `tab`.
"""
@inline function nrows(tab::SimTable)::Int
    isempty(tab.columns) && return 0
    return length(tab.data[tab.columns[1]])
end

"""
    ncols(tab::SimTable) -> Int

Returns the number of columns in `tab`.
"""
@inline ncols(tab::SimTable)::Int = length(tab.columns)

Base.size(tab::SimTable) = (nrows(tab), ncols(tab))
Base.size(tab::SimTable, dim::Int) = dim == 1 ? nrows(tab) : (dim == 2 ? ncols(tab) : 1)
Base.length(tab::SimTable) = nrows(tab)
Base.isempty(tab::SimTable) = nrows(tab) == 0

function rebuild_key_index!(tab::SimTable)
    empty!(tab.key_index)
    pk = tab.primary_key
    if pk !== nothing && haskey(tab.data, pk)
        col_vec = tab.data[pk]
        for (i, val) in enumerate(col_vec)
            tab.key_index[val] = i
            tab.key_index[string(val)] = i
        end
    end
    return tab
end

# ── SimTableRow Indexing & Property Access ────────────────────────────────────

function Base.getproperty(row::SimTableRow, sym::Symbol)
    if sym === :table || sym === :row_idx
        return getfield(row, sym)
    end
    return get_cell(getfield(row, :table), getfield(row, :row_idx), sym)
end

function Base.setproperty!(row::SimTableRow, sym::Symbol, val)
    set_cell!(getfield(row, :table), getfield(row, :row_idx), sym, val)
    return val
end

Base.getindex(row::SimTableRow, col::Symbol) = get_cell(getfield(row, :table), getfield(row, :row_idx), col)
Base.getindex(row::SimTableRow, col::AbstractString) = get_cell(getfield(row, :table), getfield(row, :row_idx), Symbol(col))
Base.getindex(row::SimTableRow, col_idx::Int) = get_cell(getfield(row, :table), getfield(row, :row_idx), getfield(row, :table).columns[col_idx])

function Base.NamedTuple(row::SimTableRow)
    tab = getfield(row, :table)
    r = getfield(row, :row_idx)
    ks = Tuple(tab.columns)
    vs = Tuple(tab.data[c][r] for c in tab.columns)
    return NamedTuple{ks}(vs)
end

# ── Helper Functions: Row, Column, Cell, Matrix & Query API ───────────────────

"""
    get_row(tab::SimTable, row_idx::Int) -> SimTableRow

Returns a lightweight `SimTableRow` view for 1-based row `row_idx`.
"""
@inline function get_row(tab::SimTable, row_idx::Int)::SimTableRow{SimTable}
    @boundscheck if row_idx < 1 || row_idx > nrows(tab)
        throw(BoundsError(tab, (row_idx, :)))
    end
    return SimTableRow(tab, row_idx)
end

"""
    get_row_by_key(tab::SimTable, key) -> Union{SimTableRow{SimTable}, Nothing}

O(1) primary-key lookup returning the matching `SimTableRow`, or `nothing` if not found.
"""
@inline function get_row_by_key(tab::SimTable, key)
    idx = get(tab.key_index, key, 0)
    if idx == 0 && !(key isa String)
        idx = get(tab.key_index, string(key), 0)
    end
    return idx > 0 ? SimTableRow(tab, idx) : nothing
end

"""
    get_col(tab::SimTable, col::Union{Symbol, AbstractString, Int}) -> Vector{Any}

Returns the column vector for `col`.
"""
@inline function get_col(tab::SimTable, col::Symbol)::Vector{Any}
    if !haskey(tab.data, col)
        throw(KeyError(col))
    end
    return tab.data[col]
end
@inline get_col(tab::SimTable, col::AbstractString) = get_col(tab, Symbol(col))
@inline get_col(tab::SimTable, col_idx::Int) = get_col(tab, tab.columns[col_idx])

"""
    get_cell(tab::SimTable, row_idx::Int, col::Union{Symbol, AbstractString, Int})

Returns the scalar element at `(row_idx, col)`.
"""
@inline function get_cell(tab::SimTable, row_idx::Int, col::Symbol)
    col_vec = get_col(tab, col)
    @boundscheck if row_idx < 1 || row_idx > length(col_vec)
        throw(BoundsError(tab, (row_idx, col)))
    end
    return col_vec[row_idx]
end
@inline get_cell(tab::SimTable, row_idx::Int, col::AbstractString) = get_cell(tab, row_idx, Symbol(col))
@inline get_cell(tab::SimTable, row_idx::Int, col_idx::Int) = get_cell(tab, row_idx, tab.columns[col_idx])

"""
    set_cell!(tab::SimTable, row_idx::Int, col::Union{Symbol, AbstractString, Int}, val)

Mutates the cell at `(row_idx, col)` in-place, bumping `tab.version` and updating primary key index if needed.
"""
@inline function set_cell!(tab::SimTable, row_idx::Int, col::Symbol, val)
    col_vec = get_col(tab, col)
    @boundscheck if row_idx < 1 || row_idx > length(col_vec)
        throw(BoundsError(tab, (row_idx, col)))
    end
    col_vec[row_idx] = val
    tab.version += 1
    if tab.primary_key === col
        rebuild_key_index!(tab)
    end
    return val
end
@inline set_cell!(tab::SimTable, row_idx::Int, col::AbstractString, val) = set_cell!(tab, row_idx, Symbol(col), val)
@inline set_cell!(tab::SimTable, row_idx::Int, col_idx::Int, val) = set_cell!(tab, row_idx, tab.columns[col_idx], val)

"""
    add_row!(tab::SimTable, row_vals::Union{AbstractVector, AbstractDict, NamedTuple})

Appends a new row to `tab`.
"""
function add_row!(tab::SimTable, row_vals::AbstractVector)
    if length(row_vals) != length(tab.columns)
        throw(DimensionMismatch("Expected $(length(tab.columns)) values, got $(length(row_vals))"))
    end
    for (j, col) in enumerate(tab.columns)
        push!(tab.data[col], row_vals[j])
    end
    tab.version += 1
    rebuild_key_index!(tab)
    return nrows(tab)
end

function add_row!(tab::SimTable, row_dict::Union{AbstractDict, NamedTuple})
    for col in tab.columns
        val = if row_dict isa NamedTuple
            haskey(row_dict, col) ? row_dict[col] : nothing
        else
            haskey(row_dict, col) ? row_dict[col] : get(row_dict, string(col), nothing)
        end
        push!(tab.data[col], val)
    end
    tab.version += 1
    rebuild_key_index!(tab)
    return nrows(tab)
end

# ── 2D Matrix-Style Indexing & Slicing (`tab[r, c]`, `tab[r, :]`, `tab[:, c]`) ─

Base.getindex(tab::SimTable, r::Int, ::Colon) = get_row(tab, r)
Base.getindex(tab::SimTable, ::Colon, c::Union{Symbol, AbstractString, Int}) = get_col(tab, c)
Base.getindex(tab::SimTable, r::Int, c::Union{Symbol, AbstractString, Int}) = get_cell(tab, r, c)

function Base.getindex(tab::SimTable, key::AbstractString)
    row = get_row_by_key(tab, key)
    row === nothing && throw(KeyError(key))
    return row
end

function Base.getindex(
    tab::SimTable,
    r_idxs::Union{AbstractVector{Int}, UnitRange{Int}, Colon},
    c_sel::Union{AbstractVector, Colon}
)::SimTable
    rows = r_idxs isa Colon ? (1:nrows(tab)) : r_idxs
    cols = if c_sel isa Colon
        copy(tab.columns)
    else
        Symbol[c isa Int ? tab.columns[c] : Symbol(c) for c in c_sel]
    end
    sub_types = Dict{Symbol, DataType}(c => get(tab.col_types, c, Any) for c in cols)
    sub_data = Dict{Symbol, Vector{Any}}(c => Any[tab.data[c][r] for r in rows] for c in cols)
    pk = (tab.primary_key !== nothing && tab.primary_key in cols) ? tab.primary_key : nothing
    return SimTable(tab.id * "_slice", tab.name, cols, sub_types, sub_data, pk)
end

Base.setindex!(tab::SimTable, val, r::Int, c::Union{Symbol, AbstractString, Int}) = set_cell!(tab, r, c, val)

"""
    to_matrix(tab::SimTable, cols::AbstractVector = tab.columns; rows = 1:nrows(tab)) -> Matrix{Float64}

Extracts a 2D `Matrix{Float64}` slice from the specified numerical columns and rows.
"""
function to_matrix(tab::SimTable, cols_pos::Union{Nothing, AbstractVector} = nothing; rows = 1:nrows(tab), cols::Union{Nothing, AbstractVector} = nothing)::Matrix{Float64}
    eff_cols = cols !== nothing ? cols : (cols_pos !== nothing ? cols_pos : tab.columns)
    row_indices = rows isa Colon ? (1:nrows(tab)) : collect(rows)
    col_syms = Symbol[c isa Int ? tab.columns[c] : Symbol(c) for c in eff_cols]
    nr = length(row_indices)
    nc = length(col_syms)
    mat = zeros(Float64, nr, nc)
    for (j, c) in enumerate(col_syms)
        col_vec = get_col(tab, c)
        for (i, r) in enumerate(row_indices)
            v = col_vec[r]
            mat[i, j] = v isa Real ? Float64(v) : (tryparse(Float64, string(v)) !== nothing ? tryparse(Float64, string(v)) : 0.0)
        end
    end
    return mat
end

"""
    find_rows(tab::SimTable, predicate::Function) -> Vector{Int}
    find_rows(tab::SimTable, pair::Pair) -> Vector{Int}

Returns all 1-based row indices matching `predicate(row)` or `col => value`.
"""
function find_rows(tab::SimTable, predicate::Function)::Vector{Int}
    matches = Int[]
    nr = nrows(tab)
    for r in 1:nr
        if predicate(SimTableRow(tab, r))
            push!(matches, r)
        end
    end
    return matches
end

function find_rows(tab::SimTable, pair::Pair)::Vector{Int}
    col = Symbol(first(pair))
    target_val = last(pair)
    col_vec = get_col(tab, col)
    matches = Int[]
    for (r, v) in enumerate(col_vec)
        if v == target_val || string(v) == string(target_val)
            push!(matches, r)
        end
    end
    return matches
end

"""
    find_first(tab::SimTable, cond) -> Union{SimTableRow{SimTable}, Nothing}

Returns the first matching `SimTableRow` or `nothing`.
"""
function find_first(tab::SimTable, cond)
    idxs = find_rows(tab, cond)
    return isempty(idxs) ? nothing : SimTableRow(tab, idxs[1])
end

"""
    get_next_scheduled_row(tab::SimTable, current_time::Real; time_col::Symbol = :sched_time) -> Union{SimTableRow{SimTable}, Nothing}

Finds the next row whose `time_col` value is `>= current_time` (with minimum scheduled timestamp).
"""
function get_next_scheduled_row(tab::SimTable, current_time::Real; time_col::Symbol = :sched_time)
    !haskey(tab.data, time_col) && return nothing
    col_vec = tab.data[time_col]
    best_r = 0
    best_t = Inf
    t_now = Float64(current_time)
    for (r, raw_v) in enumerate(col_vec)
        t_val = raw_v isa Real ? Float64(raw_v) : something(tryparse(Float64, string(raw_v)), Inf)
        if t_val >= t_now && t_val < best_t
            best_t = t_val
            best_r = r
        end
    end
    return best_r > 0 ? SimTableRow(tab, best_r) : nothing
end

# ── CSV Parsing & Serialization ───────────────────────────────────────────────

function _infer_csv_cell(raw_s::AbstractString)
    s = strip(raw_s)
    if (startswith(s, '"') && endswith(s, '"')) || (startswith(s, '\'') && endswith(s, '\''))
        return String(s[2:end-1])
    end
    iv = tryparse(Int64, s)
    iv !== nothing && return iv
    fv = tryparse(Float64, s)
    fv !== nothing && return fv
    if lowercase(s) == "true"
        return true
    elseif lowercase(s) == "false"
        return false
    end
    return String(s)
end

"""
    parse_csv_table(id::String, csv_text::AbstractString; name::String = id, primary_key = nothing) -> SimTable

Parses CSV text into a typed `SimTable`.
"""
function parse_csv_table(
    id::String,
    csv_text::AbstractString;
    name::String = id,
    primary_key::Union{Nothing, Symbol, AbstractString} = nothing
)::SimTable
    lines = filter(l -> !isempty(strip(l)), split(replace(csv_text, "\r\n" => "\n"), '\n'))
    if isempty(lines)
        return SimTable(id, name)
    end
    headers = [Symbol(strip(h)) for h in split(lines[1], ',')]
    data = Dict{Symbol, Vector{Any}}(h => Any[] for h in headers)
    for line_idx in 2:length(lines)
        parts = split(lines[line_idx], ',')
        for (col_idx, h) in enumerate(headers)
            cell_val = col_idx <= length(parts) ? _infer_csv_cell(parts[col_idx]) : ""
            push!(data[h], cell_val)
        end
    end
    pk_sym = primary_key === nothing || isempty(string(primary_key)) ? nothing : Symbol(primary_key)
    return SimTable(id, name; columns = headers, data = data, primary_key = pk_sym)
end

"""
    table_to_csv(tab::SimTable) -> String

Serializes a `SimTable` to standard CSV format.
"""
function table_to_csv(tab::SimTable)::String
    isempty(tab.columns) && return ""
    io = IOBuffer()
    println(io, join(string.(tab.columns), ","))
    nr = nrows(tab)
    for r in 1:nr
        vals = [string(tab.data[c][r]) for c in tab.columns]
        println(io, join(vals, ","))
    end
    return String(take!(io))
end
