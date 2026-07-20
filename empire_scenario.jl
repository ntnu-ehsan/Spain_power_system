# ============================================================
# EMPIRE scenario loader — future-year system data (e.g. 2035)
# ============================================================
# Reads the outputs (and the cost-relevant inputs) of an EMPIRE
# investment run and assembles the zone/tech tables that the
# midterm SDDP (midterm_sddp4.jl) and the market chain
# (run_opf.jl / data_preparation.jl) consume when a scenario
# other than "2024" is selected in config.toml → [scenario].
#
# Sources inside cfg["scenario"]["empire_dir"]:
#   Output/genInstalledCap.tab          Node × Generator × Period → MW
#   Output/marginal_costs.csv           Generator × Period → EUR/MWh (NO CO2:
#                                       EMPIRE ran with an emission cap)
#   Output/transmissionInstalledCap.tab FromNode × ToNode × Period → MW
#   Output/stor{PW,EN}InstalledCap.tab  Node × Storage × Period → MW / MWh
#   Input/Tab/Node_ElectricAnnualDemand.tab   Node × Period → MWh/yr
#   Input/Tab/General_CO2Price.tab            Period → EUR/tCO2
#   Input/Tab/Generator_Efficiency.tab        Generator × Period → η
#   Input/Tab/Generator_CO2Content.tab        Generator → tCO2/GJ_fuel
#                                       (already the *remaining* content for
#                                        CCS units; negative for BioCCS)
#
# Marginal cost with CO2:
#   cost(g) = marginal_costs.csv(g, period) + (3.6/η_g)·content_g·CO2price
# (the CCS capture/transport cost is already inside marginal_costs.csv).
#
# EMPIRE nodes: ES111…ES620 (NUTS3), "France", "Portugal", "EU" — mapped to
# the 4 model zones ES / FR / PT / EU.  EMPIRE generator names are mapped to
# the Generation.csv naming used across the repo ("GasCCGT" → "Gas CCGT",
# "Hydroregulated" → "Hydro regulated", …).
# ============================================================

using CSV, DataFrames

# ── scenario switches ────────────────────────────────────────
empire_label(cfg)  = String(get(get(cfg, "scenario", Dict()), "label", "2024"))
empire_active(cfg) = empire_label(cfg) != "2024"
empire_suffix(cfg) = empire_active(cfg) ? "_" * empire_label(cfg) : ""

# "Data/BellmanValuesOUT_sddp4.csv" → "Data/BellmanValuesOUT_sddp4_<label>.csv"
function empire_suffixed(path::AbstractString, cfg)::String
    sfx = empire_suffix(cfg)
    isempty(sfx) && return String(path)
    base, ext = splitext(path)
    return base * sfx * ext
end

# ── name mappings ────────────────────────────────────────────
# EMPIRE generator name → repo-wide tech name (Generation.csv convention)
const EMPIRE_TECH_NAME = Dict(
    "GasCCGT"               => "Gas CCGT",
    "GasOCGT"               => "Gas OCGT",
    "GasCCS"                => "Gas CCS",
    "CoalCCS"               => "Coal CCS",
    "LigniteCCS"            => "Lignite CCS",
    "BioCCS"                => "Bio CCS",
    "Hydroregulated"        => "Hydro regulated",
    "Hydrorun-of-the-river" => "Hydro run-of-the-river",
    "Windonshore"           => "Wind onshore",
    "Windoffshoregrounded"  => "Wind offshore grounded",
    "Windoffshorefloating"  => "Wind offshore floating",
)   # Bio, Coal, Lignite, Oil, Solar, Waste, Nuclear, Geo, Wave map to themselves
empire_tech(g::AbstractString) = get(EMPIRE_TECH_NAME, String(g), String(g))

# Dispatchable (thermal-like) techs in the midterm SDDP; everything else is
# VRE / hydro / storage and is handled separately.
const EMPIRE_THERMAL_TECHS = [
    "Nuclear", "Coal", "Coal CCS", "Lignite", "Lignite CCS",
    "Gas CCGT", "Gas OCGT", "Gas CCS", "Oil", "Bio", "Bio CCS",
    "Waste", "Geo",
]

