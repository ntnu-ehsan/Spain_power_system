# ============================================================
# Spain Power System — AC OPF Solver (multi-hour)
# ============================================================
# Runs an AC OPF (Ipopt) for every hour of two target days:
#   • 2024-07-08  (summer)
#   • 2024-12-02  (winter)
#
# Hydro reservoir opportunity cost comes from Bellman cuts
# produced by a long-term scheduling model.  Two methods are
# available; select via config.toml → [bellman] method:
#
#   "constant"  — fixed water value per day (fast)
#   "piecewise" — all cuts coupled across 24 hours (accurate)
#
# Usage:
#   julia run_opf.jl
# ============================================================

import Pkg
Pkg.activate(@__DIR__)
Pkg.instantiate()

using PowerModels, Ipopt, Gurobi, JuMP, CSV, DataFrames, Printf, Dates, Statistics, TOML

if startswith(lowercase(get(ENV, "IPOPT_LINEAR_SOLVER", "ma57")), "ma")
    import HSL_jll
end

# Single Gurobi environment reused across all copper-plate solves so the license
# is read just once (re-creating an env per model is slow and spams the log).
const GRB_ENV = Gurobi.Env()

include("data_preparation.jl")
include("bellman.jl")
include("crossborder.jl")
include("da.jl")
include("empire_scenario.jl")
include("empire_nodal.jl")
include("week_sampling.jl")
include("week_profiles.jl")

# ── 1. Config ────────────────────────────────────────────────
cfg = TOML.parsefile(joinpath(@__DIR__, "config.toml"))

const BELLMAN_BGN_DATE = Date(cfg["bellman"]["bgn_date"])
const BELLMAN_SSV_STEP = cfg["bellman"]["ssv_step"]

# [scenario]: label != "2024" swaps in the EMPIRE future system — the unit
# fleet is scaled per tech, marginal costs are replaced (incl. CO2 adder),
# the ES hourly profiles are rescaled, the Li-Ion BESS fleet is added, the
# Bellman inputs come from the suffixed midterm outputs, and all results go
# to results/<label>/ (see empire_scenario.jl and config.toml).
const SCEN_ACTIVE = empire_active(cfg)
const SCEN_LABEL  = empire_label(cfg)
const EMP           = SCEN_ACTIVE ? load_empire_scenario(cfg)  : nothing
const UNIT_SCALE    = SCEN_ACTIVE ? empire_unit_scale(EMP)     : nothing
const COST_OVERRIDE = SCEN_ACTIVE ? empire_cost_override(EMP)  : nothing
# [scenario].disaggregation: "nodal" (default) maps the EMPIRE expansion onto
# the grid at NUTS3 resolution — per-unit capacity factors, greenfield units,
# intra-ES corridor reinforcement of line ratings, and regional BESS siting
# (empire_nodal.jl).  "zonal" keeps the original national per-tech scaling.
const NODAL_ACTIVE  = SCEN_ACTIVE &&
    lowercase(String(get(cfg["scenario"], "disaggregation", "nodal"))) == "nodal"
const NODAL         = NODAL_ACTIVE ? build_nodal_disaggregation(cfg, EMP) : nothing
const UNIT_SCALE_ID = NODAL_ACTIVE ? NODAL.unit_scale : nothing
const EXTRA_UNITS   = NODAL_ACTIVE ? NODAL.new_units  : nothing
const LINE_SCALE    = NODAL_ACTIVE ? NODAL.line_scale : nothing
const EXTRA_LINES   = NODAL_ACTIVE ? NODAL.new_lines  : nothing
const BESS_UNITS    = NODAL_ACTIVE ? NODAL.bess :
                      SCEN_ACTIVE  ? empire_bess_units(EMP) : nothing
const ES_LOAD_SCALE  = SCEN_ACTIVE ? EMP.load_scale_es                    : 1.0
const ES_SOLAR_SCALE = SCEN_ACTIVE ? get(EMP.growth, "Solar", 1.0)        : 1.0
const ES_WIND_SCALE  = SCEN_ACTIVE ? get(EMP.growth, "Wind onshore", 1.0) : 1.0

# Scenario runs read the cost-to-go of the matching midterm SDDP run (the
# suffixed [midterm4] outputs); the 2024 run keeps the [bellman] files.
const BELLMAN_FILE = joinpath(@__DIR__, SCEN_ACTIVE ?
    empire_suffixed(cfg["midterm4"]["cuts_out"], cfg)   : cfg["bellman"]["bellman_file"])
const VOLUME_FILE  = joinpath(@__DIR__, SCEN_ACTIVE ?
    empire_suffixed(cfg["midterm4"]["volume_out"], cfg) : cfg["bellman"]["volume_file"])

const VOLTAGE_BAND       = Float64(get(get(cfg, "network", Dict()), "voltage_band", 0.05))
const LINE_RATING_FACTOR = Float64(get(get(cfg, "network", Dict()), "line_rating_factor", 0.70))

const GEN_BUS_VCTRL = get(get(cfg, "network", Dict()), "gen_bus_voltage_control", false)
const GEN_BUS_VMIN  = Float64(get(get(cfg, "network", Dict()), "gen_bus_vmin", 0.98))
const GEN_BUS_VMAX  = Float64(get(get(cfg, "network", Dict()), "gen_bus_vmax", 1.03))

const REACTORS_ENABLED   = get(get(cfg, "reactors", Dict()), "enabled", true)
const REACTOR_PCT        = Float64(get(get(cfg, "reactors", Dict()), "in_service_pct", 100.0))

const LOAD_PF            = Float64(get(get(cfg, "load", Dict()), "power_factor", 1.0))

const APPARENT_POWER_LIMIT = get(get(cfg, "generators", Dict()), "apparent_power_limit", true)
const RATED_PF             = Float64(get(get(cfg, "generators", Dict()), "rated_power_factor", 0.90))
const RENEWABLE_PF         = Float64(get(get(cfg, "generators", Dict()), "renewable_power_factor", 0.95))
if SCEN_ACTIVE
    @printf "Scenario       : %s (EMPIRE period %d, CO2 %.1f EUR/t)\n" SCEN_LABEL EMP.period EMP.co2_price
    @printf "                 load ×%.3f | solar ×%.3f | wind ×%.3f | BESS %.0f MW / %.0f MWh\n" ES_LOAD_SCALE ES_SOLAR_SCALE ES_WIND_SCALE EMP.storage["ES"].bess_mw EMP.storage["ES"].bess_mwh
    if NODAL_ACTIVE
        @printf "                 NUTS3 nodal disaggregation: %d unit factors | %d new units (%.0f MW) | %d reinforced lines | %d new corridors | %d BESS sites\n" length(NODAL.unit_scale) nrow(NODAL.new_units) sum(NODAL.new_units.capacity_mw; init = 0.0) length(NODAL.line_scale) nrow(NODAL.new_lines) length(NODAL.bess)
    else
        println("                 zonal disaggregation (national per-tech scaling)")
    end
end
@printf "Voltage band   : ±%.1f %% (%.2f–%.2f pu)\n" (100 * VOLTAGE_BAND) (1 - VOLTAGE_BAND) (1 + VOLTAGE_BAND)
@printf "Line rating    : %.0f %% of nameplate\n" (100 * LINE_RATING_FACTOR)

const CROSSBORDER = get(get(cfg, "crossborder", Dict()), "enabled", false)
@printf "Cross-border   : %s\n" (CROSSBORDER ? "ON" : "OFF")

# ── Market-chain stages ──────────────────────────────────────
# Stage 1 (DA):  copper-plate, 24h Bellman-coupled, DA forecast (-12h) data.
# Stage 2-4 (ID2/ID3/CID): same copper-plate formulation, later-gate forecast
#                data, Nuclear fixed at DA.
# Stage 5 (BAL): same copper-plate formulation, balancing (BE) data, Nuclear
#                fixed at DA; anchored to the CID schedule.
# Stage 6 (RD):  AC OPF anchored to BAL; Nuclear/Biomass/Coal/ROR frozen at BAL (=DA) values;
#                BESS free within ±rated power, anchored to its BAL schedule.
const DA_ENABLED  = get(get(cfg, "da",         Dict()), "enabled", true)
const NUCLEAR_MIN_FRAC = Float64(get(get(cfg, "da", Dict()), "nuclear_min_gen_frac", 0.0))
const ID2_ENABLED = get(get(cfg, "id2",        Dict()), "enabled", true)
const ID3_ENABLED = get(get(cfg, "id3",        Dict()), "enabled", true)
const CID_ENABLED = get(get(cfg, "cid",        Dict()), "enabled", true)
const BAL_ENABLED = get(get(cfg, "balancing",  Dict()), "enabled", true)
const RD_ENABLED  = get(get(cfg, "redispatch", Dict()), "enabled", true)
const RD_WATER_VALUE = lowercase(get(get(cfg, "redispatch", Dict()), "water_value", "constant"))
const RD_OBJECTIVE   = lowercase(get(get(cfg, "redispatch", Dict()), "objective", "quadratic"))
const ANCHOR_WEIGHT  = Float64(get(get(cfg, "redispatch", Dict()), "anchor_weight", 0.0))
# [redispatch].power_flow: "AC" → full nonlinear ACPPowerModel (voltages, reactive
# power, MVA limits); "DC" → linear DCPPowerModel (active power + angles only, the
# reactive/voltage knobs become inert).  Selects the PowerModels formulation used
# by every redispatch solve (constant and piecewise paths).
const RD_PF_MODEL  = uppercase(get(get(cfg, "redispatch", Dict()), "power_flow", "AC"))
const RD_PM_TYPE   = RD_PF_MODEL == "DC" ? PowerModels.DCPPowerModel : PowerModels.ACPPowerModel

