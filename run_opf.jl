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

using PowerModels, Ipopt, JuMP, CSV, DataFrames, Printf, Dates, Statistics, TOML
import HSL_jll

include("data_preparation.jl")
include("bellman.jl")

# ── 1. Config ────────────────────────────────────────────────
cfg = TOML.parsefile(joinpath(@__DIR__, "config.toml"))

const BELLMAN_METHOD   = cfg["bellman"]["method"]
const BELLMAN_BGN_DATE = Date(cfg["bellman"]["bgn_date"])
const BELLMAN_SSV_STEP = cfg["bellman"]["ssv_step"]
const BELLMAN_FILE     = joinpath(@__DIR__, cfg["bellman"]["bellman_file"])
const VOLUME_FILE      = joinpath(@__DIR__, cfg["bellman"]["volume_file"])

@printf "Bellman method : %s\n" BELLMAN_METHOD
BELLMAN_METHOD ∈ ("constant", "piecewise") ||
    error("config.toml: bellman.method must be \"constant\" or \"piecewise\"")

# ── 2. Load ES probabilistic forecasts (column "23" = best estimate) ─────────
TARGET_DAYS = ["2024-07-08", "2024-12-02"]
ES_DIR      = joinpath(@__DIR__, "Data", "ES")

function es_filename(date_str)
    d = Date(date_str)
    "$(day(d))_$(month(d))_$(year(d)).csv"
end

function load_es_col23(date_str, resource)
    path = joinpath(ES_DIR, resource, es_filename(date_str))
    df   = CSV.read(path, DataFrame)
    sort!(df, :delivery_time)
    return Float64.(df[!, "23"])
end

hourly_rows = NamedTuple[]
for date_str in TARGET_DAYS
    load_vals  = load_es_col23(date_str, "load")
    solar_vals = load_es_col23(date_str, "Solar")
    wind_vals  = load_es_col23(date_str, "Wind")
    for h in 0:23
        push!(hourly_rows, (
            date     = date_str,
            hour     = h,
            load_mw  = load_vals[h + 1],
            solar_mw = solar_vals[h + 1],
            wind_mw  = wind_vals[h + 1],
        ))
    end
end
hourly = DataFrame(hourly_rows)
sort!(hourly, [:date, :hour])

@printf "ES profiles loaded: %d hours across %d days\n" nrow(hourly) length(unique(hourly.date))
for d in unique(hourly.date)
    rows = filter(r -> r.date == d, hourly)
    println("  $d : load $(round(Int,minimum(rows.load_mw)))–$(round(Int,maximum(rows.load_mw))) MW" *
            " | solar $(round(Int,minimum(rows.solar_mw)))–$(round(Int,maximum(rows.solar_mw))) MW" *
            " | wind $(round(Int,minimum(rows.wind_mw)))–$(round(Int,maximum(rows.wind_mw))) MW")
end

# ── 3. Solver setup ──────────────────────────────────────────
PowerModels.silence()
mkpath(joinpath(@__DIR__, "results"))
RESULTS = joinpath(@__DIR__, "results")

const HSL_SOLVERS = Set(["ma27", "ma57", "ma77", "ma86", "ma97"])

function hsl_is_functional()
    try
        return @ccall HSL_jll.libhsl.LIBHSL_isfunctional()::Bool
    catch err
        @warn "Could not verify HSL_jll." exception = (err, catch_backtrace())
        return false
    end
end

function ipopt_linear_solver()
    requested = lowercase(get(ENV, "IPOPT_LINEAR_SOLVER", "ma97"))
    if requested in HSL_SOLVERS && !hsl_is_functional()
        @warn "HSL not functional; falling back to mumps."
        return "mumps"
    end
    return requested
end

const IPOPT_LINEAR_SOLVER = ipopt_linear_solver()

# Single-period solver (one hour at a time)
const IPOPT = optimizer_with_attributes(
    Ipopt.Optimizer,
    "print_level"   => 0,
    "tol"           => 1e-4,
    "max_iter"      => 500,
    "linear_solver" => IPOPT_LINEAR_SOLVER,
)

# Multi-period solver (24 hours coupled — larger problem, needs more iterations)
# print_level=3 + print_frequency_iter=100 shows a one-line update every 100 iterations
const IPOPT_MN = optimizer_with_attributes(
    Ipopt.Optimizer,
    "print_level"          => 3,
    "print_frequency_iter" => 100,
    "tol"                  => 1e-4,
    "max_iter"             => 3000,
    "linear_solver"        => IPOPT_LINEAR_SOLVER,
)

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

        total_gen_mw      = sum(v["pg"] * BASEMVA for v in values(sol_gen))
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
            mismatch_mw     = round(total_gen_mw - total_load_mw_out; digits=2),
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
        @printf "  h%02d  load=%.0f MW  cost=%.0f EUR/h  congested=%d\n" hour load_mw op_cost n_cong
        return true
    else
        push!(summary_rows, (
            date            = date_str,
            hour            = hour,
            status          = status,
            objective_eur_h = NaN,
            total_gen_mw    = NaN,
            total_load_mw   = load_mw,
            mismatch_mw     = NaN,
        ))
        @printf "  h%02d  FAILED: %s\n" hour status
        return false
    end
