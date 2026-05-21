# ============================================================
# Spain Power System — DC OPF with PowerModels.jl
# ============================================================
#
# This script:
#   1. Reads the six CSV data files
#   2. Converts everything to per-unit in the PowerModels Dict format
#   3. Runs a DC OPF with the HiGHS solver
#   4. Prints dispatch, cost, and congestion results
#
# To run:
#   julia opf_spain.jl
#
# To switch to AC OPF later, see the comment at the bottom of the file.
# ============================================================

# ── 0. Install / load packages ───────────────────────────────
import Pkg
Pkg.add(["CSV", "DataFrames", "PowerModels", "HiGHS", "Printf"])

using CSV, DataFrames, PowerModels, HiGHS, Printf

# ── 1. Global parameters ─────────────────────────────────────
const BASEMVA        = 100.0    # MVA system base for per-unit conversion
const FREQ_HZ        = 50.0     # grid frequency (Spain)
const TOTAL_LOAD_MW  = 35_000.0 # approximate Spain peak demand [MW] — adjust as needed
const SLACK_BUS_ID   = "ES00029" # reference bus: 400 kV, Madrid area (well-connected)

const DATA = joinpath(@__DIR__, "Data")

# ── 2. Read CSVs ─────────────────────────────────────────────
bus_df   = CSV.read(joinpath(DATA, "Bus_Data.csv"),            DataFrame)
line_df  = CSV.read(joinpath(DATA, "lines.csv"),               DataFrame)
gen_df   = CSV.read(joinpath(DATA, "generations.csv"),         DataFrame)
load_df  = CSV.read(joinpath(DATA, "load.csv"),                DataFrame)
cost_df  = CSV.read(joinpath(DATA, "generation_cost_pypsa_2024.csv"), DataFrame)
xfmr_df  = CSV.read(joinpath(DATA, "transformers_reactance.csv"),     DataFrame)

# ── 3. Bus index map: "ES00001" → integer 1, 2, … ───────────
bus_idx = Dict(row.bus_id => i for (i, row) in enumerate(eachrow(bus_df)))

# ── 4. Generation cost lookup ────────────────────────────────
# Maps (primary_fuel, technology) from generations.csv
# to the matching row in generation_cost_pypsa_2024.csv.
const COST_MAP = Dict(
    ("Solar",   "PV")             => ("Solar",               "PV"),
    ("Solar",   "CSP")            => ("Solar",               "CSP"),
    ("Wind",    "Onshore")        => ("Wind",                "Onshore"),
    ("Wind",    "Offshore")       => ("Wind",                "Onshore"),   # approximate
    ("Nuclear", "Nuclear")        => ("Nuclear",             ""),
    ("Gas",     "Combined_cycle") => ("Gas",                 "CCGT"),
    ("Gas",     "Gas_turbine")    => ("Gas",                 "OCGT"),
    ("Coal",    "Coal")           => ("Coal",                "Hard Coal"),
    ("Biomass", "Biomass")        => ("Biomass",             ""),
    ("Hydro",   "pumped_storage") => ("Electricity Storage", "Pumped Storage"),
    ("Hydro",   "Run_of_River")   => ("Hydro",               "Run of River"),
    ("Hydro",   "Reservoir")      => ("Hydro",               "Reservoir"),
    ("Oil",     "Combined_cycle") => ("Oil",                 "Internal Combustion"),
    ("Oil",     "Gas_turbine")    => ("Oil",                 "Internal Combustion"),
)

function marginal_cost(fuel::String, tech::String)::Float64
    key = (fuel, tech)
    if !haskey(COST_MAP, key)
        @warn "No cost mapping for ($fuel, $tech) — defaulting to 60 €/MWh"
        return 60.0
    end
    (carrier, technology) = COST_MAP[key]
    for row in eachrow(cost_df)
        carrier_match = row.carrier == carrier
        # technology column may be missing (e.g., Nuclear, Biomass)
        tech_match = technology == "" ||
                     (!ismissing(row.technology) && row.technology == technology)
        carrier_match && tech_match && return Float64(row.variable_total_eur_per_mwh)
    end
    @warn "Cost row not found for carrier=$carrier, tech=$technology — defaulting to 60 €/MWh"
    return 60.0