# ── Standalone load-flow / single-hour options ───────────────────────────────
# [redispatch].from_saved: run ONLY the network load flow (redispatch), reading
# the anchor schedule from a previous run's <stage>_dispatch.csv in RESULTS
# instead of re-clearing the market stages.  "" = run the full chain.  A stage
# name ("DA"|"ID2"|"ID3"|"CID"|"BAL") skips stages 1–5 and anchors the load flow
# to that saved schedule.  Bellman water values are recomputed here — that is
# cheap and independent of the market clearing.
const RD_FROM_SAVED        = uppercase(strip(get(get(cfg, "redispatch", Dict()), "from_saved", "")))
const RD_FROM_SAVED_ACTIVE = RD_FROM_SAVED != ""
const RUN_MARKET           = !RD_FROM_SAVED_ACTIVE
RD_FROM_SAVED ∈ ("", "DA", "ID2", "ID3", "CID", "BAL") ||
    error("config.toml: [redispatch].from_saved must be \"\" or one of DA/ID2/ID3/CID/BAL")

# [redispatch].only: restrict the load flow to a single delivery hour (or day).
# "" = every hour of every TARGET_DAY.  "2024-07-08 14" = that date+hour only.
# "2024-07-08" = all 24 hours of that day only.
const RD_ONLY = String(strip(get(get(cfg, "redispatch", Dict()), "only", "")))
const RD_ONLY_DATE, RD_ONLY_HOUR = let
    if RD_ONLY == ""
        (nothing, nothing)
    else
        parts = split(RD_ONLY)
        (String(parts[1]), length(parts) >= 2 ? parse(Int, parts[2]) : nothing)
    end
end

# Market-stage dependency checks apply only when the market chain actually runs.
if RUN_MARKET
    ID2_ENABLED && !DA_ENABLED  && error("config.toml: [id2].enabled requires [da].enabled")
    ID3_ENABLED && !ID2_ENABLED && error("config.toml: [id3].enabled requires [id2].enabled")
    CID_ENABLED && !DA_ENABLED  && error("config.toml: [cid].enabled requires [da].enabled")
    BAL_ENABLED && !DA_ENABLED  && error("config.toml: [balancing].enabled requires [da].enabled")
    RD_ENABLED  && !DA_ENABLED  && error("config.toml: [redispatch].enabled requires [da].enabled")
end
RD_FROM_SAVED_ACTIVE && !RD_ENABLED &&
    error("config.toml: [redispatch].from_saved is set but [redispatch].enabled = false")
RD_ONLY_HOUR !== nothing && RD_WATER_VALUE == "piecewise" &&
    error("config.toml: [redispatch].only with a single hour needs water_value=\"constant\" (piecewise couples all 24 h)")
RD_WATER_VALUE ∈ ("constant", "piecewise") ||
    error("config.toml: [redispatch].water_value must be \"constant\" or \"piecewise\"")
RD_OBJECTIVE ∈ ("quadratic", "cost_weighted") ||
    error("config.toml: [redispatch].objective must be \"quadratic\" or \"cost_weighted\"")
RD_PF_MODEL ∈ ("AC", "DC") ||
    error("config.toml: [redispatch].power_flow must be \"AC\" or \"DC\"")

rd_anchor_label() = RD_FROM_SAVED_ACTIVE ? "$(RD_FROM_SAVED) (saved)" :
                    BAL_ENABLED  ? "BAL"  :
                    CID_ENABLED  ? "CID"  :
                    ID3_ENABLED  ? "ID3"  :
                    ID2_ENABLED  ? "ID2"  : "DA"
@printf "Day-ahead      : %s\n" (DA_ENABLED  ? "ON (copper-plate, 24h Bellman-coupled)" : "OFF")
@printf "Intraday (ID2) : %s\n" (ID2_ENABLED ? "ON (copper-plate, Nuclear fixed at DA)" : "OFF")
@printf "Intraday (ID3) : %s\n" (ID3_ENABLED ? "ON (copper-plate, Nuclear fixed at DA)" : "OFF")
@printf "Intraday (CID) : %s\n" (CID_ENABLED ? "ON (copper-plate, Nuclear fixed at DA)" : "OFF")
@printf "Balancing      : %s\n" (BAL_ENABLED ? "ON (copper-plate, Nuclear fixed at DA)" : "OFF")
@printf "Redispatch     : %s\n" (RD_ENABLED  ?
    @sprintf("ON  anchor=%s  power_flow=%s  water_value=%s  objective=%s  w=%.4g",
             rd_anchor_label(), RD_PF_MODEL, RD_WATER_VALUE, RD_OBJECTIVE, ANCHOR_WEIGHT) : "OFF")
RD_FROM_SAVED_ACTIVE &&
    @printf "                 standalone load flow: market stages skipped, anchor read from %s_dispatch.csv in the results folder\n" lowercase(RD_FROM_SAVED)
RD_ONLY != "" &&
    @printf "                 restricted to: %s\n" RD_ONLY

# ── 2. Load ES profiles ───────────────────────────────────────────────────────
# Actual MW at each stage = scale_factor × base_MW, where:
#   base_MW    : ES_old col "-12" (day-ahead baseline, MW)
#   scale_factor: stage column (DA/ID2/ID3/CID) from the new ES/ files (0–1 range)
# DA scale factors are always 1.0, so DA profiles equal the ES_old -12 baseline.
# Stages modelled: DA → ID2 → ID3 → CID → Balancing (BE) → Redispatch.
TARGET_DAYS = ["2024-07-08", "2024-12-02"]
# [weeks]: sampled multi-week horizon (week_sampling.jl).  The persisted (or
# freshly drawn, when resample = true) week sample replaces the two fixed 2024
# study days; each sampled week is 7 SDDP-calendar days, so the Bellman
# stage/cut/volume lookups below work unchanged.
const WEEKS_ACTIVE = get(get(cfg, "weeks", Dict()), "enabled", false)
const WEEK_KEY     = WEEKS_ACTIVE ? load_or_sample_weeks(cfg) : nothing
if WEEKS_ACTIVE
    SCEN_ACTIVE || error("config.toml: [weeks] needs an EMPIRE scenario " *
                         "([scenario].label != \"2024\") for the ScenarioData weather")
    TARGET_DAYS = week_study_days(WEEK_KEY)
    println("Week sample    : $(nrow(WEEK_KEY)) weeks " *
            (get(cfg["weeks"], "resample", false) ? "(fresh draw)" : "(from key file)"))
    for r in eachrow(WEEK_KEY)
        @printf "  slot %d : study %s (SDDP week %d) | weather %s (climate year %d, rows %d-%d)\n" r.slot Dates.format(r.study_start, "yyyy-mm-dd") r.week_slot Dates.format(r.data_start, "yyyy-mm-dd") r.climate_year r.row_start (r.row_start + WEEK_HOURS - 1)
    end
    # crossborder.csv only covers the two 2024 study days; the sampled horizon
    # gets its exchange from the 4-zone DA clearing once that stage lands.
    CROSSBORDER && error("[weeks]: [crossborder] fixed injections exist only for " *
                         "the 2024 study days — disable it for sampled weeks")
end
# [redispatch].only may pin the whole run to a single day so the market stages,
# Bellman pre-compute and load flow all skip the other TARGET_DAY.
if RD_ONLY_DATE !== nothing
    TARGET_DAYS = filter(==(RD_ONLY_DATE), TARGET_DAYS)
    isempty(TARGET_DAYS) &&
        error("config.toml: [redispatch].only date \"$RD_ONLY_DATE\" is not one of the TARGET_DAYS")
end
ES_OLD_DIR  = joinpath(@__DIR__, "Data", "ES_old")
ES_NEW_DIR  = joinpath(@__DIR__, "Data", "ES")

function es_filename(date_str)
    d = Date(date_str)
    "$(day(d))_$(month(d))_$(year(d)).csv"
end

# Returns 24-element vector of MW values for a given stage.
# new_resource: folder name under Data/ES/      (e.g. "Wind Onshore")
# old_resource: folder name under Data/ES_old/  (e.g. "Wind")
# Scenario runs rescale the 2024-actual MW level by the EMPIRE growth factor
# (load → annual-demand ratio, solar/wind → installed-capacity ratio); the
# hourly shape and the per-stage forecast factors are kept.
profile_scale(new_resource) = new_resource == "load"  ? ES_LOAD_SCALE  :
                              new_resource == "Solar" ? ES_SOLAR_SCALE : ES_WIND_SCALE
function load_scaled_col(date_str, new_resource, old_resource, stage_col)
    base_df = CSV.read(joinpath(ES_OLD_DIR, old_resource, es_filename(date_str)), DataFrame)
    sort!(base_df, :delivery_time)
    base_mw = Float64.(base_df[!, "-12"])
    scale_df = CSV.read(joinpath(ES_NEW_DIR, new_resource, es_filename(date_str)), DataFrame)
    scale    = Float64.(scale_df[!, stage_col])
    return base_mw .* scale .* profile_scale(new_resource)
end

if WEEKS_ACTIVE
    # [weeks]: gate profiles come from the ScenarioData weather of the sampled
    # horizon (week_profiles.jl) — same table shape as the 2024 path below, with
    # the vintage factors season-matched to the 2024 study days until dated
    # files appear under Data/ES/.
    wk_tables  = week_stage_tables(cfg, EMP, WEEK_KEY)
    hourly_da  = wk_tables["DA"]
    hourly_id2 = wk_tables["ID2"]
    hourly_id3 = wk_tables["ID3"]
    hourly_cid = wk_tables["CID"]
    hourly_bal = wk_tables["BE"]