end

# ── 6. Bellman pre-computation ───────────────────────────────
println("\nBellman pre-computation:")
day_bellman = Dict{String,NamedTuple}()
for date_str in unique(hourly.date)
    stage = bellman_stage(date_str, BELLMAN_BGN_DATE, BELLMAN_SSV_STEP)
    cuts  = load_cuts_at_stage(BELLMAN_FILE, stage)
    v_es  = v_es_at_date(VOLUME_FILE, date_str, BELLMAN_BGN_DATE)
    wv    = binding_water_value(cuts, v_es)
    day_bellman[date_str] = (stage=stage, cuts=cuts, v_es=v_es, water_value=wv)
    @printf "  %s : stage=%d  V_ES=%.0f MWh  water_value=%.2f EUR/MWh\n" date_str stage v_es wv
end

# ── 7. Main solve ─────────────────────────────────────────────
n_total  = nrow(hourly)
n_solved = 0

# ────────────────────────────────────────────────────────────
# Method A — constant water value (hour-by-hour)
# ────────────────────────────────────────────────────────────
if BELLMAN_METHOD == "constant"

    for ts in eachrow(hourly)
        date_str = ts.date
        hour     = ts.hour
        bv       = day_bellman[date_str]
        label    = "$date_str h$(lpad(hour, 2, '0'))"

        net = prepare_network(ts.load_mw, ts.solar_mw, ts.wind_mw;
                              hydro_reservoir_cost = bv.water_value)
        (; network, gens, branches, dclines, loads) = net

        result = solve_ac_opf(network, IPOPT)
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
elseif BELLMAN_METHOD == "piecewise"

    for date_str in TARGET_DAYS
        bv     = day_bellman[date_str]
        day_ts = filter(r -> r.date == date_str, hourly)

        @printf "\n[Piecewise] %s  stage=%d  V_ES_start=%.0f MWh\n" date_str bv.stage bv.v_es

        # Build 24 networks; reservoir hydro cost = 0 (opportunity cost captured by θ_future)
        nets = [prepare_network(ts.load_mw, ts.solar_mw, ts.wind_mw;
                                hydro_reservoir_cost = 0.0)
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

            # Total reservoir hydro energy dispatched across all 24 hours [MWh]
            total_hydro_mwh = if isempty(reservoir_gen_ids)
                0.0
            else
                sum(PowerModels.var(pm, n, :pg, gid) * BASEMVA
                    for n in nw_ids for gid in reservoir_gen_ids)
            end

            # V_ES_end: reservoir volume at end of day
            JuMP.@variable(pm.model, V_ES_end)
            JuMP.@variable(pm.model, θ_future)
            JuMP.@constraint(pm.model, V_ES_end == v_es_0 - total_hydro_mwh)

            # Bellman cuts: piecewise-linear lower bound on future cost
            for cut in cuts
                JuMP.@constraint(pm.model, θ_future >= cut.b + cut.a1 * V_ES_end)
            end

            # Add future cost to the operational objective
            current_obj = JuMP.objective_function(pm.model)
            JuMP.@objective(pm.model, Min, current_obj + θ_future)
        end

        @printf "  Solving 24-hour coupled OPF (Ipopt progress below)...\n"
        t_start = time()
        result  = PowerModels.solve_model(mn_data, ACPPowerModel, IPOPT_MN, build_mn_bellman;
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

# ── 8. Save results ──────────────────────────────────────────
CSV.write(joinpath(RESULTS, "summary.csv"),      DataFrame(summary_rows))
CSV.write(joinpath(RESULTS, "gen_dispatch.csv"), DataFrame(gen_rows_all))
CSV.write(joinpath(RESULTS, "branch_flows.csv"), DataFrame(branch_rows_all))

fuel_df = DataFrame(fuel_rows_all)
isempty(fuel_rows_all) || sort!(fuel_df, [:date, :hour, order(:dispatch_mw, rev=true)])
CSV.write(joinpath(RESULTS, "fuel_mix.csv"), fuel_df)
CSV.write(joinpath(RESULTS, "bus_voltages.csv"), DataFrame(bus_rows_all))

println("\nResults saved to results/")
@printf "  summary.csv      : %d rows\n" length(summary_rows)
@printf "  gen_dispatch.csv : %d rows\n" length(gen_rows_all)
@printf "  fuel_mix.csv     : %d rows\n" nrow(fuel_df)
@printf "  branch_flows.csv : %d rows\n" length(branch_rows_all)
@printf "  Solved %d / %d hours successfully\n" n_solved n_total