# availability-table key for a tech (CCS variants inherit the parent's rate)
const EMPIRE_AVAIL_KEY = Dict(
    "Gas CCS" => "Gas CCGT", "Coal CCS" => "Coal",
    "Lignite CCS" => "Lignite", "Bio CCS" => "Bio",
)
empire_avail_key(t::AbstractString) = get(EMPIRE_AVAIL_KEY, String(t), String(t))

empire_zone(n::AbstractString) =
    startswith(n, "ES") ? "ES" :
    n == "France"       ? "FR" :
    n == "Portugal"     ? "PT" : "EU"

# ── tab readers ──────────────────────────────────────────────
# EMPIRE Output/*.tab files carry a proper header row; Input/Tab/*.tab files
# carry a junk "Source:_…" header, so they are read positionally.
read_out_tab(dir, f) = CSV.read(joinpath(dir, "Output", f), DataFrame; delim = '\t')
read_in_tab(dir, f; ncol) = CSV.read(joinpath(dir, "Input", "Tab", f), DataFrame;
                                     delim = '\t', header = false, skipto = 2,
                                     types = vcat(String, fill(Float64, ncol - 1)))

# ── main loader ──────────────────────────────────────────────
"""
    load_empire_scenario(cfg; data_dir) -> NamedTuple

Assemble every scenario table from the EMPIRE run selected in
cfg["scenario"].  `data_dir` is the repo Data/ folder (used for the
2024 reference fleets that the growth ratios are measured against).
"""
function load_empire_scenario(cfg; data_dir = joinpath(@__DIR__, "Data"))
    scfg   = cfg["scenario"]
    dir    = joinpath(@__DIR__, String(scfg["empire_dir"]))
    period = Int(scfg["period"])
    label  = empire_label(cfg)

    # ── installed generator capacity (MW) at `period` ────────
    df_cap = read_out_tab(dir, "genInstalledCap.tab")
    caps      = Dict(z => Dict{String,Float64}() for z in ("ES", "FR", "PT", "EU"))
    caps_nuts = Dict{String,Dict{String,Float64}}()      # ES NUTS node → tech → MW
    for r in eachrow(df_cap)
        Int(r.Period) == period || continue
        z, t, mw = empire_zone(String(r.Node)), empire_tech(String(r.Generator)),
                   Float64(r.genInstalledCap)
        mw > 1e-3 || continue
        caps[z][t] = get(caps[z], t, 0.0) + mw
        if z == "ES"
            zc = get!(caps_nuts, t, Dict{String,Float64}())
            zc[String(r.Node)] = get(zc, String(r.Node), 0.0) + mw
        end
    end

    # ── marginal costs (EUR/MWh) + CO2 adder ──────────────────
    # EMPIRE optimised under an emission cap, so marginal_costs.csv carries NO
    # CO2 cost; the adder prices the (remaining) emissions at the exogenous
    # CO2 price of the same period:  (3.6/η)·content·price.
    df_mc  = CSV.read(joinpath(dir, "Output", "marginal_costs.csv"), DataFrame)
    df_co2 = read_in_tab(dir, "General_CO2Price.tab";      ncol = 2)  # (period, EUR/t)
    df_eta = read_in_tab(dir, "Generator_Efficiency.tab";  ncol = 3)  # (gen, period, η)
    df_cnt = read_in_tab(dir, "Generator_CO2Content.tab";  ncol = 2)  # (gen, tCO2/GJ)
    co2_price = only(df_co2[parse.(Int, String.(df_co2[:, 1])) .== period, 2])
    eta = Dict(empire_tech(String(r[1])) => Float64(r[3])
               for r in eachrow(df_eta) if Int(r[2]) == period)
    co2 = Dict(empire_tech(String(r[1])) => Float64(r[2]) for r in eachrow(df_cnt))
    costs = Dict{String,Float64}()
    for r in eachrow(df_mc)
        Int(r.Period) == period || continue
        t = empire_tech(String(r.Generator))
        adder = get(co2, t, 0.0) == 0.0 ? 0.0 :
                (3.6 / eta[t]) * co2[t] * co2_price
        costs[t] = Float64(r.MarginalCost_EurperMWh) + adder
    end

    # ── annual demand (MWh/yr) per zone ───────────────────────
    df_dem = read_in_tab(dir, "Node_ElectricAnnualDemand.tab"; ncol = 3)
    demand = Dict{String,Float64}()
    for r in eachrow(df_dem)
        Int(r[2]) == period || continue
        z = empire_zone(String(r[1]))
        demand[z] = get(demand, z, 0.0) + Float64(r[3])
    end

    # ── cross-zone NTCs (MW), 2024 line orientation kept ──────
    df_tr = read_out_tab(dir, "transmissionInstalledCap.tab")
    ntc = Dict{Tuple{String,String},Float64}()
    for r in eachrow(df_tr)
        Int(r.Period) == period || continue
        f, t = empire_zone(String(r.FromNode)), empire_zone(String(r.ToNode))
        f == t && continue
        key = (f, t) in (("FR", "EU"),) ? ("EU", "FR") :
              (f, t) in (("ES", "PT"),) ? ("PT", "ES") :
              (f, t) in (("FR", "ES"),) ? ("ES", "FR") : (f, t)
        ntc[key] = get(ntc, key, 0.0) + Float64(r.transmissionInstalledCap)
    end

    # ── storage: pumped hydro + Li-Ion BESS per zone ──────────
    df_pw = read_out_tab(dir, "storPWInstalledCap.tab")
    df_en = read_out_tab(dir, "storENInstalledCap.tab")
    acc = Dict{Tuple{String,String},Dict{Symbol,Float64}}()   # (zone, storage) → pw/en
    for (df, col, key) in ((df_pw, :storPWInstalledCap, :pw),
                           (df_en, :storENInstalledCap, :en))
        for r in eachrow(df)
            Int(r.Period) == period || continue
            z = empire_zone(String(r.Node))
            d = get!(acc, (z, String(r.Storage)), Dict{Symbol,Float64}())
            d[key] = get(d, key, 0.0) + Float64(r[col])
        end
    end
    val(z, s, k) = get(get(acc, (z, s), Dict{Symbol,Float64}()), k, 0.0)
    storage = Dict(z => (phs_mw   = val(z, "HydroPumpStorage", :pw),
                         phs_mwh  = val(z, "HydroPumpStorage", :en),
                         bess_mw  = val(z, "Li-Ion_BESS",      :pw),
                         bess_mwh = val(z, "Li-Ion_BESS",      :en))
                   for z in ("ES", "FR", "PT", "EU"))

    # ── ES growth ratios vs the EMPIRE 2024 initial fleet ─────
    # Generation.csv holds EMPIRE's reference initial capacities (same data
    # lineage), so cap(period)/cap(2024-initial) is the internally consistent
    # growth factor to scale the bus-level unit fleet and the 2024-actual
    # solar/wind/load hourly profiles with.
    df_g24 = CSV.read(joinpath(data_dir, "Generation.csv"), DataFrame)
    rename!(df_g24, names(df_g24)[1] => :Node, names(df_g24)[3] => :cap)
    ref24 = Dict{String,Float64}()
    for r in eachrow(df_g24)
        startswith(String(r.Node), "ES") || continue
        t = String(r.GeneratorTechnology)
        ref24[t] = get(ref24, t, 0.0) + Float64(r.cap)
    end
    growth = Dict{String,Float64}()
    for (t, mw) in caps["ES"]
        r24 = get(ref24, t, 0.0)
        growth[t] = r24 > 1e-3 ? mw / r24 : 1.0     # brand-new techs: no scaling ref
    end

    # ES load scale vs the 2024 annual demand the pipeline is calibrated on
    # (smspp ZV_ZoneValues, the same reference the midterm SDDP uses).
    df_zv = CSV.read(joinpath(data_dir, "smspp_in", "ZV_ZoneValues.csv"),
                     DataFrame; delim = ';')
    es24  = only(Float64(r.value) for r in eachrow(df_zv) if String(r.Zone) == "ES")
    load_scale_es = demand["ES"] / es24

    return (label = label, period = period, co2_price = Float64(co2_price),
            caps = caps, caps_nuts = caps_nuts, costs = costs, demand = demand,
            ntc = ntc, storage = storage, growth = growth,
            load_scale_es = load_scale_es)
