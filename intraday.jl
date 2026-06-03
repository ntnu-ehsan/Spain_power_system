# ============================================================
# Spain Power System — Intraday dispatch reader (redispatch input)
# ============================================================
# Reads the continuous-intraday (copper-plate) dispatch produced by
# the SMS++/POMATO market model and exposes it as the initial
# operating point for the AC OPF redispatch.
#
# The market model writes one results folder per delivery hour, each
# holding a rolling 24-timestep horizon.  The dispatch actually
# delivered in hour h is the row with Timestep == h (0-based), taken
# from the folder for that hour — mirroring the extraction used in the
# upstream project:
#
#   file   = results_ij[_d2]_{hour}_pomatwo/ActivePower/ActivePowerOUT.csv
#   row    = df[df.Timestep == hour-1]
#
# Column names are unit_ids (e.g. "G0021") that match generations.csv;
# the extra "SlackUnit_*" columns of the market model are ignored.
#
# Usage (from run_opf.jl, after data_preparation.jl is included):
#   disp = load_intraday_dispatch("2024-12-02")   # unit_id => 24 MW values
#   pg_h = intraday_hour(disp, 13)                 # unit_id => MW at hour 13
# ============================================================

using CSV, DataFrames

const INTRADAY_DIR = joinpath(DATA, "smspp_out", "nutsx")

# Map a study date to the market-model folder pattern for delivery hour `h`
# (1..24).  Each modelled day uses a distinct intraday result set.
function intraday_folder(date_str::String, h::Int)::String
    if date_str == "2024-07-08"
        return "results_ij_$(h)_pomatwo"
    elseif date_str == "2024-12-02"
        return "results_ij_d2_$(h)_pomatwo"
    else
        error("No intraday dataset mapped for date $date_str (see intraday_folder)")
    end
end

# Read the full-day intraday dispatch for one study date.
# Returns Dict{unit_id => Vector{Float64}(24)} in MW, index h+1 = hour h.
function load_intraday_dispatch(date_str::String)::Dict{String,Vector{Float64}}
    dispatch = Dict{String,Vector{Float64}}()
    for h in 1:24
        path = joinpath(INTRADAY_DIR, intraday_folder(date_str, h),
                        "ActivePower", "ActivePowerOUT.csv")
        isfile(path) || error("Intraday file not found: $path")
        df  = CSV.read(path, DataFrame)
        row = df[df.Timestep .== h - 1, :]
        nrow(row) == 1 ||
            error("Expected exactly one Timestep=$(h-1) row in $path, got $(nrow(row))")
        for name in names(df)
            name == "Timestep"        && continue
            startswith(name, "G")     || continue   # generator units only (skip SlackUnit_*)
            v   = row[1, name]
            vec = get!(dispatch, name, zeros(Float64, 24))
            vec[h] = ismissing(v) ? 0.0 : Float64(v)
        end
    end
    return dispatch
end

# Slice a full-day dispatch into the per-unit set-points for one hour (0..23).
# Returns Dict{unit_id => MW}.
function intraday_hour(dispatch::Dict{String,Vector{Float64}}, hour::Int)::Dict{String,Float64}
    Dict(u => vec[hour + 1] for (u, vec) in dispatch)
end
