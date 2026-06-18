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

# ── 1. Config ────────────────────────────────────────────────
cfg = TOML.parsefile(joinpath(@__DIR__, "config.toml"))

const BELLMAN_BGN_DATE = Date(cfg["bellman"]["bgn_date"])
const BELLMAN_SSV_STEP = cfg["bellman"]["ssv_step"]
const BELLMAN_FILE     = joinpath(@__DIR__, cfg["bellman"]["bellman_file"])
const VOLUME_FILE      = joinpath(@__DIR__, cfg["bellman"]["volume_file"])

const VOLTAGE_BAND       = Float64(get(get(cfg, "network", Dict()), "voltage_band", 0.05))
const LINE_RATING_FACTOR = Float64(get(get(cfg, "network", Dict()), "line_rating_factor", 0.70))
@printf "Voltage band   : ±%.1f %% (%.2f–%.2f pu)\n" (100 * VOLTAGE_BAND) (1 - VOLTAGE_BAND) (1 + VOLTAGE_BAND)
@printf "Line rating    : %.0f %% of nameplate\n" (100 * LINE_RATING_FACTOR)

const CROSSBORDER = get(get(cfg, "crossborder", Dict()), "enabled", false)
@printf "Cross-border   : %s\n" (CROSSBORDER ? "ON" : "OFF")

# ── Market-chain stages ──────────────────────────────────────
# Stage 1 (DA):  copper-plate, 24h Bellman-coupled, DA forecast (-12h) data.
# Stage 2 (ID):  same copper-plate formulation, -2h forecast data, Nuclear fixed at DA.
# Stage 3 (CID): same copper-plate formulation, actual (col 23) data, Nuclear fixed at DA.
# Stage 4 (RD):  AC OPF anchored to CID; Nuclear/Biomass/Coal/ROR frozen at CID (=DA) values.
const DA_ENABLED  = get(get(cfg, "da",         Dict()), "enabled", true)
const ID2_ENABLED = get(get(cfg, "id2",        Dict()), "enabled", true)
const ID3_ENABLED = get(get(cfg, "id3",        Dict()), "enabled", true)
const CID_ENABLED = get(get(cfg, "cid",        Dict()), "enabled", true)
const RD_ENABLED  = get(get(cfg, "redispatch", Dict()), "enabled", true)
const RD_WATER_VALUE = lowercase(get(get(cfg, "redispatch", Dict()), "water_value", "constant"))
const RD_OBJECTIVE   = lowercase(get(get(cfg, "redispatch", Dict()), "objective", "quadratic"))
const ANCHOR_WEIGHT  = Float64(get(get(cfg, "redispatch", Dict()), "anchor_weight", 0.0))

ID2_ENABLED && !DA_ENABLED  && error("config.toml: [id2].enabled requires [da].enabled")
ID3_ENABLED && !ID2_ENABLED && error("config.toml: [id3].enabled requires [id2].enabled")
CID_ENABLED && !DA_ENABLED  && error("config.toml: [cid].enabled requires [da].enabled")
RD_ENABLED  && !DA_ENABLED  && error("config.toml: [redispatch].enabled requires [da].enabled")
RD_WATER_VALUE ∈ ("constant", "piecewise") ||
    error("config.toml: [redispatch].water_value must be \"constant\" or \"piecewise\"")
RD_OBJECTIVE ∈ ("quadratic", "cost_weighted") ||
    error("config.toml: [redispatch].objective must be \"quadratic\" or \"cost_weighted\"")

rd_anchor_label() = CID_ENABLED  ? "CID"  :
                    ID3_ENABLED  ? "ID3"  :
                    ID2_ENABLED  ? "ID2"  : "DA"
