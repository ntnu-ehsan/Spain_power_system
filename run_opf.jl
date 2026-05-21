# ============================================================
# Spain Power System — DC OPF Solver
# ============================================================
# Loads the prepared network, runs DC OPF with HiGHS, and
# saves results to results/ as CSV files for downstream plots.
#
# Usage:
#   julia run_opf.jl
# ============================================================

import Pkg
Pkg.activate(@__DIR__)

using PowerModels, HiGHS, CSV, DataFrames, Printf

include("data_preparation.jl")

# ── 1. Build network ─────────────────────────────────────────
println("Preparing network data …")
net = prepare_network()
(; network, gens, branches, loads, bus_idx, bus_df, gen_df) = net

@printf "  Buses      : %d\n" length(network["bus"])
@printf "  Branches   : %d\n" length(network["branch"])
@printf "  Generators : %d\n" length(network["gen"])
@printf "  Loads      : %d\n" length(network["load"])
@printf "  Total load : %.1f MW\n"          sum(v["pd"] for v in values(loads)) * BASEMVA
@printf "  Total gen capacity: %.1f MW\n"   sum(v["pmax"] for v in values(gens)) * BASEMVA

# ── 2. Run DC OPF ────────────────────────────────────────────
PowerModels.silence()
println("\nRunning DC OPF …")
result = solve_dc_opf(network, HiGHS.Optimizer)

status = result["termination_status"]
println("\n" * "="^60)
@printf "DC OPF status : %s\n" status
haskey(result, "objective") && @printf "Total cost    : %.2f €/h\n" result["objective"]
println("="^60)

# ── 3. Save results ──────────────────────────────────────────
mkpath(joinpath(@__DIR__, "results"))
RESULTS = joinpath(@__DIR__, "results")

if string(status) ∈ ("OPTIMAL", "LOCALLY_SOLVED")
    sol_gen    = result["solution"]["gen"]
    sol_branch = result["solution"]["branch"]

    total_gen_mw  = sum(v["pg"] * BASEMVA for v in values(sol_gen))
    total_load_mw = sum(v["pd"] * BASEMVA for v in values(loads))

    @printf "\nTotal generation : %8.1f MW\n" total_gen_mw
    @printf "Total load       : %8.1f MW\n"  total_load_mw
    @printf "Mismatch         : %8.2f MW\n"  total_gen_mw - total_load_mw

    # ── summary.csv ──────────────────────────────────────────
    CSV.write(joinpath(RESULTS, "summary.csv"), DataFrame(
        status         = [string(status)],
        objective_eur_h = [round(result["objective"]; digits=2)],
        total_gen_mw   = [round(total_gen_mw;  digits=1)],
        total_load_mw  = [round(total_load_mw; digits=1)],
        mismatch_mw    = [round(total_gen_mw - total_load_mw; digits=2)],
    ))

    # ── gen_dispatch.csv ─────────────────────────────────────
    gen_rows = []
    for (k, v) in sol_gen
        g       = gens[k]
        pg_mw   = v["pg"] * BASEMVA
        cap_mw  = g["pmax"] * BASEMVA
        util    = cap_mw > 0 ? 100 * pg_mw / cap_mw : 0.0
        cost_mwh = cap_mw > 0 ? g["cost"][1] / BASEMVA : 0.0
        push!(gen_rows, (
            gen_id       = k,
            unit_name    = g["name"],
            fuel         = g["fuel"],
            technology   = g["technology"],
            bus_i        = g["gen_bus"],
            capacity_mw  = round(cap_mw;  digits=2),
            dispatch_mw  = round(pg_mw;   digits=2),
            utilization_pct = round(util; digits=1),
            cost_eur_per_mwh = round(cost_mwh; digits=2),
        ))
    end
    CSV.write(joinpath(RESULTS, "gen_dispatch.csv"), DataFrame(gen_rows))

    # ── fuel_mix.csv ─────────────────────────────────────────
    fuel_disp = Dict{String,Float64}()
    fuel_cap  = Dict{String,Float64}()
    for (k, v) in sol_gen
        g    = gens[k]
        fuel = g["fuel"]
        fuel_disp[fuel] = get(fuel_disp, fuel, 0.0) + v["pg"] * BASEMVA
        fuel_cap[fuel]  = get(fuel_cap,  fuel, 0.0) + g["pmax"] * BASEMVA
    end
    fuel_rows = [(
        fuel            = f,
        dispatch_mw     = round(fuel_disp[f]; digits=1),
        capacity_mw     = round(fuel_cap[f];  digits=1),
        utilization_pct = round(100 * fuel_disp[f] / max(fuel_cap[f], 1e-6); digits=1),
    ) for f in keys(fuel_disp)]
    sort!(fuel_rows; by = r -> -r.dispatch_mw)
    CSV.write(joinpath(RESULTS, "fuel_mix.csv"), DataFrame(fuel_rows))

    # ── branch_flows.csv ─────────────────────────────────────
    branch_rows = []
    for (k, v) in sol_branch
        br      = branches[k]
        pf_mw   = v["pf"] * BASEMVA
        rate_mw = br["rate_a"] * BASEMVA
        loading = rate_mw > 0 ? abs(100 * pf_mw / rate_mw) : 0.0
        push!(branch_rows, (
            branch_id   = k,
            branch_name = br["name"],
            from_bus    = br["f_bus"],
            to_bus      = br["t_bus"],
            flow_mw     = round(pf_mw;   digits=2),
            limit_mw    = round(rate_mw; digits=2),
            loading_pct = round(loading; digits=1),
        ))
    end
    sort!(branch_rows; by = r -> -r.loading_pct)
    CSV.write(joinpath(RESULTS, "branch_flows.csv"), DataFrame(branch_rows))

    println("\nResults saved to results/")
    println("  summary.csv, gen_dispatch.csv, fuel_mix.csv, branch_flows.csv")

    # ── Console summary ───────────────────────────────────────
    println("\nDispatch by fuel type:")
    for row in fuel_rows
        row.dispatch_mw > 0.01 &&
            @printf "  %-25s : %8.1f MW  (%.0f%% of capacity)\n" row.fuel row.dispatch_mw row.utilization_pct
    end

    congested = filter(r -> r.loading_pct > 90, branch_rows)
    if isempty(congested)
        println("\nNo branches at >90 % of thermal limit.")
    else
        println("\nCongested branches (>90 % loading):")
        @printf "  %-22s  %8s  %8s  %6s\n" "Branch" "Flow" "Limit" "Load%"
        for r in congested[1:min(20, end)]
            @printf "  %-22s  %7.1f MW  %7.1f MW  %5.1f%%\n" r.branch_name abs(r.flow_mw) r.limit_mw r.loading_pct
        end
    end
else
    println("\nSolver did not find an optimal solution.")
    println("  • Check network connectivity (isolated buses with load but no generator)")
    println("  • Try widening angmin/angmax to ±π/2 in data_preparation.jl")
    println("  • Verify TOTAL_LOAD_MW is within installed generation capacity")
end