end

# ── 5. Buses ─────────────────────────────────────────────────
gen_buses = Set(gen_df.bus_id)   # buses that have at least one generator

buses = Dict{String,Any}()
for row in eachrow(bus_df)
    i  = bus_idx[row.bus_id]
    vn = Float64(row.voltage)    # nominal voltage [kV]

    bus_type = if row.bus_id == SLACK_BUS_ID
        3   # reference / slack bus
    elseif row.bus_id in gen_buses
        2   # PV bus (has a dispatchable unit)
    else
        1   # PQ bus (load only)
    end

    buses[string(i)] = Dict{String,Any}(
        "index"    => i,
        "bus_i"    => i,
        "bus_type" => bus_type,
        "name"     => row.bus_id,
        "base_kv"  => vn,
        "vm"       => 1.0,    # initial voltage magnitude [pu]
        "va"       => 0.0,    # initial voltage angle [rad]
        "vmax"     => 1.05,
        "vmin"     => 0.95,
        "gs"       => 0.0,    # shunt conductance [pu]
        "bs"       => 0.0,    # shunt susceptance [pu]
        "zone"     => 1,
        "area"     => 1,
    )
end

# ── 6. Branches from AC (and HVDC) lines ─────────────────────
#
# Per-unit conversion for a branch at nominal voltage V_kV:
#   Z_base [Ω] = V_kV² / BASEMVA
#   r_pu   = r_total_ohm / Z_base
#   x_pu   = x_total_ohm / Z_base
#
# Charging susceptance (needed for AC OPF, ignored in DC OPF):
#   B_total [S] = 2π·f · (c_per_length·1e-9) · length
#   Y_base  [S] = BASEMVA / V_kV²          (in consistent kV/MVA units × 1e3 factor cancels)
#   b_pu        = B_total · V_kV² / BASEMVA
#
# Thermal limit:
#   S_max [MVA] = √3 · V_kV · I_max_kA
#   rate_a [pu] = S_max / BASEMVA

branches = Dict{String,Any}()
br_count = 0

for row in eachrow(line_df)
    haskey(bus_idx, row.bus0) || continue
    haskey(bus_idx, row.bus1) || continue

    vn  = Float64(row.voltage)          # kV
    L   = Float64(row.length)           # km
    z_base = vn^2 / BASEMVA             # Ω (base impedance at this voltage level)

    r_pu = (Float64(row.r_per_length) * L) / z_base
    x_pu = (Float64(row.x_per_length) * L) / z_base
    x_pu = max(x_pu, 1e-4)             # enforce numerical minimum reactance

    # Charging susceptance (half at each end, per π-model convention)
    c_total_F = Float64(row.c_per_length) * 1e-9 * L
    b_C_pu    = 2π * FREQ_HZ * c_total_F * vn^2 / BASEMVA

    # Thermal limit
    i_max_kA  = Float64(row.Imax)
    rate_a_pu = sqrt(3) * vn * i_max_kA / BASEMVA

    global br_count += 1
    branches[string(br_count)] = Dict{String,Any}(
        "index"     => br_count,
        "f_bus"     => bus_idx[row.bus0],
        "t_bus"     => bus_idx[row.bus1],
        "name"      => String(row.line_id),
        "br_r"      => r_pu,
        "br_x"      => x_pu,
        "g_fr"      => 0.0,
        "g_to"      => 0.0,
        "b_fr"      => b_C_pu / 2,
        "b_to"      => b_C_pu / 2,
        "rate_a"    => rate_a_pu,
        "rate_b"    => rate_a_pu,
        "rate_c"    => rate_a_pu,
        "tap"       => 1.0,
        "shift"     => 0.0,
        "br_status" => 1,
        "angmin"    => -π/3,   # ±60° angle difference limit
        "angmax"    =>  π/3,
    )
