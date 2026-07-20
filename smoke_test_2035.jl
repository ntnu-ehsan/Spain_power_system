# Temporary smoke test for the [scenario] wiring (safe to delete).
import Pkg; Pkg.activate(@__DIR__)
using TOML, Printf

# 1) Parse-check every edited script
for f in ["empire_scenario.jl", "midterm_sddp4.jl", "data_preparation.jl", "da.jl", "run_opf.jl"]
    ex  = Meta.parseall(read(joinpath(@__DIR__, f), String))
    bad = any(a -> a isa Expr && a.head in (:error, :incomplete), ex.args)
    println(rpad(f, 25), bad ? "PARSE ERROR" : "parse ok")
    bad && exit(1)
end

# 2) Exercise the scenario loader with label forced to NECP2035
include(joinpath(@__DIR__, "empire_scenario.jl"))
cfg = TOML.parsefile(joinpath(@__DIR__, "config.toml"))
cfg["scenario"]["label"] = "NECP2035"
@assert empire_active(cfg)
@assert empire_suffix(cfg) == "_NECP2035"
@assert empire_suffixed("results/midterm4_cuts.json", cfg) == "results/midterm4_cuts_NECP2035.json"

emp = load_empire_scenario(cfg)
@printf "\nperiod=%d  co2=%.1f EUR/t\n" emp.period emp.co2_price

println("\nES caps (MW):")
for (t, c) in sort(collect(emp.caps["ES"]); by = x -> -x[2])
    c > 1.0 && @printf "  %-28s %10.0f\n" t c
end

println("\nCosts (EUR/MWh, incl. CO2):")
for (t, c) in sort(collect(emp.costs); by = x -> x[2])
    @printf "  %-28s %8.2f\n" t c
end

println("\nDemand (TWh/yr):")
for z in ("ES", "PT", "FR", "EU")
    @printf "  %-3s %9.1f\n" z emp.demand[z] / 1e6
end
@printf "\nload_scale_es = %.4f\n" emp.load_scale_es

println("\nNTC (MW):")
for (k, v) in emp.ntc
    @printf "  %s→%s  %8.0f\n" k[1] k[2] v
end

println("\nStorage:")
for z in ("ES", "PT", "FR", "EU")
    s = emp.storage[z]
    @printf "  %-3s PHS %7.0f MW / %10.0f MWh   BESS %6.0f MW / %8.0f MWh\n" z s.phs_mw s.phs_mwh s.bess_mw s.bess_mwh
end

println("\nGrowth vs 2024 ES fleet:")
for (t, g) in sort(collect(emp.growth))
    @printf "  %-28s ×%.3f\n" t g
end

us = empire_unit_scale(emp)
println("\nUnit scale factors ((fuel, tech) ⇒ ×):")
for (k, v) in sort(collect(us))
    @printf "  %-34s ×%.3f\n" string(k) v
end

co = empire_cost_override(emp)
println("\nCost overrides ((fuel, tech) ⇒ EUR/MWh):")
for (k, v) in sort(collect(co))
    @printf "  %-34s %8.2f\n" string(k) v
end

bess = empire_bess_units(emp)
println("\nBESS units (bus, MW, MWh):")
tot_p = 0.0; tot_e = 0.0
for b in bess
    @printf "  %-12s %7.1f MW  %8.1f MWh\n" b.bus_id b.power_mw b.energy_mwh
    global tot_p += b.power_mw; global tot_e += b.energy_mwh
end
@printf "  TOTAL        %7.1f MW  %8.1f MWh (EMPIRE: %.1f / %.1f)\n" tot_p tot_e emp.storage["ES"].bess_mw emp.storage["ES"].bess_mwh
@assert isapprox(tot_p, emp.storage["ES"].bess_mw; rtol = 1e-6)
@assert isapprox(tot_e, emp.storage["ES"].bess_mwh; rtol = 1e-6)

# caps_nuts consistency: ES NUTS3 sums should match national caps
for (t, d) in emp.caps_nuts
    nat = get(emp.caps["ES"], t, 0.0)
    s   = sum(values(d))
    isapprox(s, nat; rtol = 1e-6) || @printf "  WARN caps_nuts mismatch %s: nuts=%.1f nat=%.1f\n" t s nat
end

println("\nSMOKE TEST PASSED")
