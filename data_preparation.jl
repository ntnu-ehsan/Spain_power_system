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
    ("Solar",   "Solar Thermal")  => ("Solar",               "CSP"),
    ("Wind",    "Onshore")        => ("Wind",                "Onshore"),
    ("Wind",    "Offshore")       => ("Wind",                "Onshore"),
    ("Nuclear", "Nuclear")        => ("Nuclear",             ""),
    ("Gas",     "Combined_cycle") => ("Gas",                 "CCGT"),
    ("Gas",     "Gas_turbine")    => ("Gas",                 "OCGT"),
    ("Coal",    "Coal")           => ("Coal",                "Hard Coal"),
    ("Biomass", "Biomass")        => ("Biomass",             ""),
    ("Hydro",   "pumped_storage") => ("Electricity Storage", "Pumped Storage"),
    ("Hydro",   "Run_of_River")   => ("Hydro",               "Run of River"),
    ("Hydro",   "run_of_river")   => ("Hydro",               "Run of River"),
    ("Hydro",   "Reservoir")      => ("Hydro",               "Reservoir"),
    ("Hydro",   "reservoir")      => ("Hydro",               "Reservoir"),
    ("Oil",     "Combined_cycle") => ("Oil",                 "Internal Combustion"),
    ("Oil",     "Gas_turbine")    => ("Oil",                 "Internal Combustion"),
)

function q_limits(pmax_pu::Float64)::Tuple{Float64,Float64}
    return (pmax_pu, -pmax_pu)   # ±Pmax: conservative fallback ensuring reactive feasibility
end

# Non-dispatchable / must-run units whose intraday set-point is held fixed
# during redispatch.  Every other technology (gas, coal, oil, reservoir &
# pumped hydro, wind, solar) is free to be redispatched to relieve network
# constraints.  Active power is fixed; reactive capability is left free so the
# units can still provide voltage support.
function is_fixed_redispatch_unit(fuel::String, tech::String)::Bool
    f = lowercase(fuel)
    t = lowercase(tech)
    f == "nuclear"                       && return true
    f == "biomass"                       && return true
    (f == "hydro" && t == "run_of_river") && return true
    return false
end

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