else
    hourly_da_rows  = NamedTuple[]
    hourly_id2_rows = NamedTuple[]
    hourly_id3_rows = NamedTuple[]
    hourly_cid_rows = NamedTuple[]
    hourly_bal_rows = NamedTuple[]
    for date_str in TARGET_DAYS
        load_da   = load_scaled_col(date_str, "load",         "load",  "DA")
        solar_da  = load_scaled_col(date_str, "Solar",        "Solar", "DA")
        wind_da   = load_scaled_col(date_str, "Wind Onshore", "Wind",  "DA")
        load_id2  = load_scaled_col(date_str, "load",         "load",  "ID2")
        solar_id2 = load_scaled_col(date_str, "Solar",        "Solar", "ID2")
        wind_id2  = load_scaled_col(date_str, "Wind Onshore", "Wind",  "ID2")
        load_id3  = load_scaled_col(date_str, "load",         "load",  "ID3")
        solar_id3 = load_scaled_col(date_str, "Solar",        "Solar", "ID3")
        wind_id3  = load_scaled_col(date_str, "Wind Onshore", "Wind",  "ID3")
        load_cid  = load_scaled_col(date_str, "load",         "load",  "CID")
        solar_cid = load_scaled_col(date_str, "Solar",        "Solar", "CID")
        wind_cid  = load_scaled_col(date_str, "Wind Onshore", "Wind",  "CID")
        load_bal  = load_scaled_col(date_str, "load",         "load",  "BE")
        solar_bal = load_scaled_col(date_str, "Solar",        "Solar", "BE")
        wind_bal  = load_scaled_col(date_str, "Wind Onshore", "Wind",  "BE")
        for h in 0:23
            push!(hourly_da_rows,  (date=date_str, hour=h, load_mw=load_da[h+1],  solar_mw=solar_da[h+1],  wind_mw=wind_da[h+1]))
            push!(hourly_id2_rows, (date=date_str, hour=h, load_mw=load_id2[h+1], solar_mw=solar_id2[h+1], wind_mw=wind_id2[h+1]))
            push!(hourly_id3_rows, (date=date_str, hour=h, load_mw=load_id3[h+1], solar_mw=solar_id3[h+1], wind_mw=wind_id3[h+1]))
            push!(hourly_cid_rows, (date=date_str, hour=h, load_mw=load_cid[h+1], solar_mw=solar_cid[h+1], wind_mw=wind_cid[h+1]))
            push!(hourly_bal_rows, (date=date_str, hour=h, load_mw=load_bal[h+1], solar_mw=solar_bal[h+1], wind_mw=wind_bal[h+1]))
        end
    end
    hourly_da  = DataFrame(hourly_da_rows);  sort!(hourly_da,  [:date, :hour])
    hourly_id2 = DataFrame(hourly_id2_rows); sort!(hourly_id2, [:date, :hour])
    hourly_id3 = DataFrame(hourly_id3_rows); sort!(hourly_id3, [:date, :hour])
    hourly_cid = DataFrame(hourly_cid_rows); sort!(hourly_cid, [:date, :hour])
    hourly_bal = DataFrame(hourly_bal_rows); sort!(hourly_bal, [:date, :hour])
end

function print_profile_summary(label, df)
    @printf "%s profiles: %d hours across %d days\n" label nrow(df) length(unique(df.date))
    for d in unique(df.date)
        rows = filter(r -> r.date == d, df)
        println("  $d : load $(round(Int,minimum(rows.load_mw)))–$(round(Int,maximum(rows.load_mw))) MW" *
                " | solar $(round(Int,minimum(rows.solar_mw)))–$(round(Int,maximum(rows.solar_mw))) MW" *
                " | wind $(round(Int,minimum(rows.wind_mw)))–$(round(Int,maximum(rows.wind_mw))) MW")
    end
end
print_profile_summary("DA",  hourly_da)
print_profile_summary("ID2", hourly_id2)
print_profile_summary("ID3", hourly_id3)
print_profile_summary("CID", hourly_cid)
print_profile_summary("BAL", hourly_bal)

# ── 3. Solver setup ──────────────────────────────────────────
PowerModels.silence()
# Scenario runs write to results/<label>/ so the 2024 outputs stay untouched.
RESULTS = SCEN_ACTIVE ? joinpath(@__DIR__, "results", SCEN_LABEL) :
                        joinpath(@__DIR__, "results")
mkpath(RESULTS)

# Per-solve Ipopt logs, written here so infeasible hours can be diagnosed.
# Each file records the full iteration history and Ipopt's final verdict
# (e.g. "Converged to a point of local infeasibility") together with the
# primal/constraint-violation trajectory that points at the binding limits.
const IPOPT_LOG_DIR = joinpath(RESULTS, "ipopt_logs")
mkpath(IPOPT_LOG_DIR)

const IPOPT_LINEAR_SOLVER = lowercase(get(ENV, "IPOPT_LINEAR_SOLVER", "ma57"))

function ipopt_linear_solver_attrs()
    attrs = Pair{String,Any}["linear_solver" => IPOPT_LINEAR_SOLVER]
    startswith(IPOPT_LINEAR_SOLVER, "ma") && push!(attrs, "hsllib" => HSL_jll.libhsl_path)
    return attrs
end
const IPOPT_SOLVER_ATTRS = ipopt_linear_solver_attrs()
@printf "Linear solver  : %s\n" IPOPT_LINEAR_SOLVER

# Single-period solver (one hour at a time).  `log_file`, when given, makes Ipopt
# mirror its iteration log to that file at file_print_level 5 so infeasible hours
# can be studied after the run (stdout stays quiet at print_level 0).
function ipopt_single(; log_file::Union{String,Nothing} = nothing)
    attrs = Pair{String,Any}[
        "print_level" => 0,
        "tol"         => 1e-4,
        "max_iter"    => 500,
        IPOPT_SOLVER_ATTRS...,
    ]
    if log_file !== nothing
        push!(attrs, "output_file"      => log_file)
        push!(attrs, "file_print_level" => 5)
    end
    return optimizer_with_attributes(Ipopt.Optimizer, attrs...)
end

# Multi-period solver (24 hours coupled — larger problem, needs more iterations).
# `log_file` likewise captures the full Ipopt log for the day's coupled solve.
function ipopt_mn(; log_file::Union{String,Nothing} = nothing)
    attrs = Pair{String,Any}[
    "print_level"          => 5,
    "print_frequency_iter" => 1,
    "tol"                  => 5e-4,
    "max_iter"             => 5000,
    IPOPT_SOLVER_ATTRS...,
    # Gradient-based scaling lets Ipopt rebalance rows/columns whose Jacobian norms
    # differ widely — important for the mixed pu/energy Bellman constraints.
    "nlp_scaling_method"   => "gradient-based",
    # Initialise each inequality multiplier as mu/slack rather than a flat 1.0.
    # The 118 Bellman cuts are slack by up to ~1e9 EUR at the start (their slopes
    # span a1∈[-160,0] evaluated at a 4.4e6 MWh reservoir), so a constant multiplier
    # makes the initial complementarity ~1e9 and stalls the first step.  "mu-based"
    # keeps it at n·mu and lets the inactive cuts' multipliers start near zero.
    "bound_mult_init_method" => "mu-based",
    # Accept solution if NLP error stays within acceptable_tol for 15 consecutive iterations.
    # Prevents infinite looping when dual infeasibility stalls just above tol.
    "acceptable_tol"       => 1e-3,
    "acceptable_iter"      => 15,
    "acceptable_dual_inf_tol"  => 1e-2,
    "acceptable_constr_viol_tol" => 1e-4,
    ]
    if log_file !== nothing
        push!(attrs, "output_file"      => log_file)
        push!(attrs, "file_print_level" => 5)
    end
    return optimizer_with_attributes(Ipopt.Optimizer, attrs...)
end

# ── 4. Result accumulators ───────────────────────────────────
summary_rows    = []
gen_rows_all    = []
fuel_rows_all   = []
branch_rows_all = []
bus_rows_all    = []

# ── 5. Result processing helper ──────────────────────────────
# Reactive power getter that coalesces a missing OR NaN value to 0.  DC OPF
# solutions carry qg/qf keys populated with NaN (there is no reactive power in
# the linear model); without this, hypot(p, NaN)=NaN poisons every apparent-power
# and loading_pct figure and silently hides MW overloads.
reactive_or_zero(d, key) = (q = get(d, key, 0.0); isnan(q) ? 0.0 : q)

