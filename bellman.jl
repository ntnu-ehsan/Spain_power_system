# ============================================================
# Bellman cut utilities for hydro water-value computation
# ============================================================

using CSV, DataFrames, Dates

# One cut of the weekly cost-to-go produced by the mid-term model:
#     cost-to-go(V_FR, V_ES) = max_cuts  a_0·V_FR + a_1·V_ES + b
# The market chain models Spain alone — the French reservoir is not a decision
# variable here — so a_0·V_FR is a per-cut constant.  load_cuts_at_stage folds
# it into `b` at the French volume of the study day, which leaves the cuts
# one-dimensional in V_ES (as every consumer assumes) without distorting which
# cut binds.  Dropping the term instead would compare cuts on unequal footing:
# a_0 is nonzero in ~97% of cuts and spans −93…0 EUR/MWh across the cut sets,
# and omitting it selects a different cut on 24 of the 78 GoRES weekly stages.
struct BellmanCut
    a0::Float64   # slope for French reservoir volume [EUR/MWh] (kept for reference)
    a1::Float64   # slope for Spanish aggregate reservoir volume [EUR/MWh]
    b::Float64    # intercept, with the a_0·V_FR term already folded in
end

# Weekly stage index corresponding to the end of a study day
function bellman_stage(date_str::String, bgn_date::Date, ssv_step::Int)::Int
    uc_end = Date(date_str) + Day(1)   # 00:00 of the day after = end of study day
    hours  = convert(Dates.Hour, DateTime(uc_end) - DateTime(bgn_date)).value
    return div(hours, ssv_step)
end

# All Bellman cuts for a given stage index, with the French-volume term folded
# into the intercept at `v_fr` (the French reservoir volume of the study day,
# taken at the same instant as the V_ES the cuts are evaluated against).
function load_cuts_at_stage(bellman_file::String, stage::Int,
                            v_fr::Float64)::Vector{BellmanCut}
    df   = CSV.read(bellman_file, DataFrame)
    rows = filter(r -> r.Timestep == stage, df)
    isempty(rows) && error("No Bellman cuts found at stage $stage in $bellman_file")
    return [BellmanCut(Float64(r.a_0), Float64(r.a_1),
                       Float64(r.b) + Float64(r.a_0) * v_fr)
            for r in eachrow(rows)]
end

# Reservoir volume [MWh] held in `column` at 00:00 of a study date
function _volume_at_date(volume_file::String, date_str::String, bgn_date::Date,
                         column::String)::Float64
    ts  = convert(Dates.Hour, DateTime(Date(date_str)) - DateTime(bgn_date)).value
    df  = CSV.read(volume_file, DataFrame)
    row = filter(r -> r.Timestep == ts, df)
    isempty(row) && error("Timestep $ts ($(date_str) 00:00) not found in $volume_file")
    return Float64(row[1, column])
end

# Spanish / French aggregate reservoir volume [MWh] at 00:00 of a study date
v_es_at_date(volume_file::String, date_str::String, bgn_date::Date) =
    _volume_at_date(volume_file, date_str, bgn_date, "Hydro|Reservoir_ES_0")
v_fr_at_date(volume_file::String, date_str::String, bgn_date::Date) =
    _volume_at_date(volume_file, date_str, bgn_date, "Hydro|Reservoir_FR_0")

# Water value (EUR/MWh) from the slope of the binding Bellman cut at V_ES
function binding_water_value(cuts::Vector{BellmanCut}, v_es::Float64)::Float64
    best = argmax(c -> c.b + c.a1 * v_es, cuts)   # returns the element, not the index
    return -best.a1   # a1 < 0  →  water value > 0
end