end

# ── 7. Branches from transformers ────────────────────────────
#
# Reactance conversion from installed MVA base to 100 MVA system base:
#   X_pu_sys = X_pu_installed × (BASEMVA / installed_MVA)
#   (larger transformer → smaller per-unit reactance on system base)
#
# Resistance is neglected (standard for HV transformers in OPF).
# Tap ratio = 1.0 because each bus uses its own nominal kV as base voltage,
# so the transformer ratio is implicit in the bus base_kv values.

for row in eachrow(xfmr_df)
    haskey(bus_idx, row.bus0) || continue
    haskey(bus_idx, row.bus1) || continue

    installed_mva = Float64(row.installed_MVA)
    x_pu      = Float64(row.X_pu_on_installed_base) * (BASEMVA / installed_mva)
    x_pu      = max(x_pu, 1e-4)
    rate_a_pu = installed_mva / BASEMVA

    global br_count += 1
    branches[string(br_count)] = Dict{String,Any}(
        "index"     => br_count,
        "f_bus"     => bus_idx[row.bus0],
        "t_bus"     => bus_idx[row.bus1],
        "name"      => String(row.transformer_id),
        "br_r"      => 0.0,
        "br_x"      => x_pu,
        "g_fr"      => 0.0,
        "g_to"      => 0.0,
        "b_fr"      => 0.0,
        "b_to"      => 0.0,
        "rate_a"    => rate_a_pu,
        "rate_b"    => rate_a_pu,
        "rate_c"    => rate_a_pu,
        "tap"       => 1.0,
        "shift"     => 0.0,
        "br_status" => 1,
        "angmin"    => -π/3,
        "angmax"    =>  π/3,
    )
end

# ── 8. Generators ─────────────────────────────────────────────
#
# Cost model: linear (model=2, ncost=2)
#   total_cost [€/h] = c1 × pg_pu + c0
#   c1 = marginal_cost [€/MWh] × BASEMVA [MW/pu]
#   c0 = 0 (no fixed cost in this model)
#
# Reactive limits (needed for AC OPF, ignored in DC OPF):
#   qmax =  pmax  (rough approximation; refine for AC OPF)
#   qmin = -pmax

gens = Dict{String,Any}()
gen_count = 0

for row in eachrow(gen_df)
    haskey(bus_idx, row.bus_id) || continue

    pmax_pu  = Float64(row.capacity_mw) / BASEMVA
    cost_mwh = marginal_cost(String(row.primary_fuel), String(row.technology))
    c1       = cost_mwh * BASEMVA     # €/h per pu

    global gen_count += 1
    gens[string(gen_count)] = Dict{String,Any}(
        "index"      => gen_count,
        "gen_bus"    => bus_idx[row.bus_id],
        "name"       => String(row.unit_id),
        "fuel"       => String(row.primary_fuel),
        "pmax"       => pmax_pu,
        "pmin"       => 0.0,
        "qmax"       =>  pmax_pu,
        "qmin"       => -pmax_pu,
        "pg"         => pmax_pu / 2,  # initial guess: 50% dispatch
        "qg"         => 0.0,
        "vg"         => 1.0,
        "mbase"      => BASEMVA,
        "gen_status" => 1,
        "model"      => 2,            # polynomial cost
        "ncost"      => 2,
        "cost"       => [c1, 0.0],   # [c1, c0]
        "startup"    => 0.0,
        "shutdown"   => 0.0,
    )
end