# Accepts one hour's solution dict and pushes rows into the accumulators.
# Returns true on success, false on failure.
function process_hour_solution!(summary_rows, gen_rows_all, fuel_rows_all,
                                branch_rows_all, bus_rows_all,
                                sol_hour, network, gens, branches, dclines, loads,
                                date_str, hour, load_mw, status)
    if status ∈ ("OPTIMAL", "LOCALLY_SOLVED")
        sol_gen    = sol_hour["gen"]
        sol_branch = sol_hour["branch"]
        sol_bus    = sol_hour["bus"]

        for (k, v) in sol_bus
            push!(bus_rows_all, (
                date   = date_str,
                hour   = hour,
                bus_id = network["bus"][k]["name"],
                vm_pu  = round(get(v, "vm", 1.0);      digits=4),   # DC has no vm ⇒ nominal 1.0
                va_deg = round(rad2deg(v["va"]);       digits=3),
            ))
        end

        load_shed_mw      = sum(v["pg"] * BASEMVA for (k, v) in sol_gen
                               if gens[k]["fuel"] == "LoadShed"; init = 0.0)
        total_gen_mw      = sum(v["pg"] * BASEMVA for (k, v) in sol_gen
                               if gens[k]["fuel"] != "LoadShed")
        total_load_mw_out = sum(v["pd"] * BASEMVA for v in values(loads))
        # Operational cost from generation variables (excludes θ_future in piecewise mode)
        op_cost = sum(gens[k]["cost"][1] * v["pg"] for (k, v) in sol_gen)

        push!(summary_rows, (
            date            = date_str,
            hour            = hour,
            status          = status,
            objective_eur_h = round(op_cost;              digits=2),
            total_gen_mw    = round(total_gen_mw;         digits=1),
            total_load_mw   = round(total_load_mw_out;    digits=1),
            load_shed_mw    = round(load_shed_mw;         digits=1),
            mismatch_mw     = round(total_gen_mw + load_shed_mw - total_load_mw_out; digits=2),
        ))

        for (k, v) in sol_gen
            g        = gens[k]
            pg_mw    = v["pg"] * BASEMVA
            qg_mvar  = reactive_or_zero(v, "qg") * BASEMVA
            inst_mw  = g["installed_mw"]
            avail_mw = g["pmax"] * BASEMVA
            util     = avail_mw > 0 ? 100 * pg_mw / avail_mw : 0.0
            push!(gen_rows_all, (
                date             = date_str,
                hour             = hour,
                gen_id           = k,
                unit_name        = g["name"],
                fuel             = g["fuel"],
                technology       = g["technology"],
                bus_i            = g["gen_bus"],
                capacity_mw      = round(inst_mw;  digits=2),
                dispatch_mw      = round(pg_mw;    digits=2),
                dispatch_mvar    = round(qg_mvar;  digits=2),
                utilization_pct  = round(util;     digits=1),
                cost_eur_per_mwh = round(inst_mw > 0 ? g["cost"][1] / BASEMVA : 0.0; digits=2),
            ))
        end

        fuel_disp = Dict{String,Float64}()
        fuel_cap  = Dict{String,Float64}()
        for (k, v) in sol_gen
            g    = gens[k]
            fuel = g["fuel"]
            fuel_disp[fuel] = get(fuel_disp, fuel, 0.0) + v["pg"] * BASEMVA
            fuel_cap[fuel]  = get(fuel_cap,  fuel, 0.0) + g["installed_mw"]
        end
        for (fuel, disp) in fuel_disp
            cap = fuel_cap[fuel]
            push!(fuel_rows_all, (
                date            = date_str,
                hour            = hour,
                fuel            = fuel,
                dispatch_mw     = round(disp; digits=1),
                capacity_mw     = round(cap;  digits=1),
                utilization_pct = round(100 * disp / max(cap, 1e-6); digits=1),
            ))
        end

        for (k, v) in sol_branch
            br      = branches[k]
            pf_mw   = v["pf"] * BASEMVA
            qf_mvar = reactive_or_zero(v, "qf") * BASEMVA
            sf_mva  = hypot(pf_mw, qf_mvar)
            rate_mw = br["rate_a"] * BASEMVA
            loading = rate_mw > 0 ? 100 * sf_mva / rate_mw : 0.0
            push!(branch_rows_all, (
                date        = date_str,
                hour        = hour,
                branch_id   = k,
                branch_name = br["name"],
                from_bus    = br["f_bus"],
                to_bus      = br["t_bus"],
                flow_mw     = round(pf_mw;   digits=2),
                flow_mvar   = round(qf_mvar; digits=2),
                limit_mw    = round(rate_mw; digits=2),
                loading_pct = round(loading; digits=1),
            ))
        end

        for (k, v) in get(sol_hour, "dcline", Dict())
            dc      = dclines[k]
            pf_mw   = v["pf"] * BASEMVA
            qf_mvar = reactive_or_zero(v, "qf") * BASEMVA
            sf_mva  = hypot(pf_mw, qf_mvar)
            rate_mw = dc["pmaxf"] * BASEMVA
            loading = rate_mw > 0 ? 100 * sf_mva / rate_mw : 0.0
            push!(branch_rows_all, (
                date        = date_str,
                hour        = hour,
                branch_id   = "dc" * k,
                branch_name = dc["name"],
                from_bus    = dc["f_bus"],
                to_bus      = dc["t_bus"],
                flow_mw     = round(pf_mw;   digits=2),
                flow_mvar   = round(qf_mvar; digits=2),
                limit_mw    = round(rate_mw; digits=2),
                loading_pct = round(loading; digits=1),
            ))
        end

        n_br   = length(sol_branch) + length(get(sol_hour, "dcline", Dict()))
        n_cong = count(r -> r.loading_pct > 90.0, branch_rows_all[end-n_br+1:end])
        shed_str = load_shed_mw > 0.05 ? @sprintf("  shed=%.0f MW", load_shed_mw) : ""
        @printf "  h%02d  load=%.0f MW  cost=%.0f EUR/h  congested=%d%s\n" hour load_mw op_cost n_cong shed_str
        return true
    else
        push!(summary_rows, (
            date            = date_str,
            hour            = hour,
            status          = status,
            objective_eur_h = NaN,
            total_gen_mw    = NaN,
            total_load_mw   = load_mw,
            load_shed_mw    = NaN,
            mismatch_mw     = NaN,
        ))
        @printf "  h%02d  FAILED: %s\n" hour status
        return false
    end
end

# ── 6. Bellman pre-computation ───────────────────────────────
println("\nBellman pre-computation:")
day_bellman = Dict{String,NamedTuple}()
for date_str in TARGET_DAYS
    stage = bellman_stage(date_str, BELLMAN_BGN_DATE, BELLMAN_SSV_STEP)
    v_es  = v_es_at_date(VOLUME_FILE, date_str, BELLMAN_BGN_DATE)
    v_fr  = v_fr_at_date(VOLUME_FILE, date_str, BELLMAN_BGN_DATE)
    cuts  = load_cuts_at_stage(BELLMAN_FILE, stage, v_fr)
    wv    = binding_water_value(cuts, v_es)
    day_bellman[date_str] = (stage=stage, cuts=cuts, v_es=v_es, v_fr=v_fr, water_value=wv)
    @printf "  %s : stage=%d  V_ES=%.0f MWh  V_FR=%.0f MWh  water_value=%.2f EUR/MWh\n" date_str stage v_es v_fr wv
end

# ── 6b. Cross-border exchange pre-load ───────────────────────
xb_data  = Dict{String,Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}}()
xb_fracs = Dict{String,Dict{String,Float64}}()
if CROSSBORDER
    xb_data  = load_crossborder()
    # Nodal scenario: split the exchange over the SCENARIO border (expanded
    # corridors + synthetic ones), not the 2024 one.
    xb_fracs = crossborder_bus_fractions(line_scale = LINE_SCALE,
                                         extra_lines = EXTRA_LINES)
    println("\nCross-border exchange pre-load:")
    for (c, bf) in sort(collect(xb_fracs); by = first)
        @printf "  %s border buses: %s\n" c join(sort(collect(keys(bf))), ", ")
    end
    for date_str in TARGET_DAYS
        nets = xb_data[date_str]
        fr = extrema(t.FR for t in values(nets)); pt = extrema(t.PT for t in values(nets))
        @printf "  %s : net FR %.0f…%.0f MW | net PT %.0f…%.0f MW  (+ = import to ES)\n" date_str fr[1] fr[2] pt[1] pt[2]
    end
end

crossborder_inj_for(date_str, hour) =
    CROSSBORDER ? crossborder_injections(xb_data, xb_fracs, date_str, hour) : nothing

# ── 6c. Stage 1 — Day-ahead copper-plate dispatch ─────────────
# Solve each day's 24-hour energy-only economic dispatch (no network limits)
# with reservoir hydro coupled through the full Bellman cost-to-go.  The cleared
# per-unit schedule becomes the reference the redispatch is anchored to and is
# written to results/da_dispatch.csv.  Returns (date,hour) ⇒ Dict(unit ⇒ MW).

# Solver for the copper-plate market clearing (DA/ID2/ID3/CID).  This stage is a
# linear program (linear generation cost + power balance + Bellman cuts), so it
# is cleared exactly with Gurobi rather than the interior-point Ipopt used for
# the nonlinear AC OPF redispatch.  The shared GRB_ENV avoids re-reading the
# license for every solve.
function gurobi_da(; log_file::Union{String,Nothing} = nothing)
    attrs = Pair{String,Any}[
        "OutputFlag"     => 0,    # silent (no console, no file) by default
        "FeasibilityTol" => 1e-6,
        "OptimalityTol"  => 1e-6,
    ]
    if log_file !== nothing
        # File-only logging: enable output globally but mute the console so the
        # full solve log lands in the file while stdout stays clean.
        attrs[1] = "OutputFlag" => 1
        push!(attrs, "LogToConsole" => 0)
        push!(attrs, "LogFile"      => log_file)
    end
    return optimizer_with_attributes(() -> Gurobi.Optimizer(GRB_ENV), attrs...)
end

# Redispatch solver selection.  The DC formulation is linear (plus, at most, the
# convex quadratic anchor term), so it is solved exactly with Gurobi; the
# nonlinear AC formulation needs the interior-point Ipopt.  `log_file` routes
# the solver log to the per-solve file either way.
const RD_SOLVER_NAME = RD_PF_MODEL == "DC" ? "Gurobi" : "Ipopt"
rd_optimizer_single(; log_file = nothing) =
    RD_PF_MODEL == "DC" ? gurobi_da(log_file = log_file) : ipopt_single(log_file = log_file)
rd_optimizer_mn(; log_file = nothing) =
    RD_PF_MODEL == "DC" ? gurobi_da(log_file = log_file) : ipopt_mn(log_file = log_file)

da_rows_all  = []
id2_rows_all = []
id3_rows_all = []
cid_rows_all = []
bal_rows_all = []
da_schedule  = Dict{Tuple{String,Int},Dict{String,Float64}}()
id2_schedule = Dict{Tuple{String,Int},Dict{String,Float64}}()
id3_schedule = Dict{Tuple{String,Int},Dict{String,Float64}}()
cid_schedule = Dict{Tuple{String,Int},Dict{String,Float64}}()
bal_schedule = Dict{Tuple{String,Int},Dict{String,Float64}}()

