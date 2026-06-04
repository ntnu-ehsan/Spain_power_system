# ============================================================
# Spain Power System — Cross-border exchange reader (redispatch input)
# ============================================================
# Reads the market-cleared cross-border schedule (Data/crossborder.csv)
# and turns it into fixed nodal injections at the FR/PT terminal buses,
# so the redispatch AC OPF sees the imports/exports that were settled in
# the market clearing that preceded redispatch.
#
# crossborder.csv columns:
#   Day      : "8_Jul" / "2_Dec"        -> study date
#   Time     : "HH:00 - HH:00"          -> delivery hour (start hour, 0..23)
#   to_PT,   from_PT                    : Spain->PT export, PT->Spain import [MW]
#   from_FR, to_FR                      : FR->Spain import, Spain->FR export [MW]
#
# Net injection into Spain per country = from_X - to_X  (import positive).
# The per-country total is disaggregated across that country's border
# lines proportionally to each line's thermal rating (∝ V·Imax) and then
# aggregated to the foreign terminal bus, where it is injected.
#
# Usage (from run_opf.jl, after data_preparation.jl is included):
#   xb     = load_crossborder()                       # date => hour => (FR,PT) net MW
#   fracs  = crossborder_bus_fractions()              # country => bus_id => share
#   inj    = crossborder_injections(xb, fracs, "2024-12-02", 13)  # bus_id => MW
# ============================================================

using CSV, DataFrames

# "Day" label in crossborder.csv -> study date used everywhere else.
const XB_DAY_MAP = Dict("8_Jul" => "2024-07-08", "2_Dec" => "2024-12-02")

# Read the cross-border schedule into date => hour => (FR=net, PT=net) in MW,
# where net = import into Spain − export from Spain.
function load_crossborder()::Dict{String,Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}}
    df = CSV.read(joinpath(DATA, "crossborder.csv"), DataFrame)
    data = Dict{String,Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}}()
    for row in eachrow(df)
        haskey(XB_DAY_MAP, string(row.Day)) || continue
        date_str = XB_DAY_MAP[string(row.Day)]
        hour     = parse(Int, split(strip(string(row.Time)), ":")[1])   # start hour
        net_fr   = Float64(row.from_FR) - Float64(row.to_FR)
        net_pt   = Float64(row.from_PT) - Float64(row.to_PT)
        get!(data, date_str, Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}())[hour] =
            (FR = net_fr, PT = net_pt)
    end
    return data
end

# Identify the FR/PT border buses and the share of their country's exchange that
# each one carries, proportional to the thermal rating (∝ V·Imax) of the border
# line(s) terminating at that bus.  Returns country => (bus_id => fraction),
# fractions summing to 1 within each country.
function crossborder_bus_fractions()::Dict{String,Dict{String,Float64}}
    bus_df  = CSV.read(joinpath(DATA, "Bus_Data.csv"), DataFrame)
    line_df = CSV.read(joinpath(DATA, "lines.csv"),    DataFrame)
    country = Dict(string(r.bus_id) => string(r.country) for r in eachrow(bus_df))

    # Accumulate per-country, per-bus line-rating weights.
    weight = Dict("FR" => Dict{String,Float64}(), "PT" => Dict{String,Float64}())
    for r in eachrow(line_df)
        b0, b1 = string(r.bus0), string(r.bus1)
        # A border line has exactly one foreign (FR/PT) end and one ES end.
        for (foreign, home) in ((b0, b1), (b1, b0))
            c = get(country, foreign, "ES")
            (c == "FR" || c == "PT") && get(country, home, "ES") == "ES" || continue
            w = Float64(r.voltage) * Float64(r.Imax)   # ∝ √3·V·Imax thermal rating
            weight[c][foreign] = get(weight[c], foreign, 0.0) + w
        end
    end

    fracs = Dict{String,Dict{String,Float64}}()
    for (c, busw) in weight
        tot = sum(values(busw))
        fracs[c] = Dict(bus => w / tot for (bus, w) in busw)
    end
    return fracs
end

# Net cross-border injection (MW, import into Spain positive) per foreign bus for
# one study date and hour (0..23).  Returns Dict{bus_id => MW}.
function crossborder_injections(xb_data, fracs, date_str::String, hour::Int)::Dict{String,Float64}
    net = xb_data[date_str][hour]
    inj = Dict{String,Float64}()
    for (country, total) in (("FR", net.FR), ("PT", net.PT))
        for (bus, f) in fracs[country]
            inj[bus] = get(inj, bus, 0.0) + total * f
        end
    end
    return inj
end
