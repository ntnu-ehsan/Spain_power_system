# ============================================================
# Bellman cut utilities for hydro water-value computation
# ============================================================

using CSV, DataFrames, Dates

struct BellmanCut
    a0::Float64   # slope for French reservoir volume (already folded into b)
    a1::Float64   # slope for Spanish aggregate reservoir volume [EUR/MWh]
    b::Float64    # intercept (pre-adjusted for French trajectory)
end

# Weekly stage index corresponding to the end of a study day
function bellman_stage(date_str::String, bgn_date::Date, ssv_step::Int)::Int
    uc_end = Date(date_str) + Day(1)   # 00:00 of the day after = end of study day
    hours  = convert(Dates.Hour, DateTime(uc_end) - DateTime(bgn_date)).value
    return div(hours, ssv_step)
end

# All Bellman cuts for a given stage index
function load_cuts_at_stage(bellman_file::String, stage::Int)::Vector{BellmanCut}
    df   = CSV.read(bellman_file, DataFrame)
    rows = filter(r -> r.Timestep == stage, df)
    isempty(rows) && error("No Bellman cuts found at stage $stage in $bellman_file")
    return [BellmanCut(Float64(r.a_0), Float64(r.a_1), Float64(r.b))
            for r in eachrow(rows)]
end

# Spanish aggregate reservoir volume [MWh] at 00:00 of a study date
function v_es_at_date(volume_file::String, date_str::String, bgn_date::Date)::Float64
    ts  = convert(Dates.Hour, DateTime(Date(date_str)) - DateTime(bgn_date)).value
    df  = CSV.read(volume_file, DataFrame)
    row = filter(r -> r.Timestep == ts, df)
    isempty(row) && error("Timestep $ts ($(date_str) 00:00) not found in $volume_file")
    return Float64(row[1, "Hydro|Reservoir_ES_0"])
end

# Water value (EUR/MWh) from the slope of the binding Bellman cut at V_ES
function binding_water_value(cuts::Vector{BellmanCut}, v_es::Float64)::Float64
    best = argmax(c -> c.b + c.a1 * v_es, cuts)   # returns the element, not the index
    return -best.a1   # a1 < 0  →  water value > 0
end