# Helper: build 24 energy-only networks for one day using the given hourly profile.
# nuclear_sched: the full da_schedule dict — when provided, Nuclear units are frozen
# at their DA dispatch values (pmin=pmax) for this copper-plate stage.
function build_da_nets(date_str, day_ts; nuclear_sched = nothing)
    [prepare_network(ts.load_mw, ts.solar_mw, ts.wind_mw;
                     hydro_reservoir_cost = 0.0,
                     crossborder_inj = crossborder_inj_for(date_str, ts.hour),
                     nuclear_da_dispatch = nuclear_sched === nothing ? nothing :
                                           get(nuclear_sched, (date_str, ts.hour), nothing),
                     nuclear_min_frac = NUCLEAR_MIN_FRAC,
                     voltage_band = VOLTAGE_BAND,
                     line_rating_factor = LINE_RATING_FACTOR,
                     reactors_enabled = REACTORS_ENABLED,
                     reactor_in_service_pct = REACTOR_PCT,
                     load_power_factor = LOAD_PF,
                     apparent_power_limit = APPARENT_POWER_LIMIT,
                     rated_power_factor = RATED_PF,
                     renewable_power_factor = RENEWABLE_PF,
                     gen_bus_voltage_control = GEN_BUS_VCTRL,
                     gen_bus_vmin = GEN_BUS_VMIN,
                     gen_bus_vmax = GEN_BUS_VMAX,
                     unit_scale = UNIT_SCALE,
                     cost_override = COST_OVERRIDE,
                     bess_units = BESS_UNITS,
                     unit_scale_by_id = UNIT_SCALE_ID,
                     extra_units = EXTRA_UNITS,
                     line_scale = LINE_SCALE,
                     extra_lines = EXTRA_LINES)
     for ts in eachrow(day_ts)]
end

# Reservoir gen ids (stable across hours) for a day's assembled networks.
reservoir_ids_of(nets) = sort([parse(Int, k) for (k, g) in nets[1].gens
                                if g["fuel"] == "Hydro" &&
                                   lowercase(g["technology"]) == "reservoir"])

# Store a cleared schedule (sched :: Dict net-idx ⇒ unit ⇒ MW) into the
# (date,hour) schedule dict and append the per-unit rows for CSV export.
function store_stage_result!(schedule, rows_acc, date_str, day_ts, nets, sched)
    for (h_idx, ts) in enumerate(eachrow(day_ts))
        hour = ts.hour
        schedule[(date_str, hour)] = sched[h_idx]
        for (k, g) in nets[h_idx].gens
            push!(rows_acc, (
                date        = date_str,
                hour        = hour,
                gen_id      = g["name"],
                fuel        = g["fuel"],
                technology  = g["technology"],
                dispatch_mw = round(sched[h_idx][g["name"]]; digits = 2),
            ))
        end
    end
end

# Helper: run solve_da over one day and populate a schedule dict + rows accumulator.
# free_hours_actual : Set of delivery hours (0–23) tradable at this gate; the rest
#                     are frozen at `prev_schedule` (the previous gate's (date,hour)
#                     schedule).  `nothing` ⇒ all 24 hours tradable.
function run_copper_plate!(schedule, rows_acc, label, date_str, day_ts, bv, log_tag;
                            nuclear_sched = nothing,
                            free_hours_actual = nothing,
                            prev_schedule = nothing)
    nets = build_da_nets(date_str, day_ts; nuclear_sched = nuclear_sched)
    reservoir_gen_ids = reservoir_ids_of(nets)

    # Map tradable delivery hours → net indices.  Hours NOT tradable at this gate
    # are frozen at prev_schedule (prev_map); tradable hours are anchored to it
    # (anchor_map) so the gate adjusts the previous dispatch with minimum movement
    # rather than re-clearing from scratch.  With prev_schedule given but no
    # free_hours_actual (e.g. ID2), every hour is tradable and anchored.
    free_set   = nothing
    prev_map   = nothing
    anchor_map = nothing
    if free_hours_actual !== nothing || prev_schedule !== nothing
        free_set   = Set{Int}()
        prev_map   = Dict{Int,Dict{String,Float64}}()
        anchor_map = Dict{Int,Dict{String,Float64}}()
        for (h_idx, ts) in enumerate(eachrow(day_ts))
            is_free = free_hours_actual === nothing || ts.hour in free_hours_actual
            ps = prev_schedule === nothing ? nothing : get(prev_schedule, (date_str, ts.hour), nothing)
            if is_free
                push!(free_set, h_idx)
                ps !== nothing && (anchor_map[h_idx] = ps)
            elseif ps !== nothing
                prev_map[h_idx] = ps
            end
        end
    end

    log_file = joinpath(IPOPT_LOG_DIR, "$(date_str)_$(log_tag).log")
    t_start  = time()
    result   = solve_da(nets, reservoir_gen_ids, bv.cuts, bv.v_es,
                        gurobi_da(log_file = log_file);
                        free_hours = free_set, prev_sched = prev_map, anchor = anchor_map)
    @printf "  %s %s : status=%s  cost=%.0f EUR  (%.1f s)\n" label date_str result.status result.objective (time() - t_start)
    result.status ∈ ("OPTIMAL", "LOCALLY_SOLVED") ||
        error("$label dispatch failed for $date_str: $(result.status)")
    store_stage_result!(schedule, rows_acc, date_str, day_ts, nets, result.sched)
end

# Continuous Intraday modelled as auction gates closing one hour before delivery.
# For each delivery hour we re-clear the remaining horizon (this hour onward) with
# every earlier hour frozen at its already-committed CID value, then commit this
# hour.  Earlier hours' reservoir use is locked in, so water cannot be reallocated
# backwards in time — the causality the 1h-before-delivery rule implies.
function run_cid_rolling!(schedule, rows_acc, date_str, day_ts, bv;
                          nuclear_sched = nothing, anchor_base = nothing)
    nets = build_da_nets(date_str, day_ts; nuclear_sched = nuclear_sched)
    reservoir_gen_ids = reservoir_ids_of(nets)
    H         = length(nets)
    committed = Dict{Int,Dict{String,Float64}}()
    t_start   = time()
    # prev_full holds the most recent market view of every hour, seeded from the
    # predecessor stage (anchor_base, a (date,hour)⇒sched lookup).  Each gate
    # anchors its tradable hours to it with minimum movement, then refreshes it
    # with its own fresh clear so the next gate adjusts from the latest state.
    prev_full = Dict{Int,Dict{String,Float64}}()
    if anchor_base !== nothing
        for (h_idx, ts) in enumerate(eachrow(day_ts))
            ps = anchor_base(date_str, ts.hour)
            ps !== nothing && (prev_full[h_idx] = ps)
        end
    end
    for hgate in 1:H
        free_set   = Set(hgate:H)
        anchor_map = Dict(h => prev_full[h] for h in hgate:H if haskey(prev_full, h))
        result   = solve_da(nets, reservoir_gen_ids, bv.cuts, bv.v_es, gurobi_da();
                            free_hours = free_set, prev_sched = committed, anchor = anchor_map)
        result.status ∈ ("OPTIMAL", "LOCALLY_SOLVED") ||
            error("CID gate h=$(day_ts.hour[hgate]) failed for $date_str: $(result.status)")
        committed[hgate] = result.sched[hgate]
        for h in hgate:H
            prev_full[h] = result.sched[h]
        end
    end
    @printf "  CID %s : %d rolling gates solved  (%.1f s)\n" date_str H (time() - t_start)
    store_stage_result!(schedule, rows_acc, date_str, day_ts, nets, committed)
end

if DA_ENABLED && RUN_MARKET
    println("\n── Stage 1: Day-ahead market (copper-plate, 24h Bellman-coupled) ──")
    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly_da)
        run_copper_plate!(da_schedule, da_rows_all, "DA", date_str, day_ts, bv, "da")
    end
end

da_sched_for(date_str, hour) = get(da_schedule, (date_str, hour), nothing)

if ID2_ENABLED && RUN_MARKET
    println("\n── Stage 2: Intraday market ID2 (copper-plate, Nuclear fixed at DA) ──")
    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly_id2)
        # All 24 hours tradable, anchored to the DA schedule (minimum-movement
        # adjustment for the ID2 forecast update rather than a fresh re-clear).
        run_copper_plate!(id2_schedule, id2_rows_all, "ID2", date_str, day_ts, bv, "id2";
                          nuclear_sched = da_schedule,
                          prev_schedule = da_schedule)
    end
end

id2_sched_for(date_str, hour) = get(id2_schedule, (date_str, hour), nothing)

if ID3_ENABLED && RUN_MARKET
    println("\n── Stage 3: Intraday market ID3 (copper-plate, last 12h only, Nuclear fixed at DA) ──")
    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly_id3)
        # ID3 closes 10:00 D and trades only the last 12 delivery hours (12–23);
        # hours 0–11 are not retradeable here and stay at their ID2 schedule.
        run_copper_plate!(id3_schedule, id3_rows_all, "ID3", date_str, day_ts, bv, "id3";
                          nuclear_sched = da_schedule,
                          free_hours_actual = Set(12:23),
                          prev_schedule = id2_schedule)
    end
end

id3_sched_for(date_str, hour) = get(id3_schedule, (date_str, hour), nothing)

if CID_ENABLED && RUN_MARKET
    println("\n── Stage 4: Continuous Intraday (rolling gates 1h before delivery, Nuclear fixed at DA) ──")
    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly_cid)
        # CID's predecessor view: ID3 where it traded (hours 12–23), else ID2,
        # else DA — the same precedence the redispatch anchor uses.
        cid_anchor_base(d, h) = ID3_ENABLED ? (id3_sched_for(d, h) !== nothing ? id3_sched_for(d, h) :
                                               ID2_ENABLED ? id2_sched_for(d, h) : da_sched_for(d, h)) :
                                ID2_ENABLED ? id2_sched_for(d, h) : da_sched_for(d, h)
        run_cid_rolling!(cid_schedule, cid_rows_all, date_str, day_ts, bv;
                         nuclear_sched = da_schedule, anchor_base = cid_anchor_base)
    end
end

cid_sched_for(date_str, hour) = get(cid_schedule, (date_str, hour), nothing)