# Add a cheap slack generator at the reference bus so DC OPF always has
# a source to balance load (it will have zero dispatch if the network is
# otherwise balanced; if it dispatches significantly, TOTAL_LOAD_MW is wrong).
slack_bus_i = bus_idx[SLACK_BUS_ID]
global gen_count += 1
gens[string(gen_count)] = Dict{String,Any}(
    "index"      => gen_count,
    "gen_bus"    => slack_bus_i,
    "name"       => "SLACK",
    "fuel"       => "Slack",
    "pmax"       =>  9999.0,   # very large capacity
    "pmin"       => -9999.0,
    "qmax"       =>  9999.0,
    "qmin"       => -9999.0,
    "pg"         => 0.0,
    "qg"         => 0.0,
    "vg"         => 1.0,
    "mbase"      => BASEMVA,
    "gen_status" => 1,
    "model"      => 2,
    "ncost"      => 2,
    "cost"       => [1_000.0 * BASEMVA, 0.0],  # very expensive → dispatches only as last resort
    "startup"    => 0.0,
    "shutdown"   => 0.0,
)

# ── 9. Loads ─────────────────────────────────────────────────
#
# The "demand" column in load.csv holds each bus's share of total Spanish demand.
# We normalise these shares and scale by TOTAL_LOAD_MW.
#
# Reactive load: at power factor 0.95 lagging, q/p = tan(acos(0.95)) ≈ 0.3287
# This is only relevant for AC OPF; DC OPF ignores qd.

demand_sum = sum(skipmissing(load_df.demand))
@info "Sum of demand fractions = $(round(demand_sum; digits=4)) " *
      "(expected ≈ 1.0 for normalised shares)"

const QD_RATIO = tan(acos(0.95))  # reactive/active ratio at PF = 0.95

loads = Dict{String,Any}()
load_count = 0

for row in eachrow(load_df)
    haskey(bus_idx, row.bus_id) || continue
    row.demand == 0.0               && continue   # skip zero-load buses

    pd_mw = Float64(row.demand) / demand_sum * TOTAL_LOAD_MW
    pd_pu = pd_mw / BASEMVA

    global load_count += 1
    loads[string(load_count)] = Dict{String,Any}(
        "index"    => load_count,
        "load_bus" => bus_idx[row.bus_id],
        "name"     => String(row.bus_id) * "_load",
        "pd"       => pd_pu,
        "qd"       => pd_pu * QD_RATIO,
        "status"   => 1,
    )
end

# ── 10. Assemble the PowerModels network dict ─────────────────
network = Dict{String,Any}(
    "name"     => "Spain_Power_System",
    "baseMVA"  => BASEMVA,
    "per_unit" => true,
    "bus"     => buses,
    "branch"  => branches,
    "gen"     => gens,
    "load"    => loads,
    "dcline"  => Dict{String,Any}(),
    "shunt"   => Dict{String,Any}(),
    "storage" => Dict{String,Any}(),
    "switch"  => Dict{String,Any}(),
)

# Quick sanity check on the data before solving
println("\nNetwork summary:")
@printf "  Buses      : %d\n" length(network["bus"])
@printf "  Branches   : %d\n" length(network["branch"])
@printf "  Generators : %d\n" length(network["gen"])
@printf "  Loads      : %d\n" length(network["load"])
@printf "  Total load : %.1f MW\n" sum(v["pd"] for v in values(loads)) * BASEMVA
@printf "  Total gen capacity: %.1f MW\n" sum(v["pmax"] for v in values(gens)) * BASEMVA

# ── 11. Run DC OPF ───────────────────────────────────────────
PowerModels.silence()   # suppress internal solver logs

println("\nRunning DC OPF …")
result = solve_dc_opf(network, HiGHS.Optimizer)
# If you are on an older PowerModels version (<0.20), use:
#   result = run_dc_opf(network, HiGHS.Optimizer)

# ── 12. Print results ────────────────────────────────────────
status = result["termination_status"]
println("\n" * "="^60)
@printf "DC OPF status : %s\n" status
if haskey(result, "objective")
    @printf "Total cost    : %.2f €/h\n" result["objective"]
end
println("="^60)

