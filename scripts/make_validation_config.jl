# Build the validation chain config for step 6 of
# docs/method_grid_reinforcement_identification.md.
#
#   julia --project=. scripts/make_validation_config.jl <label> <reinforcement.csv> [n_weeks] [AC|DC]
#
# Same sampled-week horizon and hourly-NTC day-ahead as the diagnostic, so the
# validation is run on exactly the weeks the reinforcement list was derived
# from.  The differences are the point of the step: the derived list is loaded
# through [redispatch].extra_line_scale_file, and the diagnostic multipliers are
# returned to 1.0 so nothing but that list relieves the network.
using TOML

length(ARGS) >= 2 || error("usage: make_validation_config.jl <label> <reinforcement.csv> [n_weeks] [AC|DC]")
scen = ARGS[1]
list = ARGS[2]
nwk  = length(ARGS) >= 3 ? parse(Int, ARGS[3])  : 2
pf   = length(ARGS) >= 4 ? uppercase(ARGS[4])   : "DC"

cfg = TOML.parsefile(joinpath(@__DIR__, "..", "config.toml"))
cfg["scenario"]["label"]      = scen
cfg["scenario"]["empire_dir"] = "Data/2035/$scen"
cfg["midterm4"]["end_penalty"] = 0.0

w = cfg["weeks"]
w["enabled"]    = true
w["n_weeks"]    = nwk
w["contiguous"] = false
# resample = false: reuse the key file the diagnostic drew, so validation and
# derivation see the same weeks.  A fresh draw would change the question.
w["resample"]   = false
w["seed"]       = 20260822
w["key_file"]   = "Data/sample_weeks_diag_$(nwk)w.csv"
ntc = get!(w, "ntc", Dict{String,Any}())
ntc["enabled"] = true
ntc["reuse"] = true
ntc["reliability_margin"] = 0.70
w["xb_ntc_margin"] = 1.0

cfg["crossborder"]["enabled"] = false
cfg["id2"]["enabled"] = false
cfg["id3"]["enabled"] = false
cfg["cid"]["enabled"] = false
cfg["balancing"]["enabled"] = false

cfg["network"]["line_rating_factor"] = 0.80
cfg["network"]["voltage_band"] = 0.10

rd = cfg["redispatch"]
rd["power_flow"] = pf
rd["from_saved"] = ""
# Full output: the validation run is the one whose results get analysed.
rd["diagnostic_output"] = false
rd["diagnostic_intra_nuts_multiplier"] = 1.0
rd["diagnostic_inter_nuts_multiplier"] = 1.0
rd["diagnostic_international_multiplier"] = 1.0
rd["crossborder_split"] = "country_total"
rd["extra_line_scale_file"] = list

p = joinpath(@__DIR__, "config_validate_$(scen).toml")
open(p, "w") do io; TOML.print(io, cfg); end
println("wrote scripts/config_validate_$(scen).toml")
println("  power_flow=$pf  base_lrf=0.80  reinforcement_list=$list")
