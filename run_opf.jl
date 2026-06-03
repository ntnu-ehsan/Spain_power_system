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

include("data_preparation.jl")
include("bellman.jl")
include("intraday.jl")

# ── 1. Config ────────────────────────────────────────────────
cfg = TOML.parsefile(joinpath(@__DIR__, "config.toml"))

const BELLMAN_METHOD   = cfg["bellman"]["method"]
const BELLMAN_BGN_DATE = Date(cfg["bellman"]["bgn_date"])
const BELLMAN_SSV_STEP = cfg["bellman"]["ssv_step"]
const BELLMAN_FILE     = joinpath(@__DIR__, cfg["bellman"]["bellman_file"])
const VOLUME_FILE      = joinpath(@__DIR__, cfg["bellman"]["volume_file"])

const REDISPATCH = get(get(cfg, "redispatch", Dict()), "enabled", false)
@printf "Redispatch mode: %s\n" (REDISPATCH ? "ON (intraday warm-start + fixed non-dispatchables)" : "OFF (cost-minimising dispatch)")

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

function ipopt_linear_solver()
    lowercase(get(ENV, "IPOPT_LINEAR_SOLVER", "mumps"))
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
const IPOPT_MN = optimizer_with_attributes(
    Ipopt.Optimizer,
    "print_level"          => 5,
    "print_frequency_iter" => 1,
    "tol"                  => 5e-4,
    "max_iter"             => 5000,
    "linear_solver"        => IPOPT_LINEAR_SOLVER,
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

# ── 5b. Redispatch model builder ─────────────────────────────
# Standard single-period AC OPF, but the objective is replaced by the cost of
# redispatching away from the intraday set-points:
#
#   min  Σ_g c_g · (Δup_g + Δdown_g)
#   s.t. pg_g = pg0_g + Δup_g − Δdown_g,   Δup_g, Δdown_g ≥ 0
#
# c_g is the unit marginal cost (reservoir hydro = water value); the slack's
# huge cost keeps it near zero.  Fixed non-dispatchable units have pmin=pmax=pg0,
# so their deviation is forced to zero and they contribute nothing to the cost.
function redispatch_build(gens_dict)
    ids = sort([g["index"] for g in values(gens_dict)])
    pg0 = Dict(g["index"] => g["pg0"]     for g in values(gens_dict))
    c1  = Dict(g["index"] => g["cost"][1] for g in values(gens_dict))
    return function (pm::PowerModels.AbstractPowerModel)
        PowerModels.build_opf(pm)   # vars + constraints + (fuel-cost) objective
        rup = JuMP.@variable(pm.model, [i in ids], lower_bound = 0.0, base_name = "rup")
        rdn = JuMP.@variable(pm.model, [i in ids], lower_bound = 0.0, base_name = "rdn")
        for i in ids
            JuMP.@constraint(pm.model, PowerModels.var(pm, :pg, i) == pg0[i] + rup[i] - rdn[i])
        end
        JuMP.@objective(pm.model, Min, sum(c1[i] * (rup[i] + rdn[i]) for i in ids))
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

# ── 6b. Intraday dispatch pre-load (redispatch initial operating point) ──
day_intraday = Dict{String,Dict{String,Vector{Float64}}}()
if REDISPATCH
    println("\nIntraday dispatch pre-load:")
    for date_str in unique(hourly.date)
        disp = load_intraday_dispatch(date_str)
        day_intraday[date_str] = disp
        day_total = sum(sum(v) for v in values(disp)) / 24
        @printf "  %s : %d units, mean daily dispatch %.0f MW\n" date_str length(disp) day_total
    end
end

# Per-hour intraday set-points for `date_str` at `hour`, or nothing if redispatch off.
intraday_pg_for(date_str, hour) =
    REDISPATCH ? intraday_hour(day_intraday[date_str], hour) : nothing

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
                              hydro_reservoir_cost = bv.water_value,
                              intraday_pg = intraday_pg_for(date_str, hour))
        (; network, gens, branches, dclines, loads) = net

        result = REDISPATCH ?
            PowerModels.solve_model(network, ACPPowerModel, IPOPT, redispatch_build(gens)) :
            solve_ac_opf(network, IPOPT)
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
                                hydro_reservoir_cost = 0.0,
                                intraday_pg = intraday_pg_for(date_str, ts.hour))
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

        # Per-network intraday reference set-points & marginal costs (redispatch objective)
        pg0_nw = Dict(h => Dict(g["index"] => g["pg0"]     for g in values(nets[h+1].gens)) for h in 0:23)
        c1_nw  = Dict(h => Dict(g["index"] => g["cost"][1] for g in values(nets[h+1].gens)) for h in 0:23)

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

            nw_ids = sort(collect(keys(PowerModels.nws(pm))))

            # Base objective: pure fuel cost, or redispatch deviation cost (redispatch mode).
            #   redispatch:  Σ_n Σ_g c_g·(Δup + Δdown),  pg = pg0 + Δup − Δdown
            base_obj = if REDISPATCH
                dev = JuMP.AffExpr(0.0)
                for n in nw_ids
                    pg0_n = pg0_nw[n]
                    c1_n  = c1_nw[n]
                    for i in PowerModels.ids(pm, :gen; nw=n)
                        rup = JuMP.@variable(pm.model, lower_bound = 0.0, base_name = "rup_$(n)_$(i)")
                        rdn = JuMP.@variable(pm.model, lower_bound = 0.0, base_name = "rdn_$(n)_$(i)")
                        JuMP.@constraint(pm.model,
                            PowerModels.var(pm, n, :pg, i) == pg0_n[i] + rup - rdn)
                        JuMP.add_to_expression!(dev, c1_n[i], rup)
                        JuMP.add_to_expression!(dev, c1_n[i], rdn)
                    end
                end
                dev
            else
                PowerModels.objective_min_fuel_and_flow_cost(pm)
                JuMP.objective_function(pm.model)
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

            JuMP.@objective(pm.model, Min, base_obj + θ_future)
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