if BAL_ENABLED && RUN_MARKET
    println("\n── Stage 5: Balancing market (copper-plate, Nuclear fixed at DA) ──")
    # Predecessor schedule the balancing gate adjusts: the latest market view
    # available (CID > ID3 > ID2 > DA).  All 24 hours are tradable and anchored
    # to it with minimum movement — the same formulation as the ID2 intraday gate.
    pre_bal_schedule = CID_ENABLED ? cid_schedule :
                       ID3_ENABLED ? id3_schedule :
                       ID2_ENABLED ? id2_schedule : da_schedule
    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly_bal)
        run_copper_plate!(bal_schedule, bal_rows_all, "BAL", date_str, day_ts, bv, "bal";
                          nuclear_sched = da_schedule,
                          prev_schedule = pre_bal_schedule)
    end
end

bal_sched_for(date_str, hour) = get(bal_schedule, (date_str, hour), nothing)

# Reconstruct a (date,hour) ⇒ Dict(unit ⇒ MW) anchor schedule from a previous
# run's <stage>_dispatch.csv in RESULTS.  Used by the [redispatch].from_saved
# standalone load-flow path so stages 1–5 need not be re-solved.  The CSV's
# gen_id column is the unit name and dispatch_mw its cleared MW — exactly the
# anchor format prepare_network's `da_dispatch` expects.
function load_saved_schedule(stage)
    file = joinpath(RESULTS, lowercase(stage) * "_dispatch.csv")
    isfile(file) ||
        error("[redispatch].from_saved=$stage: $file not found — run the market chain first")
    df = CSV.read(file, DataFrame)
    sched = Dict{Tuple{String,Int},Dict{String,Float64}}()
    for r in eachrow(df)
        d = get!(() -> Dict{String,Float64}(), sched, (string(r.date), Int(r.hour)))
        d[string(r.gen_id)] = Float64(r.dispatch_mw)
    end
    @printf "  Loaded %s anchor schedule from %s (%d unit-hours, %d delivery hours)\n" stage basename(file) nrow(df) length(sched)
    return sched
end

# In standalone mode the anchor comes from the saved CSV; otherwise it is the
# last in-memory cleared schedule: BAL > CID > ID3 > ID2 > DA.
loaded_schedule = RD_FROM_SAVED_ACTIVE ? load_saved_schedule(RD_FROM_SAVED) : nothing
rd_sched_for(date_str, hour) =
    RD_FROM_SAVED_ACTIVE ? get(loaded_schedule, (date_str, hour), nothing) :
                                BAL_ENABLED  ? bal_sched_for(date_str, hour)  :
                                CID_ENABLED  ? cid_sched_for(date_str, hour)  :
                                ID3_ENABLED  ? id3_sched_for(date_str, hour)  :
                                ID2_ENABLED  ? id2_sched_for(date_str, hour)  :
                                               da_sched_for(date_str, hour)

# Solve one hour's AC OPF anchored to the day-ahead schedule `sched`
# (Dict unit ⇒ MW).  Two objective forms, selected by RD_OBJECTIVE:
#   "quadratic"     — base OPF cost + ANCHOR_WEIGHT·Σ(P_g − P_DA)² over the real
#                     units (name "G…"); reservoir hydro keeps the constant water
#                     value its network was built with.
#   "cost_weighted" — pay only for movement: Σ c_g·(Δup+Δdown) with
#                     P_g = P_DA + Δup − Δdown over the free units, plus the slack
#                     and load-shed penalties so those stay last-resort.
# Add per-generator reactive-capability constraints to an instantiated model:
#   • synchronous units (finite `smax`): MVA capability circle  P² + Q² ≤ S²
#     (convex second-order cone — Ipopt handles it as an NLP);
#   • inverter-based Wind/Solar (finite `qp_ratio` k): grid-code cap tied to
#     output,  −k·P ≤ Q ≤ k·P  (linear).
# No-op when [generators].apparent_power_limit = false (relax switch).  `nw`
# selects the network for multinetwork (Bellman) models.
function add_gen_capability!(pm, gen_dict; nw = PowerModels.nw_id_default)
    APPARENT_POWER_LIMIT || return
    # DC models carry no reactive power (no qg variable), so the MVA capability
    # circle and the reactive grid-code cap are meaningless — skip them.
    pm isa PowerModels.AbstractActivePowerModel && return
    for (_, g) in gen_dict
        i  = g["index"]
        pg = PowerModels.var(pm, nw, :pg, i)
        qg = PowerModels.var(pm, nw, :qg, i)
        s = get(g, "smax", Inf)
        if isfinite(s) && s > 0
            JuMP.@constraint(pm.model, pg^2 + qg^2 <= s^2)
        end
        k = get(g, "qp_ratio", Inf)
        if isfinite(k)
            JuMP.@constraint(pm.model, qg <=  k * pg)
            JuMP.@constraint(pm.model, qg >= -k * pg)
        end
    end
    return
end

# Plain AC OPF that also enforces the generator MVA limits (when enabled).
function rd_solve_ac_opf(network, optimizer)
    APPARENT_POWER_LIMIT || return PowerModels.solve_opf(network, RD_PM_TYPE, optimizer)
    pm = PowerModels.instantiate_model(network, RD_PM_TYPE, PowerModels.build_opf)
    add_gen_capability!(pm, network["gen"])
    return PowerModels.optimize_model!(pm; optimizer = optimizer)
end

# Infeasibility diagnosis: when a DC redispatch solve is infeasible, ask Gurobi for
# the IIS (irreducible infeasible subsystem) and dump the conflicting constraints to
# results/<label>/iis.txt together with a gen/branch/bus name legend, so the binding
# network cut (e.g. a fixed unit trapped behind an undersized line) can be read off.
function rd_dump_iis(pm, network; label::Union{Nothing,String} = nothing)
    m = pm.model
    println("  computing Gurobi IIS ...")
    try
        JuMP.compute_conflict!(m)
    catch e
        println("  IIS computation failed: $e")
        return
    end
    gen_by_i = Dict(g["index"] => g for (_, g) in network["gen"])
    bus_by_i = Dict(b["index"] => b for (_, b) in network["bus"])
    br_by_i  = Dict(b["index"] => b for (_, b) in network["branch"])
    # Keep one IIS per failed delivery hour so an analysis notebook can match a
    # conflict to the corresponding row in summary.csv.  iis.txt remains a
    # backwards-compatible copy of the most recently diagnosed hour.
    suffix = label === nothing ? "" : "_" * replace(label, " " => "_")
    out = joinpath(RESULTS, "iis$(suffix).txt")
    n_conflict = 0
    open(out, "w") do io
        for (F, S) in JuMP.list_of_constraint_types(m)
            for c in JuMP.all_constraints(m, F, S)
                st = try
                    JuMP.MOI.get(m, JuMP.MOI.ConstraintConflictStatus(), c)
                catch
                    continue
                end
                st == JuMP.MOI.IN_CONFLICT || continue
                n_conflict += 1
                println(io, c)
            end
        end
        println(io, "\n── legend ─────────────────────────────────")
        println(io, "gen index → name @ bus (fuel, pmin..pmax pu):")
        for i in sort(collect(keys(gen_by_i)))
            g = gen_by_i[i]
            println(io, "  pg[$i] = $(g["name"]) @ bus $(g["gen_bus"]) ($(g["fuel"]), $(round(g["pmin"];digits=3))..$(round(g["pmax"];digits=3)))")
        end
        println(io, "branch index → name f_bus→t_bus (rate_a pu, x pu):")
        for i in sort(collect(keys(br_by_i)))
            b = br_by_i[i]
            println(io, "  br[$i] = $(get(b,"name","?")) $(b["f_bus"])→$(b["t_bus"]) (rate $(round(b["rate_a"];digits=2)), x $(round(b["br_x"];digits=5)))")
        end
        println(io, "bus index → name:")
        for i in sort(collect(keys(bus_by_i)))
            println(io, "  bus $i = $(get(bus_by_i[i],"name","?"))")
        end
    end
    if label !== nothing
        cp(out, joinpath(RESULTS, "iis.txt"); force = true)
    end
    println("  IIS: $n_conflict conflicting constraints written to $out")
end

function solve_anchored_opf(network, gens, optimizer, sched;
                            iis_label::Union{Nothing,String} = nothing)
    if sched === nothing || (RD_OBJECTIVE == "quadratic" && ANCHOR_WEIGHT <= 0)
        return rd_solve_ac_opf(network, optimizer)
    end
    pm = PowerModels.instantiate_model(network, RD_PM_TYPE, PowerModels.build_opf)
    add_gen_capability!(pm, gens)

    # Anchored units: market units ("G…") present in the schedule, plus every
    # battery ("BESS_…") — a battery absent from the schedule is anchored to
    # 0 MW so it cannot act as a free energy source (no hourly energy budget).
    rd_anchor_tgt(g) =
        startswith(g["name"], "G")     ? (haskey(sched, g["name"]) ? sched[g["name"]] / BASEMVA : nothing) :
        startswith(g["name"], "BESS_") ? get(sched, g["name"], 0.0) / BASEMVA : nothing

    if RD_OBJECTIVE == "quadratic"
        pen = zero(JuMP.QuadExpr)
        for (_, g) in gens
            tgt_pu = rd_anchor_tgt(g)
            tgt_pu === nothing && continue
            pg = PowerModels.var(pm, :pg, g["index"])
            JuMP.add_to_expression!(pen, ((pg - tgt_pu) * BASEMVA)^2)
        end
        base_obj = JuMP.objective_function(pm.model)
        JuMP.@objective(pm.model, Min, base_obj + ANCHOR_WEIGHT * pen)
    else   # cost_weighted
        dev = zero(JuMP.AffExpr)
        for (_, g) in gens
            pg     = PowerModels.var(pm, :pg, g["index"])
            tgt_pu = rd_anchor_tgt(g)
            if tgt_pu !== nothing && abs(g["pmax"] - g["pmin"]) > 1e-9  # free, anchored unit
                up   = JuMP.@variable(pm.model, lower_bound = 0.0)
                down = JuMP.@variable(pm.model, lower_bound = 0.0)
                JuMP.@constraint(pm.model, pg == tgt_pu + up - down)
                JuMP.add_to_expression!(dev, g["cost"][1], up)   # c_g [EUR/pu] · Δ
                JuMP.add_to_expression!(dev, g["cost"][1], down)
            elseif startswith(g["name"], "SLACK") || startswith(g["name"], "LS_")
                JuMP.add_to_expression!(dev, g["cost"][1], pg)   # keep penalties active
            end
        end
        JuMP.@objective(pm.model, Min, dev)
    end
    result = PowerModels.optimize_model!(pm; optimizer = optimizer)
    if RD_PF_MODEL == "DC" &&
       result["termination_status"] in (JuMP.MOI.INFEASIBLE, JuMP.MOI.INFEASIBLE_OR_UNBOUNDED)
        rd_dump_iis(pm, network; label = iis_label)
    end
    return result