@printf "Day-ahead      : %s\n" (DA_ENABLED  ? "ON (copper-plate, 24h Bellman-coupled)" : "OFF")
@printf "Intraday (ID2) : %s\n" (ID2_ENABLED ? "ON (copper-plate, Nuclear fixed at DA)" : "OFF")
@printf "Intraday (ID3) : %s\n" (ID3_ENABLED ? "ON (copper-plate, Nuclear fixed at DA)" : "OFF")
@printf "Intraday (CID) : %s\n" (CID_ENABLED ? "ON (copper-plate, Nuclear fixed at DA)" : "OFF")
@printf "Redispatch     : %s\n" (RD_ENABLED  ?
    @sprintf("ON  anchor=%s  water_value=%s  objective=%s  w=%.4g",
             rd_anchor_label(), RD_WATER_VALUE, RD_OBJECTIVE, ANCHOR_WEIGHT) : "OFF")

# ── 2. Load ES profiles ───────────────────────────────────────────────────────
# Actual MW at each stage = scale_factor × base_MW, where:
#   base_MW    : ES_old col "-12" (day-ahead baseline, MW)
#   scale_factor: stage column (DA/ID2/ID3/CID) from the new ES/ files (0–1 range)
# DA scale factors are always 1.0, so DA profiles equal the ES_old -12 baseline.
# Stages modelled: DA → ID2 → ID3 → CID → Redispatch.  BE column is ignored.
TARGET_DAYS = ["2024-07-08", "2024-12-02"]
ES_OLD_DIR  = joinpath(@__DIR__, "Data", "ES_old")
ES_NEW_DIR  = joinpath(@__DIR__, "Data", "ES")

function es_filename(date_str)
    d = Date(date_str)
    "$(day(d))_$(month(d))_$(year(d)).csv"
end

# Returns 24-element vector of MW values for a given stage.
# new_resource: folder name under Data/ES/      (e.g. "Wind Onshore")
# old_resource: folder name under Data/ES_old/  (e.g. "Wind")
function load_scaled_col(date_str, new_resource, old_resource, stage_col)
    base_df = CSV.read(joinpath(ES_OLD_DIR, old_resource, es_filename(date_str)), DataFrame)
    sort!(base_df, :delivery_time)
    base_mw = Float64.(base_df[!, "-12"])
    scale_df = CSV.read(joinpath(ES_NEW_DIR, new_resource, es_filename(date_str)), DataFrame)
    scale    = Float64.(scale_df[!, stage_col])
    return base_mw .* scale
end

hourly_da_rows  = NamedTuple[]
hourly_id2_rows = NamedTuple[]
hourly_id3_rows = NamedTuple[]
hourly_cid_rows = NamedTuple[]
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
    for h in 0:23
        push!(hourly_da_rows,  (date=date_str, hour=h, load_mw=load_da[h+1],  solar_mw=solar_da[h+1],  wind_mw=wind_da[h+1]))
        push!(hourly_id2_rows, (date=date_str, hour=h, load_mw=load_id2[h+1], solar_mw=solar_id2[h+1], wind_mw=wind_id2[h+1]))
        push!(hourly_id3_rows, (date=date_str, hour=h, load_mw=load_id3[h+1], solar_mw=solar_id3[h+1], wind_mw=wind_id3[h+1]))
        push!(hourly_cid_rows, (date=date_str, hour=h, load_mw=load_cid[h+1], solar_mw=solar_cid[h+1], wind_mw=wind_cid[h+1]))
    end
end
hourly_da  = DataFrame(hourly_da_rows);  sort!(hourly_da,  [:date, :hour])
hourly_id2 = DataFrame(hourly_id2_rows); sort!(hourly_id2, [:date, :hour])
hourly_id3 = DataFrame(hourly_id3_rows); sort!(hourly_id3, [:date, :hour])
hourly_cid = DataFrame(hourly_cid_rows); sort!(hourly_cid, [:date, :hour])

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