end

# ── market-chain views ───────────────────────────────────────
# generations.csv (fuel, technology) → EMPIRE tech, for unit scaling and costs
const EMPIRE_UNIT_TECH = Dict(
    ("Solar",   "PV")             => "Solar",
    ("Solar",   "CSP")            => "Solar",
    ("Solar",   "Solar Thermal")  => "Solar",
    ("Wind",    "Onshore")        => "Wind onshore",
    ("Wind",    "Offshore")       => "Wind onshore",     # ES: no offshore class in EMPIRE
    ("Nuclear", "Nuclear")        => "Nuclear",
    ("Gas",     "Combined_cycle") => "Gas CCGT",
    ("Gas",     "Gas_turbine")    => "Gas OCGT",
    ("Coal",    "Coal")           => "Coal",
    ("Biomass", "Biomass")        => "Bio",
    ("Hydro",   "Run_of_River")   => "Hydro run-of-the-river",
    ("Hydro",   "run_of_river")   => "Hydro run-of-the-river",
    ("Hydro",   "Reservoir")      => "Hydro regulated",
    ("Hydro",   "reservoir")      => "Hydro regulated",
    ("Oil",     "Combined_cycle") => "Oil",
    ("Oil",     "Gas_turbine")    => "Oil",
    # techs with no 2024 units — greenfield capacity created by the nodal
    # disaggregation (empire_nodal.jl); listed here so empire_cost_override
    # prices them from the EMPIRE marginal costs (incl. the CO2 adder,
    # negative for BioCCS) instead of the 60 EUR/MWh fallback.
    ("Waste",   "Waste")          => "Waste",
    ("Biomass", "BioCCS")         => "Bio CCS",
    ("Gas",     "Gas_CCS")        => "Gas CCS",
    ("Coal",    "Coal_CCS")       => "Coal CCS",
    ("Lignite", "Lignite")        => "Lignite",
    ("Lignite", "Lignite_CCS")    => "Lignite CCS",
    ("Geo",     "Geo")            => "Geo",
)