end

# ── 7. Stage 6 — Redispatch (AC OPF anchored to BAL/CID/ID/DA schedule) ──
# Uses the final-stage wind/solar/load profiles (balancing BE values when the
# balancing stage is on, else CID) and anchors to the last cleared schedule.
# Profiles for the load flow follow the anchor stage: in standalone mode that is
# the saved stage, otherwise the last enabled market stage (BAL else CID).
hourly_rd = RD_FROM_SAVED_ACTIVE ?
    (RD_FROM_SAVED == "BAL" ? hourly_bal :
     RD_FROM_SAVED == "CID" ? hourly_cid :
     RD_FROM_SAVED == "ID3" ? hourly_id3 :
     RD_FROM_SAVED == "ID2" ? hourly_id2 : hourly_da) :
    (BAL_ENABLED ? hourly_bal : hourly_cid)
# [redispatch].only may pin the load flow to a single delivery hour (constant
# water_value only; the day is already restricted via TARGET_DAYS).
RD_ONLY_HOUR !== nothing && (hourly_rd = filter(r -> r.hour == RD_ONLY_HOUR, hourly_rd))
RD_ONLY_HOUR !== nothing && isempty(hourly_rd) &&
    error("config.toml: [redispatch].only hour $RD_ONLY_HOUR is out of range 0–23")
n_total  = nrow(hourly_rd)
n_solved = 0

if RD_ENABLED
println("\n── Stage 6: Redispatch ($(RD_PF_MODEL) OPF via $(RD_SOLVER_NAME), anchored to $(rd_anchor_label())) ──")

# ────────────────────────────────────────────────────────────
# Method A — constant water value (hour-by-hour)
# ────────────────────────────────────────────────────────────
if RD_WATER_VALUE == "constant"

    for ts in eachrow(hourly_rd)
        date_str = ts.date
        hour     = ts.hour
        bv       = day_bellman[date_str]
        label    = "$date_str h$(lpad(hour, 2, '0'))"

        net = prepare_network(ts.load_mw, ts.solar_mw, ts.wind_mw;
                              hydro_reservoir_cost = bv.water_value,
                              crossborder_inj = crossborder_inj_for(date_str, hour),
                              da_dispatch = rd_sched_for(date_str, hour),
                              voltage_band = VOLTAGE_BAND,
                              line_rating_factor = LINE_RATING_FACTOR,
                              reactors_enabled = REACTORS_ENABLED,
                              reactor_in_service_pct = REACTOR_PCT,
                              load_power_factor = LOAD_PF,
                              apparent_power_limit = APPARENT_POWER_LIMIT,
                              rated_power_factor = RATED_PF,
                              renewable_power_factor = RENEWABLE_PF,
                              gen_bus_voltage_control = GEN_BUS_VCTRL,
                              gen_bus_vmin = GEN_BUS_VMIN,
                              gen_bus_vmax = GEN_BUS_VMAX,
                              unit_scale = UNIT_SCALE,
                              cost_override = COST_OVERRIDE,
                              bess_units = BESS_UNITS,
                              unit_scale_by_id = UNIT_SCALE_ID,
                              extra_units = EXTRA_UNITS,
                              line_scale = LINE_SCALE,
                              extra_lines = EXTRA_LINES)
        (; network, gens, branches, dclines, loads) = net

        log_file = joinpath(IPOPT_LOG_DIR, "$(date_str)_h$(lpad(hour, 2, '0')).log")
        result = solve_anchored_opf(network, gens, rd_optimizer_single(log_file = log_file),
                                    rd_sched_for(date_str, hour); iis_label = label)
        status = string(result["termination_status"])

        @printf "[%2d/%d] %s\n" (n_solved + 1) n_total label

        sol_hour = Dict(
            "gen"    => get(result["solution"], "gen",    Dict()),
            "branch" => get(result["solution"], "branch", Dict()),
            "bus"    => get(result["solution"], "bus",    Dict()),
            "dcline" => get(result["solution"], "dcline", Dict()),
        )
        ok = process_hour_solution!(summary_rows, gen_rows_all, fuel_rows_all,
                                    branch_rows_all, bus_rows_all,
                                    sol_hour, network, gens, branches, dclines, loads,
                                    date_str, hour, ts.load_mw, status)
        ok && (global n_solved += 1)
    end

