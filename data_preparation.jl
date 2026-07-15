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

const LOAD_SHED_COST_EUR_MWH = 10_000.0   # Value of Lost Load — shed only as absolute last resort

# ── Shunt reactors (EHV line-charging compensation) ──────────────────────────
# Installed peninsular shunt-reactor fleet, REE Boletín Mensual diciembre 2024:
#   https://www.ree.es/es/datos/publicaciones/boletines-mensuales/boletin-mensual-diciembre-2024
#   • 400 kV : 11 750 MVAr (80 units)
#   • ≤220 kV:  3 722 MVAr (55 units)
# The Balearic/Canary systems are non-synchronous and excluded (peninsular only).
# The fleet is disaggregated across buses in proportion to the AC line charging
# connected at each bus and cached in Data/reactors.csv (see add_reactor_shunts!).
const REACTOR_MVAR_400KV      = 11_750.0
const REACTOR_MVAR_LE220KV    =  3_722.0
const REACTOR_HV_THRESHOLD_KV = 380.0      # base_kv ≥ ⇒ "400 kV" group, else "≤220 kV"
const REACTOR_FILE            = joinpath(DATA, "reactors.csv")

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

# Disaggregate the installed shunt-reactor fleet across buses (∝ connected AC
# line charging) and attach it to the network as `shunt` components.  A reactor
# absorbs reactive power, so its susceptance is negative (bs < 0).
#
# The per-bus *installed* capacity (the full 100 % fleet) is cached in
# Data/reactors.csv so it can be reused as a model input on later runs; delete
# that file to regenerate the disaggregation (e.g. after changing the line
# data).  `in_service_pct` then scales how much of the installed fleet is
# energised at the operating point — set it in config.toml ([reactors]).
function add_reactor_shunts!(network, buses, branches, bus_idx;
                             enabled::Bool, in_service_pct::Float64)
    enabled || return
    BASE      = network["baseMVA"]
    installed = Dict{Int,Float64}()        # bus index ⇒ installed reactor [MVAr]

    if isfile(REACTOR_FILE)
        rdf = CSV.read(REACTOR_FILE, DataFrame)
        for row in eachrow(rdf)
            haskey(bus_idx, row.bus_id) || continue
            installed[bus_idx[row.bus_id]] = Float64(row.reactor_installed_mvar)
        end
    else
        # Connected line charging at each bus = Σ half-charging of the incident
        # AC lines (b_fr at the from-bus, b_to at the to-bus), as MVAr at 1.0 pu.
        # Transformers (b_fr = b_to = 0) and HVDC links contribute nothing.
        charging = Dict{Int,Float64}()
        for (_, br) in branches
            charging[br["f_bus"]] = get(charging, br["f_bus"], 0.0) + get(br, "b_fr", 0.0) * BASE
            charging[br["t_bus"]] = get(charging, br["t_bus"], 0.0) + get(br, "b_to", 0.0) * BASE
        end
        group(bi) = buses[string(bi)]["base_kv"] >= REACTOR_HV_THRESHOLD_KV ? "400kV" : "<=220kV"
        fleet = Dict("400kV" => REACTOR_MVAR_400KV, "<=220kV" => REACTOR_MVAR_LE220KV)
        ctot  = Dict("400kV" => 0.0,                "<=220kV" => 0.0)
        for (bi, c) in charging
            ctot[group(bi)] += c
        end
        rows = NamedTuple[]
        for (bi, c) in charging
            g = group(bi)
            ctot[g] > 0 || continue
            q = fleet[g] * c / ctot[g]     # ∝ share of group charging
            installed[bi] = q
            push!(rows, (bus_id                  = buses[string(bi)]["name"],
                         base_kv                 = buses[string(bi)]["base_kv"],
                         voltage_group           = g,
                         connected_charging_mvar = round(c; digits = 3),
                         reactor_installed_mvar  = round(q; digits = 3)))
        end
        sort!(rows; by = r -> -r.reactor_installed_mvar)
        CSV.write(REACTOR_FILE, DataFrame(rows))
        @info "Wrote shunt-reactor disaggregation to $REACTOR_FILE ($(length(rows)) buses)"
    end

    scale = in_service_pct / 100.0
    n = length(network["shunt"])        # append after any existing shunts
    for (bi, q_inst) in installed
        q = q_inst * scale
        q > 1e-9 || continue
        n += 1
        network["shunt"][string(n)] = Dict{String,Any}(
            "index"     => n,
            "shunt_bus" => bi,
            "gs"        => 0.0,
            "bs"        => -q / BASE,       # negative ⇒ inductive (absorbs reactive power)
            "status"    => 1,
        )
    end
    return
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
                         crossborder_inj::Union{Dict{String,Float64},Nothing} = nothing,
                         da_dispatch::Union{Dict{String,Float64},Nothing} = nothing,
                         nuclear_da_dispatch::Union{Dict{String,Float64},Nothing} = nothing,
                         nuclear_min_frac::Float64   = 0.0,
                         voltage_band::Float64       = 0.05,
                         line_rating_factor::Float64 = 0.70,
                         reactors_enabled::Bool      = true,
                         reactor_in_service_pct::Float64 = 100.0,
                         load_power_factor::Float64      = 1.0,
                         apparent_power_limit::Bool      = true,
                         rated_power_factor::Float64     = 0.90,
                         renewable_power_factor::Float64 = 0.95,
                         gen_bus_voltage_control::Bool   = false,
                         gen_bus_vmin::Float64           = 0.98,
                         gen_bus_vmax::Float64           = 1.03,
                         # [scenario] overrides (EMPIRE future system; see
                         # empire_scenario.jl — all `nothing` for the 2024 run):
                         #   unit_scale    : (fuel, technology) ⇒ capacity factor the
                         #                   existing unit fleet is scaled by
                         #   cost_override : (fuel, technology) ⇒ EUR/MWh replacing the
                         #                   pypsa-2024 marginal-cost table
                         #   bess_units    : [(bus_id, power_mw, energy_mwh), …] Li-Ion
                         #                   BESS fleet placed on the grid
                         unit_scale::Union{Dict{Tuple{String,String},Float64},Nothing} = nothing,
                         cost_override::Union{Dict{Tuple{String,String},Float64},Nothing} = nothing,
                         bess_units = nothing)
    bus_df   = CSV.read(joinpath(DATA, "Bus_Data.csv"),                      DataFrame)
    line_df  = CSV.read(joinpath(DATA, "lines.csv"),                         DataFrame)
    gen_df   = CSV.read(joinpath(DATA, "generations.csv"),                   DataFrame)
    load_df  = CSV.read(joinpath(DATA, "load.csv"),                          DataFrame)
    cost_df  = CSV.read(joinpath(DATA, "generation_cost_pypsa_2024.csv"),    DataFrame)
    xfmr_df  = CSV.read(joinpath(DATA, "transformers_reactance.csv"),        DataFrame)

    bus_idx  = Dict(row.bus_id => i for (i, row) in enumerate(eachrow(bus_df)))
    gen_buses = Set(gen_df.bus_id)
    # Buses hosting a SYNCHRONOUS machine (strong AVR voltage regulation).  Only
    # these (plus the slack) get the tighter voltage band — renewable-only buses,
    # whose reactive is capped at low output, keep the wider load-bus band.
    synchronous_gen_buses = Set(row.bus_id for row in eachrow(gen_df)
                                if !(row.primary_fuel == "Wind" || row.primary_fuel == "Solar"))

    # Total installed capacity of modelled solar/wind generators (for proportional scaling)
    # Per-unit capacity scale factor from the scenario ((fuel, tech) ⇒ factor)
    uscale(row) = unit_scale === nothing ? 1.0 :
                  get(unit_scale, (String(row.primary_fuel), String(row.technology)), 1.0)
    total_solar_mw = sum(Float64(row.capacity_mw) * uscale(row) for row in eachrow(gen_df)
                         if row.primary_fuel == "Solar" && haskey(bus_idx, row.bus_id);
                         init = 0.0)
    total_wind_mw  = sum(Float64(row.capacity_mw) * uscale(row) for row in eachrow(gen_df)
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
        # AVR-regulated buses (synchronous machine or slack) get the tighter band,
        # so the profile follows realistic setpoints instead of railing to vmax.
        avr_bus = gen_bus_voltage_control &&
                  (bus_type == 3 || row.bus_id in synchronous_gen_buses)
        vmax_b  = avr_bus ? gen_bus_vmax : 1.0 + voltage_band
        vmin_b  = avr_bus ? gen_bus_vmin : 1.0 - voltage_band
        buses[string(i)] = Dict{String,Any}(
            "index"    => i,  "bus_i"    => i,
            "bus_type" => bus_type,
            "name"     => row.bus_id,
            "base_kv"  => vn,
            "vm"       => 1.0,  "va"   => 0.0,
            "vmax"     => vmax_b, "vmin" => vmin_b,
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
        # N identical circuits in parallel: series R,X divide by N; shunt B and
        # thermal rating (√3·V·Imax per circuit) multiply by N.
        # N identical circuits in parallel: series R,X divide by N; shunt B and
        # thermal rating (√3·V·Imax per circuit) multiply by N.
        nc     = max(Float64(row.circuits), 1.0)
        r_pu   = (Float64(row.r_per_length) * L) / z_base / nc
        x_pu   = max((Float64(row.x_per_length) * L) / z_base / nc, 1e-4)
        c_F    = Float64(row.c_per_length) * 1e-9 * L
        b_C_pu = 2π * FREQ_HZ * c_F * vn^2 / BASEMVA * nc
        rate   = sqrt(3) * vn * Float64(row.Imax) / BASEMVA * line_rating_factor * nc
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
        rate   = imva / BASEMVA * line_rating_factor
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
        # Parallel circuits scale the converter power rating (no series R/X here).
        nc   = max(Float64(row.circuits), 1.0)
        rate = sqrt(3) * vn * Float64(row.Imax) / BASEMVA * line_rating_factor * nc
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
        cap_mw = Float64(row.capacity_mw) * uscale(row)
        cap_mw > 1e-6 || continue          # tech fully retired in the scenario
        pmax_pu = if row.primary_fuel == "Solar" && isfinite(solar_avail_mw) && total_solar_mw > 0
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
        elseif cost_override !== nothing &&
               haskey(cost_override, (String(row.primary_fuel), String(row.technology)))
            cost_override[(String(row.primary_fuel), String(row.technology))] * BASEMVA
        else
            marginal_cost(cost_df, String(row.primary_fuel), String(row.technology)) * BASEMVA
        end
        # Reactive capability is sized on installed capacity, independent of any
        # active-power freeze applied below.
        (qmax_pu, qmin_pu) = q_limits(pmax_pu)

        # Reactive capability (enforced in the OPF build via add_gen_capability!):
        #   • Synchronous units (thermal/hydro): MVA capability circle
        #     P² + Q² ≤ S²,  S = installed MVA / rated_power_factor  (nameplate,
        #     not the hourly-derated Pmax); the reactive box is widened to ±S.
        #   • Inverter-based Wind/Solar: a grid-code reactive cap tied to *actual*
        #     output, |Q| ≤ tan(acos(renewable_power_factor))·P  (so a derated
        #     farm cannot park at a very low PF); the box is the value at full
        #     available output.
        # When apparent_power_limit = false, both fall back to the ±Pmax box.
        smax_pu  = Inf      # MVA circle radius [pu]   (synchronous only)
        qp_ratio = Inf      # |Q|/P cap                (renewables only)
        if apparent_power_limit
            if row.primary_fuel == "Wind" || row.primary_fuel == "Solar"
                qp_ratio = tan(acos(renewable_power_factor))
                qmax_pu, qmin_pu = qp_ratio * pmax_pu, -qp_ratio * pmax_pu
            else
                smax_pu = cap_mw > 0 ? (cap_mw / BASEMVA) / rated_power_factor : Inf
                isfinite(smax_pu) && ((qmax_pu, qmin_pu) = (smax_pu, -smax_pu))
            end
        end

        # ── Anchor to the day-ahead schedule (redispatch stage) ──────────────
        # When a DA dispatch is supplied, warm-start every unit from it and
        # *freeze* the units that do not provide redispatch (Nuclear, run-of-
        # river hydro, biomass) at their DA set-point (pmin = pmax = P_DA).  All
        # other units stay free; the anchor objective keeps them near P_DA.
        da_pu = (!isnothing(da_dispatch) && haskey(da_dispatch, String(row.unit_id))) ?
                da_dispatch[String(row.unit_id)] / BASEMVA : nothing
        # Nuclear DA dispatch is carried unchanged into all subsequent market stages.
        # When nuclear_da_dispatch is provided the unit is frozen regardless of da_dispatch.
        nuc_pu = (String(row.primary_fuel) == "Nuclear" &&
                  !isnothing(nuclear_da_dispatch) &&
                  haskey(nuclear_da_dispatch, String(row.unit_id))) ?
                 nuclear_da_dispatch[String(row.unit_id)] / BASEMVA : nothing
        is_frozen = nuc_pu !== nothing ||
                    (da_pu !== nothing && (
                        String(row.primary_fuel) == "Nuclear" ||
                        String(row.primary_fuel) == "Biomass" ||
                        String(row.primary_fuel) == "Coal"    ||
                        (String(row.primary_fuel) == "Hydro" &&
                         lowercase(String(row.technology)) == "run_of_river")))
        frozen_pu = nuc_pu !== nothing ? nuc_pu : da_pu
        # Nuclear must-run floor: when not frozen (the DA clear), hold nuclear at
        # >= nuclear_min_frac·Pmax so baseload can't be shut down at the solar peak.
        nuc_floor = (nuclear_min_frac > 0.0 && String(row.primary_fuel) == "Nuclear") ?
                    nuclear_min_frac * pmax_pu : 0.0
        pmin_g  = is_frozen ? frozen_pu : nuc_floor
        pmax_g  = is_frozen ? frozen_pu : pmax_pu
        pg_strt = frozen_pu !== nothing ? clamp(frozen_pu, 0.0, pmax_pu) :
                  nuc_floor > 0.0       ? pmax_pu : pmax_pu/2

        gen_count += 1
        gens[string(gen_count)] = Dict{String,Any}(
            "index"         => gen_count,
            "gen_bus"       => bus_idx[row.bus_id],
            "name"          => String(row.unit_id),
            "fuel"          => String(row.primary_fuel),
            "technology"    => String(row.technology),
            "installed_mw"  => cap_mw,           # fixed installed capacity
            "pmax"          => pmax_g,   "pmin" => pmin_g,
            "pg0"           => (frozen_pu !== nothing ? frozen_pu :
                               da_pu     !== nothing ? da_pu     : pmax_pu/2),
            "qmax"          => qmax_pu,   "qmin" => qmin_pu,
            "smax"          => smax_pu,    # MVA circle radius [pu] (Inf ⇒ none)
            "qp_ratio"      => qp_ratio,   # |Q|/P cap (Inf ⇒ none, renewables)
            "pg"         => pg_strt,   "qg"   => 0.0,
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
        "vg"         => 1.0,
        "mbase"      => BASEMVA,
        "gen_status" => 1,
        "model"      => 2,  "ncost" => 2,
        "cost"       => [1_000.0 * BASEMVA, 0.0],
        "startup"    => 0.0,  "shutdown" => 0.0,
    )

    # ── Cross-border exchange (fixed market-cleared imports only) ──
    # Only positive net injections (imports into Spain) are modelled as fixed
    # generators.  Negative values (Spanish exports, e.g. to Portugal) are skipped:
    # the SMS++ intraday market clearing (used as the redispatch anchor) cleared
    # Spanish generators against domestic load + FR imports only — it placed the
    # cross-border obligation for PT exports on the Portuguese side of MIBEL.
    # Injecting the PT export as a fixed withdrawal would create a 1–4 GW gap
    # between the OPF's required generation and the anchor's reference schedule,
    # forcing the optimizer to massively deviate from the market dispatch.
    if !isnothing(crossborder_inj)
        for (bus_id, mw) in crossborder_inj
            haskey(bus_idx, bus_id) || continue
            mw > 0 || continue          # skip exports (negative net injections)
            p_pu  = mw / BASEMVA
            gen_count += 1
            gens[string(gen_count)] = Dict{String,Any}(
                "index"        => gen_count,
                "gen_bus"      => bus_idx[bus_id],
                "name"         => "XB_" * bus_id,
                "fuel"         => "CrossBorder",
                "technology"   => "Interconnector",
                "installed_mw" => mw,
                "pmax"       => p_pu,   "pmin" => p_pu,
                "qmax"       => p_pu,   "qmin" => -p_pu,
                "pg"         => p_pu,   "qg"   => 0.0,
                "vg"         => 1.0,
                "mbase"      => BASEMVA,
                "gen_status" => 1,
                "model"      => 2,  "ncost" => 2,
                "cost"       => [0.0, 0.0],
                "startup"    => 0.0,  "shutdown" => 0.0,
            )
        end
    end

    # ── Li-Ion BESS fleet ([scenario] only) ──────────────────
    # Each battery is a generator with pmin = −pmax: positive output discharges,
    # negative charges.  In the copper-plate market stages the daily energy
    # balance / SOC window is enforced in solve_da (da.jl) via the "energy_mwh"
    # field; in the redispatch stage the unit is FROZEN at its cleared market
    # schedule (like nuclear), so the AC OPF cannot re-optimise storage without
    # an energy constraint.
    if bess_units !== nothing
        for b in bess_units
            haskey(bus_idx, b.bus_id) || continue
            p_pu   = b.power_mw / BASEMVA
            name   = "BESS_" * b.bus_id
            da_pu  = (!isnothing(da_dispatch) && haskey(da_dispatch, name)) ?
                     da_dispatch[name] / BASEMVA : nothing
            frozen = da_pu !== nothing
            gen_count += 1
            gens[string(gen_count)] = Dict{String,Any}(
                "index"        => gen_count,
                "gen_bus"      => bus_idx[b.bus_id],
                "name"         => name,
                "fuel"         => "Battery",
                "technology"   => "Li-Ion",
                "installed_mw" => b.power_mw,
                "energy_mwh"   => b.energy_mwh,
                "pmax"         => frozen ? da_pu :  p_pu,
                "pmin"         => frozen ? da_pu : -p_pu,
                "pg"           => frozen ? da_pu : 0.0,
                "qmax"         => p_pu,   "qmin" => -p_pu,
                "qg"           => 0.0,
                "vg"           => 1.0,
                "mbase"        => BASEMVA,
                "gen_status"   => 1,
                "model"        => 2,  "ncost" => 2,
                "cost"         => [0.0, 0.0],
                "startup"      => 0.0,  "shutdown" => 0.0,
            )
        end
    end

    # ── Loads ────────────────────────────────────────────────
    # `load_power_factor` is the NET power factor the transmission grid sees at
    # each load bus (distribution-level PF correction is assumed already applied
    # below the model boundary).  qd = pd · tan(acos(pf)); pf = 1.0 ⇒ active only.
    demand_sum   = sum(skipmissing(load_df.demand))
    const_qd     = tan(acos(load_power_factor))
    loads        = Dict{String,Any}()
    load_count   = 0
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
    end

    # ── Load-shedding generators ──────────────────────────────
    # One curtailable unit per load bus priced at VoLL (10 000 EUR/MWh).
    # pg ∈ [0, pd] reduces net demand at the bus; qg ∈ [−pd, pd] provides
    # matching reactive relief.  Dispatches only when no feasible network
    # solution exists within the thermal/voltage limits.
    for (_, load) in loads
        bus_i  = load["load_bus"]
        pd_pu  = load["pd"]
        gen_count += 1
        gens[string(gen_count)] = Dict{String,Any}(
            "index"        => gen_count,
            "gen_bus"      => bus_i,
            "name"         => "LS_" * buses[string(bus_i)]["name"],
            "fuel"         => "LoadShed",
            "technology"   => "LoadShed",
            "installed_mw" => pd_pu * BASEMVA,
            "pmax"         => pd_pu,   "pmin" => 0.0,
            "qmax"         => pd_pu,   "qmin" => -pd_pu,
            "pg"           => 0.0,     "qg"   => 0.0,
            "vg"           => 1.0,
            "mbase"        => BASEMVA,
            "gen_status"   => 1,
            "model"        => 2,  "ncost" => 2,
            "cost"         => [LOAD_SHED_COST_EUR_MWH * BASEMVA, 0.0],
            "startup"      => 0.0,  "shutdown" => 0.0,
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
        "dcline"   => dclines,
        "shunt"    => Dict{String,Any}(),
        "storage"  => Dict{String,Any}(),
        "switch"   => Dict{String,Any}(),
    )

    # Attach the disaggregated shunt-reactor fleet (absorbs EHV line charging).
    add_reactor_shunts!(network, buses, branches, bus_idx;
                        enabled        = reactors_enabled,
                        in_service_pct = reactor_in_service_pct)

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