if string(status) == "OPTIMAL" || string(status) == "LOCALLY_SOLVED"

    sol_gen    = result["solution"]["gen"]
    sol_branch = result["solution"]["branch"]

    # ── Total generation vs. load ──────────────────────────
    total_gen_mw  = sum(v["pg"] * BASEMVA for v in values(sol_gen))
    total_load_mw = sum(v["pd"] * BASEMVA for v in values(loads))
    @printf "\nTotal generation : %8.1f MW\n" total_gen_mw
    @printf "Total load       : %8.1f MW\n"  total_load_mw
    @printf "Mismatch         : %8.2f MW\n"  total_gen_mw - total_load_mw

    # ── Top 15 dispatched generators ─────────────────────
    println("\nTop 15 dispatched generators:")
    @printf "  %-12s  %-30s  %8s  %8s  %s\n" "Unit" "Name" "Dispatch" "Capacity" "Fuel"
    println("  " * "-"^75)

    gen_disp = [(k, v["pg"] * BASEMVA) for (k, v) in sol_gen if v["pg"] > 0.05]
    sort!(gen_disp; by = x -> -x[2])
    for (k, pg_mw) in gen_disp[1:min(15, end)]
        g    = gens[k]
        util = 100 * pg_mw / (g["pmax"] * BASEMVA)
        @printf "  %-12s  %-30s  %7.1f MW  %7.1f MW  %s (%.0f%%)\n" g["name"] "" pg_mw (g["pmax"]*BASEMVA) g["fuel"] util
    end

    # ── Dispatch by fuel type ─────────────────────────────
    fuel_dispatch = Dict{String,Float64}()
    for (k, v) in sol_gen
        fuel = gens[k]["fuel"]
        fuel_dispatch[fuel] = get(fuel_dispatch, fuel, 0.0) + v["pg"] * BASEMVA
    end
    println("\nDispatch by fuel type:")
    for (fuel, mw) in sort(collect(fuel_dispatch); by = x -> -x[2])
        mw > 0.01 && @printf "  %-25s : %8.1f MW\n" fuel mw
    end

    # ── Congested branches (>90 % of thermal limit) ───────
    congested = Tuple{String,Float64,Float64}[]
    for (k, v) in sol_branch
        pf_mw  = abs(v["pf"]) * BASEMVA
        rate   = branches[k]["rate_a"] * BASEMVA
        pf_mw > 0.9 * rate && push!(congested, (branches[k]["name"], pf_mw, rate))
    end

    if isempty(congested)
        println("\nNo branches at >90 % of thermal limit.")
    else
        println("\nCongested branches (>90% loading):")
        sort!(congested; by = x -> -(x[2] / x[3]))
        @printf "  %-22s  %8s  %8s  %6s\n" "Branch" "Flow" "Limit" "Load%"
        for (name, pf, rate) in congested[1:min(20, end)]
            @printf "  %-22s  %7.1f MW  %7.1f MW  %5.1f%%\n" name pf rate 100*pf/rate
        end
    end

else
    println("\nSolver did not find an optimal solution.")
    println("Possible causes:")
    println("  • Islanded buses with load but no generator — check connectivity")
    println("  • Angle limits too tight — try widening angmin/angmax to ±π/2")
    println("  • TOTAL_LOAD_MW too large relative to installed generation capacity")
    println("\nDiagnosis: run PowerModels.check_network_data(network) for warnings.")
end

# ── HOW TO SWITCH TO AC OPF ──────────────────────────────────
#
# 1. Install Ipopt:
#      import Pkg; Pkg.add("Ipopt")
#      using Ipopt
#
# 2. Replace the solve call:
#      result = solve_ac_opf(network, Ipopt.Optimizer)
#
# 3. The solution will then include voltage magnitudes ("vm") at each bus,
#    reactive power flows ("qf", "qt"), and generator reactive dispatch ("qg").
#
# 4. For AC OPF you may also want to:
#    • Add shunt capacitors/reactors (network["shunt"])
#    • Set tighter voltage bounds per voltage level (e.g., 0.95–1.05 pu)
#    • Provide better generator reactive capability curves (qmax/qmin)
