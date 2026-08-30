#!/usr/bin/env julia

# Build the two production market-chain configs using a shared peak-demand
# winter/summer key and explicit line-specific reinforcement files.

using TOML

cases = [
    (scenario = "NECPEssentials",
     reinforcement = "results/NECPEssentials_sens_hourlyntc0p7_intra3p0_inter5p0_da_rd/reinforcement_combined.csv"),
    (scenario = "Trinity",
     reinforcement = "results/Trinity_sens_hourlyntc0p7_intra2p5_inter3p0_da_rd/reinforcement_combined.csv"),
]

for case in cases
    template = joinpath(@__DIR__, "config_$(case.scenario).toml")
    cfg = TOML.parsefile(template)

    for stage in ("id2", "id3", "cid", "balancing")
        cfg[stage]["enabled"] = true
    end
    cfg["crossborder"]["enabled"] = false

    weeks = cfg["weeks"]
    weeks["enabled"] = true
    weeks["n_weeks"] = 2
    weeks["contiguous"] = false
    weeks["resample"] = false
    weeks["key_file"] = "cluster/sample_weeks_market_summer_winter.csv"
    ntc = get!(weeks, "ntc", Dict{String,Any}())
    ntc["enabled"] = true
    ntc["reuse"] = true
    ntc["reliability_margin"] = 0.70
    ntc["only"] = false
    ntc["cache_file"] = "hourly_ntc.csv"

    rd = cfg["redispatch"]
    rd["enabled"] = true
    rd["from_saved"] = ""
    rd["only"] = ""
    rd["power_flow"] = "AC"
    rd["diagnostic_output"] = false
    rd["diagnostic_intra_nuts_multiplier"] = 1.0
    rd["diagnostic_inter_nuts_multiplier"] = 1.0
    rd["diagnostic_international_multiplier"] = 1.0
    rd["crossborder_split"] = "country_total"
    rd["extra_line_scale_file"] = case.reinforcement

    cfg["network"]["line_rating_factor"] = 0.80
    out = joinpath(@__DIR__, "config_market_$(case.scenario)_winter_summer.toml")
    open(out, "w") do io
        TOML.print(io, cfg)
    end
    println("wrote $(basename(out))")
end
