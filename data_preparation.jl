# ============================================================
# Spain Power System — Data Preparation
# ============================================================
# Reads the six CSV data files and assembles the PowerModels.jl
# network dict in per-unit on a 100 MVA base.
#
# Usage (from run_opf.jl):
#   include("data_preparation.jl")
#   net = prepare_network()
#   # net.network, net.gens, net.branches, net.loads, net.bus_idx
# ============================================================

using CSV, DataFrames

const BASEMVA       = 100.0
const FREQ_HZ       = 50.0
const TOTAL_LOAD_MW = 35_000.0
const SLACK_BUS_ID  = "ES00029"
const DATA          = joinpath(@__DIR__, "Data")

const COST_MAP = Dict(
    ("Solar",   "PV")             => ("Solar",               "PV"),
    ("Solar",   "CSP")            => ("Solar",               "CSP"),
    ("Wind",    "Onshore")        => ("Wind",                "Onshore"),
    ("Wind",    "Offshore")       => ("Wind",                "Onshore"),
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

function marginal_cost(cost_df::DataFrame, fuel::String, tech::String)::Float64
    key = (fuel, tech)
    if !haskey(COST_MAP, key)
        @warn "No cost mapping for ($fuel, $tech) — defaulting to 60 €/MWh"
        return 60.0
    end
    (carrier, technology) = COST_MAP[key]
    for row in eachrow(cost_df)
        carrier_match = row.carrier == carrier
        tech_match    = technology == "" ||
                        (!ismissing(row.technology) && row.technology == technology)
        carrier_match && tech_match && return Float64(row.variable_total_eur_per_mwh)
    end
    @warn "Cost row not found for carrier=$carrier, tech=$technology — defaulting to 60 €/MWh"
    return 60.0
end

function prepare_network()
    bus_df   = CSV.read(joinpath(DATA, "Bus_Data.csv"),                      DataFrame)
    line_df  = CSV.read(joinpath(DATA, "lines.csv"),                         DataFrame)
    gen_df   = CSV.read(joinpath(DATA, "generations.csv"),                   DataFrame)
    load_df  = CSV.read(joinpath(DATA, "load.csv"),                          DataFrame)
    cost_df  = CSV.read(joinpath(DATA, "generation_cost_pypsa_2024.csv"),    DataFrame)
    xfmr_df  = CSV.read(joinpath(DATA, "transformers_reactance.csv"),        DataFrame)

    bus_idx  = Dict(row.bus_id => i for (i, row) in enumerate(eachrow(bus_df)))
    gen_buses = Set(gen_df.bus_id)

    # ── Buses ────────────────────────────────────────────────
    buses = Dict{String,Any}()
    for row in eachrow(bus_df)
        i  = bus_idx[row.bus_id]
        vn = Float64(row.voltage)
        bus_type = if row.bus_id == SLACK_BUS_ID; 3
                   elseif row.bus_id in gen_buses;  2
                   else;                            1  end
        buses[string(i)] = Dict{String,Any}(
            "index"    => i,  "bus_i"    => i,
            "bus_type" => bus_type,
            "name"     => row.bus_id,
            "base_kv"  => vn,
            "vm"       => 1.0,  "va"   => 0.0,
            "vmax"     => 1.05, "vmin" => 0.95,
            "gs"       => 0.0,  "bs"   => 0.0,
            "zone"     => 1,    "area" => 1,
        )
    end

    # ── Branches: AC lines ───────────────────────────────────
    branches  = Dict{String,Any}()
    br_count  = 0
    for row in eachrow(line_df)
        haskey(bus_idx, row.bus0) || continue
        haskey(bus_idx, row.bus1) || continue
        vn     = Float64(row.voltage)
        L      = Float64(row.length)
        z_base = vn^2 / BASEMVA
        r_pu   = (Float64(row.r_per_length) * L) / z_base
        x_pu   = max((Float64(row.x_per_length) * L) / z_base, 1e-4)
        c_F    = Float64(row.c_per_length) * 1e-9 * L
        b_C_pu = 2π * FREQ_HZ * c_F * vn^2 / BASEMVA
        rate   = sqrt(3) * vn * Float64(row.Imax) / BASEMVA
        br_count += 1
        branches[string(br_count)] = Dict{String,Any}(
            "index"     => br_count,
            "f_bus"     => bus_idx[row.bus0],
            "t_bus"     => bus_idx[row.bus1],
            "name"      => String(row.line_id),
            "br_r"      => r_pu,   "br_x"  => x_pu,
            "g_fr"      => 0.0,    "g_to"  => 0.0,
            "b_fr"      => b_C_pu/2, "b_to" => b_C_pu/2,
            "rate_a"    => rate,   "rate_b" => rate, "rate_c" => rate,
            "tap"       => 1.0,    "shift"  => 0.0,
            "br_status" => 1,
            "angmin"    => -π/3,   "angmax" => π/3,
        )
    end

    # ── Branches: transformers ───────────────────────────────
    for row in eachrow(xfmr_df)
        haskey(bus_idx, row.bus0) || continue
        haskey(bus_idx, row.bus1) || continue
        imva   = Float64(row.installed_MVA)
        x_pu   = max(Float64(row.X_pu_on_installed_base) * (BASEMVA / imva), 1e-4)
        rate   = imva / BASEMVA
        br_count += 1
        branches[string(br_count)] = Dict{String,Any}(
            "index"     => br_count,
            "f_bus"     => bus_idx[row.bus0],
            "t_bus"     => bus_idx[row.bus1],
            "name"      => String(row.transformer_id),
            "br_r"      => 0.0,    "br_x"  => x_pu,
            "g_fr"      => 0.0,    "g_to"  => 0.0,
            "b_fr"      => 0.0,    "b_to"  => 0.0,
            "rate_a"    => rate,   "rate_b" => rate, "rate_c" => rate,
            "tap"       => 1.0,    "shift"  => 0.0,
            "br_status" => 1,
            "angmin"    => -π/3,   "angmax" => π/3,
        )
    end

    # ── Generators ───────────────────────────────────────────
    gens      = Dict{String,Any}()
    gen_count = 0
    for row in eachrow(gen_df)
        haskey(bus_idx, row.bus_id) || continue
        pmax_pu  = Float64(row.capacity_mw) / BASEMVA
        c1       = marginal_cost(cost_df, String(row.primary_fuel), String(row.technology)) * BASEMVA
        gen_count += 1
        gens[string(gen_count)] = Dict{String,Any}(
            "index"      => gen_count,
            "gen_bus"    => bus_idx[row.bus_id],
            "name"       => String(row.unit_id),
            "fuel"       => String(row.primary_fuel),
            "technology" => String(row.technology),
            "pmax"       => pmax_pu,   "pmin" => 0.0,
            "qmax"       =>  pmax_pu,  "qmin" => -pmax_pu,
            "pg"         => pmax_pu/2, "qg"   => 0.0,
            "vg"         => 1.0,
            "mbase"      => BASEMVA,
            "gen_status" => 1,
            "model"      => 2,  "ncost" => 2,
            "cost"       => [c1, 0.0],
            "startup"    => 0.0,  "shutdown" => 0.0,
        )
    end

    # Slack generator (balancing unit, very high cost)
    gen_count += 1
    gens[string(gen_count)] = Dict{String,Any}(
        "index"      => gen_count,
        "gen_bus"    => bus_idx[SLACK_BUS_ID],
        "name"       => "SLACK",
        "fuel"       => "Slack",
        "technology" => "Slack",
        "pmax"       =>  9999.0,  "pmin" => -9999.0,
        "qmax"       =>  9999.0,  "qmin" => -9999.0,
        "pg"         => 0.0,      "qg"   => 0.0,
        "vg"         => 1.0,
        "mbase"      => BASEMVA,
        "gen_status" => 1,
        "model"      => 2,  "ncost" => 2,
        "cost"       => [1_000.0 * BASEMVA, 0.0],
        "startup"    => 0.0,  "shutdown" => 0.0,
    )

    # ── Loads ────────────────────────────────────────────────
    demand_sum  = sum(skipmissing(load_df.demand))
    const_qd    = tan(acos(0.95))
    loads       = Dict{String,Any}()
    load_count  = 0
    for row in eachrow(load_df)
        haskey(bus_idx, row.bus_id) || continue
        row.demand == 0.0 && continue
        pd_pu = Float64(row.demand) / demand_sum * TOTAL_LOAD_MW / BASEMVA
        load_count += 1
        loads[string(load_count)] = Dict{String,Any}(
            "index"    => load_count,
            "load_bus" => bus_idx[row.bus_id],
            "name"     => String(row.bus_id) * "_load",
            "pd"       => pd_pu,
            "qd"       => pd_pu * const_qd,
            "status"   => 1,
        )
    end

    # ── Assemble PowerModels dict ────────────────────────────
    network = Dict{String,Any}(
        "name"     => "Spain_Power_System",
        "baseMVA"  => BASEMVA,
        "per_unit" => true,
        "bus"      => buses,
        "branch"   => branches,
        "gen"      => gens,
        "load"     => loads,
        "dcline"   => Dict{String,Any}(),
        "shunt"    => Dict{String,Any}(),
        "storage"  => Dict{String,Any}(),
        "switch"   => Dict{String,Any}(),
    )

    return (
        network  = network,
        bus_idx  = bus_idx,
        bus_df   = bus_df,
        gen_df   = gen_df,
        gens     = gens,
        branches = branches,
        loads    = loads,
    )
end