# ── 3. Solver setup ──────────────────────────────────────────
PowerModels.silence()
mkpath(joinpath(@__DIR__, "results"))
RESULTS = joinpath(@__DIR__, "results")

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
                vm_pu  = round(v["vm"];          digits=4),
                va_deg = round(rad2deg(v["va"]); digits=3),
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
            qg_mvar  = get(v, "qg", 0.0) * BASEMVA
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
            qf_mvar = get(v, "qf", 0.0) * BASEMVA
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
            qf_mvar = get(v, "qf", 0.0) * BASEMVA
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
    cuts  = load_cuts_at_stage(BELLMAN_FILE, stage)
    v_es  = v_es_at_date(VOLUME_FILE, date_str, BELLMAN_BGN_DATE)
    wv    = binding_water_value(cuts, v_es)
    day_bellman[date_str] = (stage=stage, cuts=cuts, v_es=v_es, water_value=wv)
    @printf "  %s : stage=%d  V_ES=%.0f MWh  water_value=%.2f EUR/MWh\n" date_str stage v_es wv
end

# ── 6b. Cross-border exchange pre-load ───────────────────────
xb_data  = Dict{String,Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}}()
xb_fracs = Dict{String,Dict{String,Float64}}()
if CROSSBORDER
    xb_data  = load_crossborder()
    xb_fracs = crossborder_bus_fractions()
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

da_rows_all  = []
id2_rows_all = []
id3_rows_all = []
cid_rows_all = []
da_schedule  = Dict{Tuple{String,Int},Dict{String,Float64}}()
id2_schedule = Dict{Tuple{String,Int},Dict{String,Float64}}()
id3_schedule = Dict{Tuple{String,Int},Dict{String,Float64}}()
cid_schedule = Dict{Tuple{String,Int},Dict{String,Float64}}()

# Helper: build 24 energy-only networks for one day using the given hourly profile.
# nuclear_sched: the full da_schedule dict — when provided, Nuclear units are frozen
# at their DA dispatch values (pmin=pmax) for this copper-plate stage.
function build_da_nets(date_str, day_ts; nuclear_sched = nothing)
    [prepare_network(ts.load_mw, ts.solar_mw, ts.wind_mw;
                     hydro_reservoir_cost = 0.0,
                     crossborder_inj = crossborder_inj_for(date_str, ts.hour),
                     nuclear_da_dispatch = nuclear_sched === nothing ? nothing :
                                           get(nuclear_sched, (date_str, ts.hour), nothing),
                     voltage_band = VOLTAGE_BAND,
                     line_rating_factor = LINE_RATING_FACTOR)
     for ts in eachrow(day_ts)]
end

# Helper: run solve_da and populate a schedule dict + rows accumulator.
function run_copper_plate!(schedule, rows_acc, label, date_str, day_ts, bv, log_tag;
                            nuclear_sched = nothing)
    nets = build_da_nets(date_str, day_ts; nuclear_sched = nuclear_sched)
    reservoir_gen_ids = sort([parse(Int, k) for (k, g) in nets[1].gens
                               if g["fuel"] == "Hydro" &&
                                  lowercase(g["technology"]) == "reservoir"])
    log_file = joinpath(IPOPT_LOG_DIR, "$(date_str)_$(log_tag).log")
    t_start  = time()
    result   = solve_da(nets, reservoir_gen_ids, bv.cuts, bv.v_es,
                        gurobi_da(log_file = log_file))
    @printf "  %s %s : status=%s  cost=%.0f EUR  (%.1f s)\n" label date_str result.status result.objective (time() - t_start)
    result.status ∈ ("OPTIMAL", "LOCALLY_SOLVED") ||
        error("$label dispatch failed for $date_str: $(result.status)")
    for (h_idx, ts) in enumerate(eachrow(day_ts))
        hour = ts.hour
        schedule[(date_str, hour)] = result.sched[h_idx]
        for (k, g) in nets[h_idx].gens
            push!(rows_acc, (
                date        = date_str,
                hour        = hour,
                gen_id      = g["name"],
                fuel        = g["fuel"],
                technology  = g["technology"],
                dispatch_mw = round(result.sched[h_idx][g["name"]]; digits = 2),
            ))
        end
    end
end