function prepare_network(total_load_mw::Float64 = TOTAL_LOAD_MW,
                         solar_avail_mw::Float64 = Inf,
                         wind_avail_mw::Float64  = Inf;
                         hydro_reservoir_cost::Union{Float64,Nothing} = nothing,
                         intraday_pg::Union{Dict{String,Float64},Nothing} = nothing)
    bus_df   = CSV.read(joinpath(DATA, "Bus_Data.csv"),                      DataFrame)
    line_df  = CSV.read(joinpath(DATA, "lines.csv"),                         DataFrame)
    gen_df   = CSV.read(joinpath(DATA, "generations.csv"),                   DataFrame)
    load_df  = CSV.read(joinpath(DATA, "load.csv"),                          DataFrame)
    cost_df  = CSV.read(joinpath(DATA, "generation_cost_pypsa_2024.csv"),    DataFrame)
    xfmr_df  = CSV.read(joinpath(DATA, "transformers_reactance.csv"),        DataFrame)

    bus_idx  = Dict(row.bus_id => i for (i, row) in enumerate(eachrow(bus_df)))
    gen_buses = Set(gen_df.bus_id)

    # Total installed capacity of modelled solar/wind generators (for proportional scaling)
    total_solar_mw = sum(Float64(row.capacity_mw) for row in eachrow(gen_df)
                         if row.primary_fuel == "Solar" && haskey(bus_idx, row.bus_id);
                         init = 0.0)
    total_wind_mw  = sum(Float64(row.capacity_mw) for row in eachrow(gen_df)
                         if row.primary_fuel == "Wind" && haskey(bus_idx, row.bus_id);
                         init = 0.0)

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
            "vmax"     => 1.10, "vmin" => 0.90,
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
        String(row.dc) == "t"    && continue   # HVDC handled below as a dcline
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

    # ── DC lines (HVDC) ──────────────────────────────────────
    # HVDC links are modelled as PowerModels `dcline` components — a
    # controllable converter pair rather than an AC impedance branch.
    # (Treating them as AC branches caused solver errors, since x≈0.)
    # The active-power transfer is a decision variable bounded by the
    # converter rating; each converter may also exchange reactive power
    # with its terminal bus.  Converters are modelled lossless.
    dclines  = Dict{String,Any}()
    dc_count = 0
    for row in eachrow(line_df)
        String(row.dc) == "t" || continue          # AC lines handled above
        haskey(bus_idx, row.bus0) || continue
        haskey(bus_idx, row.bus1) || continue
        vn   = Float64(row.voltage)
        # Rating from terminal voltage and current limit (same voltage/Imax
        # columns as AC lines), expressed in per-unit on the system base.
        rate = sqrt(3) * vn * Float64(row.Imax) / BASEMVA
        dc_count += 1
        dclines[string(dc_count)] = Dict{String,Any}(
            "index"     => dc_count,
            "f_bus"     => bus_idx[row.bus0],
            "t_bus"     => bus_idx[row.bus1],
            "name"      => String(row.line_id),
            "br_status" => 1,
            # Active-power flow variables (bidirectional, ±rate)
            "pf"    => 0.0,   "pt"    => 0.0,
            "pminf" => -rate, "pmaxf" => rate,
            "pmint" => -rate, "pmaxt" => rate,
            # Reactive-power capability at each converter (±rate)
            "qf"    => 0.0,   "qt"    => 0.0,
            "qminf" => -rate, "qmaxf" => rate,
            "qmint" => -rate, "qmaxt" => rate,
            # Terminal voltage setpoints
            "vf"    => 1.0,   "vt"    => 1.0,
            # Lossless converter model: p_fr + p_to == loss0 + loss1*p_fr
            "loss0" => 0.0,   "loss1" => 0.0,
            # No explicit cost on DC transfer
            "model" => 2, "ncost" => 2, "cost" => [0.0, 0.0],
            "startup" => 0.0, "shutdown" => 0.0,
        )
    end

    # ── Remove buses with no branch connections (isolated buses) ──
    connected_buses = Set{Int}()
    for br in values(branches)
        push!(connected_buses, br["f_bus"])
        push!(connected_buses, br["t_bus"])
    end
    for dc in values(dclines)                       # keep HVDC terminal buses
        push!(connected_buses, dc["f_bus"])
        push!(connected_buses, dc["t_bus"])
    end
    for k in collect(keys(buses))
        buses[k]["index"] ∉ connected_buses && delete!(buses, k)
    end

    # ── Generators ───────────────────────────────────────────
    gens      = Dict{String,Any}()
    gen_count = 0
    for row in eachrow(gen_df)
        haskey(bus_idx, row.bus_id) || continue
        cap_mw = Float64(row.capacity_mw)
        # Capacity- (or availability-) based active limit, used both as the
        # dispatchable upper bound and as the basis for reactive capability.
        pmax_cap_pu = if row.primary_fuel == "Solar" && isfinite(solar_avail_mw) && total_solar_mw > 0
            min(cap_mw, solar_avail_mw * cap_mw / total_solar_mw) / BASEMVA
        elseif row.primary_fuel == "Wind" && isfinite(wind_avail_mw) && total_wind_mw > 0
            min(cap_mw, wind_avail_mw * cap_mw / total_wind_mw) / BASEMVA
        else
            cap_mw / BASEMVA
        end
        is_reservoir = String(row.primary_fuel) == "Hydro" &&
                       lowercase(String(row.technology)) == "reservoir"
        c1 = if is_reservoir && !isnothing(hydro_reservoir_cost)
            hydro_reservoir_cost * BASEMVA
        else
            marginal_cost(cost_df, String(row.primary_fuel), String(row.technology)) * BASEMVA
        end
        # Reactive capability scales with rated MVA, so derive it from the
        # capacity-based limit before any active-power fixing below.
        (qmax_pu, qmin_pu) = q_limits(pmax_cap_pu)

        # ── Intraday set-point (redispatch initial operating point) ──
        # Default: free dispatch on [0, pmax_cap], warm-started at half capacity.
        pmin_pu  = 0.0
        pmax_pu  = pmax_cap_pu
        pg_start = pmax_cap_pu / 2
        if !isnothing(intraday_pg) && haskey(intraday_pg, String(row.unit_id))
            v_pu = intraday_pg[String(row.unit_id)] / BASEMVA
            if is_fixed_redispatch_unit(String(row.primary_fuel), String(row.technology))
                # Non-dispatchable: hold exactly at the intraday set-point.
                pmin_pu  = max(v_pu, 0.0)
                pmax_pu  = max(v_pu, 0.0)
                pg_start = max(v_pu, 0.0)
            else
                # Dispatchable: warm-start from intraday, keep bounds [0, pmax_cap].
                pg_start = clamp(v_pu, 0.0, pmax_cap_pu)
            end
        end

        gen_count += 1
        gens[string(gen_count)] = Dict{String,Any}(
            "index"         => gen_count,
            "gen_bus"       => bus_idx[row.bus_id],
            "name"          => String(row.unit_id),
            "fuel"          => String(row.primary_fuel),
            "technology"    => String(row.technology),
            "installed_mw"  => cap_mw,           # fixed installed capacity
            "pmax"          => pmax_pu,   "pmin" => pmin_pu,
            "qmax"          => qmax_pu,   "qmin" => qmin_pu,
            "pg"         => pg_start,  "qg"   => 0.0,
            "pg0"        => pg_start,  # intraday reference set-point [pu] for redispatch
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
        "index"        => gen_count,
        "gen_bus"      => bus_idx[SLACK_BUS_ID],
        "name"         => "SLACK",
        "fuel"         => "Slack",
        "technology"   => "Slack",
        "installed_mw" => 9999.0 * BASEMVA,
        "pmax"         =>  9999.0,  "pmin" => 0.0,
        "qmax"       =>  9999.0,  "qmin" => -9999.0,
        "pg"         => 0.0,      "qg"   => 0.0,
        "pg0"        => 0.0,      # no intraday set-point; any slack use is "redispatch"
        "vg"         => 1.0,
        "mbase"      => BASEMVA,
        "gen_status" => 1,
        "model"      => 2,  "ncost" => 2,
        "cost"       => [1_000.0 * BASEMVA, 0.0],
        "startup"    => 0.0,  "shutdown" => 0.0,
    )

    # ── Loads ────────────────────────────────────────────────
    demand_sum  = sum(skipmissing(load_df.demand))
    const_qd    = tan(acos(0.95))   # Q/P ratio at PF 0.95 — provides reactive sink for line charging
    loads       = Dict{String,Any}()
    load_count  = 0
    for row in eachrow(load_df)
        haskey(bus_idx, row.bus_id) || continue
        row.demand == 0.0 && continue
        pd_pu = Float64(row.demand) / demand_sum * total_load_mw / BASEMVA
        qd_pu = pd_pu * const_qd
        load_count += 1
        bus_i = bus_idx[row.bus_id]
        loads[string(load_count)] = Dict{String,Any}(
            "index"    => load_count,
            "load_bus" => bus_i,
            "name"     => String(row.bus_id) * "_load",
            "pd"       => pd_pu,
            "qd"       => qd_pu,
            "status"   => 1,
        )
        # Local shunt capacitor compensates reactive demand so lines carry
        # only active power — models distributed reactive compensation
        buses[string(bus_i)]["bs"] += qd_pu
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
        "dcline"   => dclines,
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
        dclines  = dclines,
        loads    = loads,
    )
end