# ────────────────────────────────────────────────────────────
# Method B — piecewise cost-to-go (all 24 hours per day coupled)
# ────────────────────────────────────────────────────────────
elseif RD_WATER_VALUE == "piecewise"

    RD_OBJECTIVE == "cost_weighted" &&
        error("config.toml: [redispatch] objective=\"cost_weighted\" is only wired into the \"constant\" water_value path; use \"quadratic\" with \"piecewise\".")

    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly_rd)

        @printf "\n[Piecewise] %s  stage=%d  V_ES_start=%.0f MWh\n" date_str bv.stage bv.v_es

        # Build 24 networks anchored to the CID schedule: Nuclear/run-of-river/
        # biomass/coal are frozen at their CID set-point, every other unit is free.
        # Reservoir hydro carries no separate linear adder here because the
        # Bellman cost-to-go term below supplies its opportunity cost.
        nets = [prepare_network(ts.load_mw, ts.solar_mw, ts.wind_mw;
                                hydro_reservoir_cost = 0.0,
                                crossborder_inj = crossborder_inj_for(date_str, ts.hour),
                                da_dispatch = rd_sched_for(date_str, ts.hour),
                                voltage_band = VOLTAGE_BAND,
                                line_rating_factor = LINE_RATING_FACTOR,
                                reactors_enabled = REACTORS_ENABLED,
                                reactor_in_service_pct = REACTOR_PCT,
                                load_power_factor = LOAD_PF,
                                apparent_power_limit = APPARENT_POWER_LIMIT,
                                rated_power_factor = RATED_PF,
                                renewable_power_factor = RENEWABLE_PF,
                                gen_bus_voltage_control = GEN_BUS_VCTRL,
                                gen_bus_vmin = GEN_BUS_VMIN,
                                gen_bus_vmax = GEN_BUS_VMAX,
                                unit_scale = UNIT_SCALE,
                                cost_override = COST_OVERRIDE,
                                bess_units = BESS_UNITS,
                                unit_scale_by_id = UNIT_SCALE_ID,
                                extra_units = EXTRA_UNITS,
                                line_scale = LINE_SCALE,
                                extra_lines = EXTRA_LINES)
                for ts in eachrow(day_ts)]

        # Generator IDs (Int) for Spanish reservoir hydro — same topology every hour
        reservoir_gen_ids = sort([parse(Int, k) for (k, g) in nets[1].gens
                                   if g["fuel"] == "Hydro" &&
                                      lowercase(g["technology"]) == "reservoir"])
        @printf "  Reservoir hydro units in Bellman constraint: %d\n" length(reservoir_gen_ids)

        # Multinetwork dict: network "0" = hour 0, ..., "23" = hour 23
        mn_data = Dict{String,Any}(
            "multinetwork" => true,
            "baseMVA"      => BASEMVA,
            "per_unit"     => true,
            "name"         => "Spain_mn",
            "nw"           => Dict{String,Any}(
                string(h) => nets[h + 1].network for h in 0:23
            ),
        )

        cuts   = bv.cuts
        v_es_0 = bv.v_es

        # Custom build function: standard AC OPF per network + Bellman coupling
        function build_mn_bellman(pm::PowerModels.AbstractPowerModel)
            for (n, _) in PowerModels.nws(pm)
                PowerModels.variable_bus_voltage(pm; nw=n)
                PowerModels.variable_gen_power(pm; nw=n)
                PowerModels.variable_branch_power(pm; nw=n)
                PowerModels.variable_dcline_power(pm; nw=n)
                PowerModels.constraint_model_voltage(pm; nw=n)
                for i in PowerModels.ids(pm, :bus; nw=n)
                    PowerModels.constraint_power_balance(pm, i; nw=n)
                end
                for i in PowerModels.ids(pm, :branch; nw=n)
                    PowerModels.constraint_ohms_yt_from(pm, i; nw=n)
                    PowerModels.constraint_ohms_yt_to(pm, i; nw=n)
                    PowerModels.constraint_voltage_angle_difference(pm, i; nw=n)
                    PowerModels.constraint_thermal_limit_from(pm, i; nw=n)
                    PowerModels.constraint_thermal_limit_to(pm, i; nw=n)
                end
                for i in PowerModels.ids(pm, :dcline; nw=n)
                    PowerModels.constraint_dcline_power_losses(pm, i; nw=n)
                end
            end

            PowerModels.objective_min_fuel_and_flow_cost(pm)

            nw_ids = sort(collect(keys(PowerModels.nws(pm))))

            # Generator reactive-capability limits per hour/network.
            for n in nw_ids
                add_gen_capability!(pm, nets[parse(Int, n) + 1].network["gen"]; nw = n)
            end

            # Express reservoir energy in pu·h (= MWh / BASEMVA) so V_ES variables
            # sit at the same scale as the per-unit pg variables.  The raw MWh scale
            # (O(10^6)) vs pu scale (O(1)) made the KKT matrix too ill-conditioned for
            # HSL solvers to factorize at iteration 0.
            v_es_0_puh = v_es_0 / BASEMVA   # initial reservoir volume [pu·h]

            total_hydro_puh = if isempty(reservoir_gen_ids)
                JuMP.AffExpr(0.0)
            else
                sum(PowerModels.var(pm, n, :pg, gid)
                    for n in nw_ids for gid in reservoir_gen_ids)
            end

            # Both variables carry an explicit lower bound of 0.  They appear only
            # linearly (zero Hessian), so without a bound the log-barrier adds no
            # curvature in their directions and the KKT matrix has wrong inertia —
            # Ipopt then reports "problem in step computation" and bails to restoration
            # at iteration 0.  A lower bound (with an interior start) supplies the
            # missing curvature.  Both bounds are physically valid: reservoir volume
            # is non-negative, and the recentred future cost θ' ≥ 0 because reservoir
            # units only discharge (V_ES_end ≤ v_es_0).
            JuMP.@variable(pm.model, V_ES_puh >= 0)   # reservoir volume at end of day [pu·h]
            JuMP.@variable(pm.model, θ_future >= 0)   # future cost relative to its value at v_es_0 [EUR]
            JuMP.set_start_value(V_ES_puh, v_es_0_puh)   # deep interior (v_es_0_puh ≫ 0)
            JuMP.set_start_value(θ_future, 1.0e3)        # interior, well above the 0 bound
            JuMP.@constraint(pm.model, V_ES_puh == v_es_0_puh - total_hydro_puh)

            # Bellman cuts, recentred about the *starting* reservoir volume v_es_0.
            #
            #   raw cut :  θ  ≥ b + a1·V_ES                       (b ~ 3.5e9 EUR, a1·V_ES ~ -4e8 EUR)
            #   centred :  θ' ≥ (b + a1·v_es_0 − θ_ref) + a1·(V_ES − v_es_0)
            #
            # θ_ref is the binding cut value at v_es_0, so θ' starts at 0 and only
            # carries the dispatch-dependent deviation a1·(V_ES − v_es_0) ~ O(1e6 EUR).
            # The dropped constant θ_ref (~1.5e9 EUR for high-volume days) is independent
            # of the dispatch, so it does not change the optimum — but leaving it in the
            # objective put 10^9-magnitude entries in the KKT system and made the HSL
            # factorization fail for high-volume days such as 2024-07-08.
            θ_ref = isempty(cuts) ? 0.0 : maximum(c.b + c.a1 * v_es_0 for c in cuts)
            for cut in cuts
                const_term = cut.b + cut.a1 * v_es_0 - θ_ref
                # a1 [EUR/MWh] × BASEMVA [MWh/(pu·h)] → slope in EUR/(pu·h)
                JuMP.@constraint(pm.model,
                    θ_future >= const_term + cut.a1 * BASEMVA * (V_ES_puh - v_es_0_puh))
            end

            # Anchor each hour's free units to the DA schedule (quadratic form),
            # mirroring solve_anchored_opf for the constant path.  Frozen units
            # (Nuclear/run-of-river/biomass) already have pmin == pmax == P_DA and
            # are skipped.  nw key "n" corresponds to hour n.
            anchor_pen = zero(JuMP.QuadExpr)
            if ANCHOR_WEIGHT > 0
                for n in nw_ids
                    sched_n = rd_sched_for(date_str, parse(Int, n))
                    sched_n === nothing && continue
                    for gid in PowerModels.ids(pm, :gen; nw=n)
                        g = PowerModels.ref(pm, n, :gen, gid)
                        # Market units anchored when scheduled; batteries always
                        # anchored (to 0 MW when absent from the schedule).
                        tgt_mw =
                            startswith(g["name"], "G")     ? get(sched_n, g["name"], nothing) :
                            startswith(g["name"], "BESS_") ? get(sched_n, g["name"], 0.0) : nothing
                        tgt_mw === nothing && continue
                        abs(g["pmax"] - g["pmin"]) > 1e-9 || continue   # skip frozen
                        tgt_pu = tgt_mw / BASEMVA
                        pg     = PowerModels.var(pm, n, :pg, gid)
                        JuMP.add_to_expression!(anchor_pen, ((pg - tgt_pu) * BASEMVA)^2)
                    end
                end
            end

            current_obj = JuMP.objective_function(pm.model)
            JuMP.@objective(pm.model, Min, current_obj + θ_future + ANCHOR_WEIGHT * anchor_pen)
        end

        @printf "  Solving 24-hour coupled OPF with %s...\n" RD_SOLVER_NAME
        mn_log_file = joinpath(IPOPT_LOG_DIR, "$(date_str)_piecewise.log")
        t_start = time()
        result  = PowerModels.solve_model(mn_data, RD_PM_TYPE,
                                          rd_optimizer_mn(log_file = mn_log_file), build_mn_bellman;
                                          multinetwork=true)
        elapsed = time() - t_start
        status  = string(result["termination_status"])
        @printf "  Solve finished in %.1f s — status: %s  total_objective=%.0f EUR\n" elapsed status result["objective"]

        # Extract per-hour results from the multinetwork solution
        nw_sol = get(get(result, "solution", Dict()), "nw", Dict())
        for (h_idx, ts) in enumerate(eachrow(day_ts))
            hour  = ts.hour
            h_key = string(h_idx - 1)     # "0".."23"
            net   = nets[h_idx]
            sol_h = get(nw_sol, h_key, Dict())

            sol_hour = Dict(
                "gen"    => get(sol_h, "gen",    Dict()),
                "branch" => get(sol_h, "branch", Dict()),
                "bus"    => get(sol_h, "bus",    Dict()),
                "dcline" => get(sol_h, "dcline", Dict()),
            )
            ok = process_hour_solution!(summary_rows, gen_rows_all, fuel_rows_all,
                                        branch_rows_all, bus_rows_all,
                                        sol_hour, net.network, net.gens,
                                        net.branches, net.dclines, net.loads,
                                        date_str, hour, ts.load_mw, status)
            ok && (global n_solved += 1)
        end
    end
end

end  # if RD_ENABLED

# ── 8. Save results ──────────────────────────────────────────
println("\nResults saved to results/")

# Stage 1 — day-ahead cleared schedule + load profile
if DA_ENABLED && RUN_MARKET
    da_df = DataFrame(da_rows_all)
    isempty(da_rows_all) || sort!(da_df, [:date, :hour, order(:dispatch_mw, rev=true)])
    CSV.write(joinpath(RESULTS, "da_dispatch.csv"), da_df)
    CSV.write(joinpath(RESULTS, "da_profiles.csv"),  hourly_da)
    @printf "  da_dispatch.csv  : %d rows\n" nrow(da_df)
end

# Stage 2 — ID2 cleared schedule + load profile
if ID2_ENABLED && RUN_MARKET
    id2_df = DataFrame(id2_rows_all)
    isempty(id2_rows_all) || sort!(id2_df, [:date, :hour, order(:dispatch_mw, rev=true)])
    CSV.write(joinpath(RESULTS, "id2_dispatch.csv"), id2_df)
    CSV.write(joinpath(RESULTS, "id2_profiles.csv"), hourly_id2)
    @printf "  id2_dispatch.csv : %d rows\n" nrow(id2_df)
end

# Stage 3 — ID3 cleared schedule + load profile
if ID3_ENABLED && RUN_MARKET
    id3_df = DataFrame(id3_rows_all)
    isempty(id3_rows_all) || sort!(id3_df, [:date, :hour, order(:dispatch_mw, rev=true)])
    CSV.write(joinpath(RESULTS, "id3_dispatch.csv"), id3_df)
    CSV.write(joinpath(RESULTS, "id3_profiles.csv"), hourly_id3)
    @printf "  id3_dispatch.csv : %d rows\n" nrow(id3_df)
end

# Stage 4 — CID cleared schedule + load profile
if CID_ENABLED && RUN_MARKET
    cid_df = DataFrame(cid_rows_all)
    isempty(cid_rows_all) || sort!(cid_df, [:date, :hour, order(:dispatch_mw, rev=true)])
    CSV.write(joinpath(RESULTS, "cid_dispatch.csv"), cid_df)
    CSV.write(joinpath(RESULTS, "cid_profiles.csv"), hourly_cid)
    @printf "  cid_dispatch.csv : %d rows\n" nrow(cid_df)
end

# Stage 5 — Balancing cleared schedule + load profile
if BAL_ENABLED && RUN_MARKET
    bal_df = DataFrame(bal_rows_all)
    isempty(bal_rows_all) || sort!(bal_df, [:date, :hour, order(:dispatch_mw, rev=true)])
    CSV.write(joinpath(RESULTS, "bal_dispatch.csv"), bal_df)
    CSV.write(joinpath(RESULTS, "bal_profiles.csv"), hourly_bal)
    @printf "  bal_dispatch.csv : %d rows\n" nrow(bal_df)
end

# Stage 5 — redispatch (AC-feasible) solution
if RD_ENABLED
    CSV.write(joinpath(RESULTS, "summary.csv"),      DataFrame(summary_rows))
    CSV.write(joinpath(RESULTS, "gen_dispatch.csv"), DataFrame(gen_rows_all))
    CSV.write(joinpath(RESULTS, "branch_flows.csv"), DataFrame(branch_rows_all))

    fuel_df = DataFrame(fuel_rows_all)
    isempty(fuel_rows_all) || sort!(fuel_df, [:date, :hour, order(:dispatch_mw, rev=true)])
    CSV.write(joinpath(RESULTS, "fuel_mix.csv"), fuel_df)
    CSV.write(joinpath(RESULTS, "bus_voltages.csv"), DataFrame(bus_rows_all))

    @printf "  summary.csv      : %d rows\n" length(summary_rows)
    @printf "  gen_dispatch.csv : %d rows\n" length(gen_rows_all)
    @printf "  fuel_mix.csv     : %d rows\n" nrow(fuel_df)
    @printf "  branch_flows.csv : %d rows\n" length(branch_rows_all)
    @printf "  Solved %d / %d hours successfully\n" n_solved n_total
end