"""
    empire_unit_scale(emp; data_dir) -> Dict{Tuple{String,String},Float64}

Per-(fuel, technology) capacity scale factors for the bus-level unit fleet.
Regular techs use the EMPIRE growth ratio; pumped storage is rescaled so the
unit fleet total matches the EMPIRE installed pumped-hydro power capacity.
"""
function empire_unit_scale(emp; data_dir = joinpath(@__DIR__, "Data"))
    scale = Dict{Tuple{String,String},Float64}()
    for (key, t) in EMPIRE_UNIT_TECH
        scale[key] = get(emp.growth, t, 1.0)
    end
    # pumped storage: match the EMPIRE zone total against today's unit fleet
    gdf = CSV.read(joinpath(data_dir, "generations.csv"), DataFrame)
    ps  = sum(Float64(r.capacity_mw) for r in eachrow(gdf)
              if String(r.primary_fuel) == "Hydro" &&
                 lowercase(String(r.technology)) == "pumped_storage"; init = 0.0)
    scale[("Hydro", "pumped_storage")] = ps > 1e-3 ? emp.storage["ES"].phs_mw / ps : 1.0
    return scale
end

"""
    empire_cost_override(emp) -> Dict{Tuple{String,String},Float64}

Per-(fuel, technology) marginal costs [EUR/MWh] for the bus-level fleet
(replaces the pypsa-2024 table).  Pumped storage keeps its pypsa cost
(EMPIRE prices storage through its charge/discharge cycle, not per MWh).
"""
function empire_cost_override(emp)
    over = Dict{Tuple{String,String},Float64}()
    for (key, t) in EMPIRE_UNIT_TECH
        haskey(emp.costs, t) && (over[key] = emp.costs[t])
    end
    return over
end

"""
    empire_bess_units(emp; data_dir, n_buses) -> Vector{NamedTuple}

Site the EMPIRE Spanish Li-Ion BESS fleet on the grid: the installed power/
energy is split across the `n_buses` highest-demand buses in proportion to
their load share.  Returns [(bus_id, power_mw, energy_mwh), …].
"""
function empire_bess_units(emp; data_dir = joinpath(@__DIR__, "Data"), n_buses = 20)
    p_mw, e_mwh = emp.storage["ES"].bess_mw, emp.storage["ES"].bess_mwh
    p_mw > 1e-3 || return NamedTuple[]
    ldf = sort(CSV.read(joinpath(data_dir, "load.csv"), DataFrame),
               :demand; rev = true)[1:n_buses, :]
    wtot = sum(Float64.(ldf.demand))
    return [(bus_id = String(r.bus_id),
             power_mw  = p_mw  * Float64(r.demand) / wtot,
             energy_mwh = e_mwh * Float64(r.demand) / wtot)
            for r in eachrow(ldf)]
end