if DA_ENABLED
    println("\n── Stage 1: Day-ahead market (copper-plate, 24h Bellman-coupled) ──")
    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly_da)
        run_copper_plate!(da_schedule, da_rows_all, "DA", date_str, day_ts, bv, "da")
    end
end

da_sched_for(date_str, hour) = get(da_schedule, (date_str, hour), nothing)

if ID2_ENABLED
    println("\n── Stage 2: Intraday market ID2 (copper-plate, Nuclear fixed at DA) ──")
    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly_id2)
        run_copper_plate!(id2_schedule, id2_rows_all, "ID2", date_str, day_ts, bv, "id2";
                          nuclear_sched = da_schedule)
    end
end

id2_sched_for(date_str, hour) = get(id2_schedule, (date_str, hour), nothing)

if ID3_ENABLED
    println("\n── Stage 3: Intraday market ID3 (copper-plate, Nuclear fixed at DA) ──")
    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly_id3)
        run_copper_plate!(id3_schedule, id3_rows_all, "ID3", date_str, day_ts, bv, "id3";
                          nuclear_sched = da_schedule)
    end
end

id3_sched_for(date_str, hour) = get(id3_schedule, (date_str, hour), nothing)

if CID_ENABLED
    println("\n── Stage 4: Intraday market CID (copper-plate, Nuclear fixed at DA) ──")
    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly_cid)
        run_copper_plate!(cid_schedule, cid_rows_all, "CID", date_str, day_ts, bv, "cid";
                          nuclear_sched = da_schedule)
    end
end

cid_sched_for(date_str, hour) = get(cid_schedule, (date_str, hour), nothing)
# Redispatch anchors to the last cleared schedule: CID > ID3 > ID2 > DA.
rd_sched_for(date_str, hour) = CID_ENABLED  ? cid_sched_for(date_str, hour)  :
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
function solve_anchored_opf(network, gens, optimizer, sched)
    if sched === nothing || (RD_OBJECTIVE == "quadratic" && ANCHOR_WEIGHT <= 0)
        return solve_ac_opf(network, optimizer)
    end
    pm = PowerModels.instantiate_model(network, PowerModels.ACPPowerModel, PowerModels.build_opf)

    if RD_OBJECTIVE == "quadratic"
        pen = zero(JuMP.QuadExpr)
        for (_, g) in gens
            startswith(g["name"], "G") || continue
            haskey(sched, g["name"]) || continue
            tgt_pu = sched[g["name"]] / BASEMVA
            pg     = PowerModels.var(pm, :pg, g["index"])
            JuMP.add_to_expression!(pen, ((pg - tgt_pu) * BASEMVA)^2)
        end
        base_obj = JuMP.objective_function(pm.model)
        JuMP.@objective(pm.model, Min, base_obj + ANCHOR_WEIGHT * pen)
    else   # cost_weighted
        dev = zero(JuMP.AffExpr)
        for (_, g) in gens
            pg = PowerModels.var(pm, :pg, g["index"])
            if startswith(g["name"], "G") && haskey(sched, g["name"]) &&
               abs(g["pmax"] - g["pmin"]) > 1e-9                 # free, anchored unit
                tgt_pu = sched[g["name"]] / BASEMVA
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
    return PowerModels.optimize_model!(pm; optimizer = optimizer)
end

# ── 7. Stage 4 — Redispatch (AC OPF anchored to CID/ID/DA schedule) ──
# Uses CID actual values for wind/solar/load and anchors to the last cleared schedule.
n_total  = nrow(hourly_cid)
n_solved = 0

if RD_ENABLED
println("\n── Stage 4: Redispatch (AC OPF anchored to $(rd_anchor_label())) ──")

