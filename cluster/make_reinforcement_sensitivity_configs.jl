#!/usr/bin/env julia

# Generate reproducible hourly-NTC reinforcement-sensitivity configs from the
# tracked NECPEssentials reference configuration. Keeping one reference avoids
# drift between scenario sweeps while `empire_suffixed` selects each scenario's
# own SDDP cuts, volumes, and turbine schedule at runtime.

using TOML

length(ARGS) >= 2 || error(
    "usage: make_reinforcement_sensitivity_configs.jl <scenario> <inter|intra> [fixed_multiplier]")

scenario = ARGS[1]
sweep = lowercase(ARGS[2])
sweep in ("inter", "intra") || error("sweep must be inter or intra")

inter_cases = [("1p0", 1.0), ("1p5", 1.5), ("2p0", 2.0),
               ("3p0", 3.0), ("4p0", 4.0), ("4p5", 4.5)]
intra_cases = [("1p0", 1.0), ("1p5", 1.5), ("2p0", 2.0),
               ("2p5", 2.5), ("2p75", 2.75), ("3p0", 3.0),
               ("4p0", 4.0)]

fixed = length(ARGS) >= 3 ? parse(Float64, ARGS[3]) :
        (sweep == "inter" ? 10.0 : 5.0)
template = joinpath(@__DIR__, "config_sens_NECP_intra10_inter1p0.toml")
isfile(template) || error("missing tracked sensitivity template: $template")

function multiplier_tag(x::Float64)
    replace(string(x), "." => "p")
end

for (case_tag, case_value) in (sweep == "inter" ? inter_cases : intra_cases)
    cfg = TOML.parsefile(template)
    cfg["scenario"]["label"] = scenario
    cfg["scenario"]["empire_dir"] = "Data/2035/$scenario"

    # Reuse the exact persisted weather-week key across scenarios and parallel
    # cases. The key is input data and is transferred separately to the cluster.
    cfg["weeks"]["resample"] = false
    cfg["weeks"]["key_file"] = "Data/sample_weeks_diag_2w.csv"
    ntc = cfg["weeks"]["ntc"]
    ntc["enabled"] = true
    ntc["reuse"] = true
    ntc["reliability_margin"] = 0.70
    ntc["only"] = false
    ntc["cache_file"] = "hourly_ntc.csv"

    rd = cfg["redispatch"]
    rd["power_flow"] = "DC"
    rd["diagnostic_output"] = true
    rd["crossborder_split"] = "country_total"
    rd["diagnostic_international_multiplier"] = 1.0
    rd["extra_line_scale_file"] = ""
    if sweep == "inter"
        rd["diagnostic_intra_nuts_multiplier"] = fixed
        rd["diagnostic_inter_nuts_multiplier"] = case_value
        intra_tag, inter_tag = multiplier_tag(fixed), case_tag
    else
        rd["diagnostic_intra_nuts_multiplier"] = case_value
        rd["diagnostic_inter_nuts_multiplier"] = fixed
        intra_tag, inter_tag = case_tag, multiplier_tag(fixed)
    end

    out = joinpath(@__DIR__,
        "config_sens_$(scenario)_intra$(intra_tag)_inter$(inter_tag).toml")
    open(out, "w") do io
        TOML.print(io, cfg)
    end
    println("wrote $(basename(out))")
end