# ────────────────────────────────────────────────────────────
# Method A — constant water value (hour-by-hour)
# ────────────────────────────────────────────────────────────
if RD_WATER_VALUE == "constant"

    for ts in eachrow(hourly_cid)
        date_str = ts.date
        hour     = ts.hour
        bv       = day_bellman[date_str]
        label    = "$date_str h$(lpad(hour, 2, '0'))"

        net = prepare_network(ts.load_mw, ts.solar_mw, ts.wind_mw;
                              hydro_reservoir_cost = bv.water_value,
                              crossborder_inj = crossborder_inj_for(date_str, hour),
                              da_dispatch = rd_sched_for(date_str, hour),
                              voltage_band = VOLTAGE_BAND,
                              line_rating_factor = LINE_RATING_FACTOR)
        (; network, gens, branches, dclines, loads) = net

        log_file = joinpath(IPOPT_LOG_DIR, "$(date_str)_h$(lpad(hour, 2, '0')).log")
        result = solve_anchored_opf(network, gens, ipopt_single(log_file = log_file),
                                    rd_sched_for(date_str, hour))
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
        day_ts = filter(r -> r.date == date_str, hourly_cid)

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
                                line_rating_factor = LINE_RATING_FACTOR)
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
                        startswith(g["name"], "G") || continue
                        haskey(sched_n, g["name"]) || continue
                        abs(g["pmax"] - g["pmin"]) > 1e-9 || continue   # skip frozen
                        tgt_pu = sched_n[g["name"]] / BASEMVA
                        pg     = PowerModels.var(pm, n, :pg, gid)
                        JuMP.add_to_expression!(anchor_pen, ((pg - tgt_pu) * BASEMVA)^2)
                    end
                end
            end

            current_obj = JuMP.objective_function(pm.model)
            JuMP.@objective(pm.model, Min, current_obj + θ_future + ANCHOR_WEIGHT * anchor_pen)
        end

        @printf "  Solving 24-hour coupled OPF (Ipopt progress below)...\n"
        mn_log_file = joinpath(IPOPT_LOG_DIR, "$(date_str)_piecewise.log")
        t_start = time()
        result  = PowerModels.solve_model(mn_data, ACPPowerModel,
                                          ipopt_mn(log_file = mn_log_file), build_mn_bellman;
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
if DA_ENABLED
    da_df = DataFrame(da_rows_all)
    isempty(da_rows_all) || sort!(da_df, [:date, :hour, order(:dispatch_mw, rev=true)])
    CSV.write(joinpath(RESULTS, "da_dispatch.csv"), da_df)
    CSV.write(joinpath(RESULTS, "da_profiles.csv"),  hourly_da)
    @printf "  da_dispatch.csv  : %d rows\n" nrow(da_df)
end

# Stage 2 — ID2 cleared schedule + load profile
if ID2_ENABLED
    id2_df = DataFrame(id2_rows_all)
    isempty(id2_rows_all) || sort!(id2_df, [:date, :hour, order(:dispatch_mw, rev=true)])
    CSV.write(joinpath(RESULTS, "id2_dispatch.csv"), id2_df)
    CSV.write(joinpath(RESULTS, "id2_profiles.csv"), hourly_id2)
    @printf "  id2_dispatch.csv : %d rows\n" nrow(id2_df)
end

# Stage 3 — ID3 cleared schedule + load profile
if ID3_ENABLED
    id3_df = DataFrame(id3_rows_all)
    isempty(id3_rows_all) || sort!(id3_df, [:date, :hour, order(:dispatch_mw, rev=true)])
    CSV.write(joinpath(RESULTS, "id3_dispatch.csv"), id3_df)
    CSV.write(joinpath(RESULTS, "id3_profiles.csv"), hourly_id3)
    @printf "  id3_dispatch.csv : %d rows\n" nrow(id3_df)
end

# Stage 4 — CID cleared schedule + load profile
if CID_ENABLED
    cid_df = DataFrame(cid_rows_all)
    isempty(cid_rows_all) || sort!(cid_df, [:date, :hour, order(:dispatch_mw, rev=true)])
    CSV.write(joinpath(RESULTS, "cid_dispatch.csv"), cid_df)
    CSV.write(joinpath(RESULTS, "cid_profiles.csv"), hourly_cid)
    @printf "  cid_dispatch.csv : %d rows\n" nrow(cid_df)
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
