# Diagnostic config for step 3 of docs/method_grid_reinforcement_identification.md:
# an over-rated, UNCONGESTED solve for same-NUTS3 Spanish branches. EMPIRE's
# inter-NUTS3 and international corridor capacities remain fixed by default;
# separate optional multipliers support controlled sensitivity tests.
#
#   julia --project=. cluster/make_diag_config.jl <label> [intra_mult] [n_weeks] [AC|DC] [inter_mult] [international_mult] [xb_split]
#   defaults:                                              10.0         2         DC      1.0         1.0                 fixed
#
# Why DC.  req_factor sizes a THERMAL rating against active power, and step 2 of
# the method already ruled voltage out for this scenario, so the reactive/voltage
# machinery of the AC OPF buys nothing here and costs an order of magnitude in
# runtime.  Spending that time on more weeks instead is the better trade: the
# statistic is a MAX over hours, so coverage of the flow distribution matters far
# more than per-hour fidelity.
#
# The caveat, measured on the existing AC results: loading_pct is |S|/rate for AC
# branches, and at their peak-loading hour the 32 binding branches carry a median
# |S|/|P| of 1.043 -- so a DC pass under-reports them ~4 %, and a handful that are
# reactive-dominated (90th pct 4.2) far more.  Treat the DC list as a LOWER bound
# and confirm it with the AC validation run in step 6.
using TOML
scen  = length(ARGS) >= 1 ? ARGS[1] : error("usage: make_diag_config.jl <label> [intra_mult] [n_weeks] [AC|DC] [inter_mult] [international_mult] [xb_split]")
mult  = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : 10.0
nwk   = length(ARGS) >= 3 ? parse(Int, ARGS[3])     : 2
pf    = length(ARGS) >= 4 ? uppercase(ARGS[4])      : "DC"
imult = length(ARGS) >= 5 ? parse(Float64, ARGS[5]) : 1.0
xmult = length(ARGS) >= 6 ? parse(Float64, ARGS[6]) : 1.0
xbsplit = length(ARGS) >= 7 ? lowercase(ARGS[7]) : "fixed"
xbsplit in ("fixed", "country_total") || error("xb_split must be fixed or country_total")

cfg = TOML.parsefile(joinpath(@__DIR__, "..", "config.toml"))
cfg["scenario"]["label"]      = scen
cfg["scenario"]["empire_dir"] = "Data/2035/$scen"
cfg["midterm4"]["end_penalty"] = 0.0            # match the cuts now on disk

w = cfg["weeks"]
w["enabled"]    = true
w["n_weeks"]    = nwk
# Independent draws on distinct slots rather than one contiguous block: the
# reinforcement statistic wants the widest spread of operating conditions
# (winter peak, summer solar surplus, windy nights), not one correlated season.
w["contiguous"] = false
w["resample"]   = true
w["seed"]       = 20260822
# A private key file — resampling the shared Data/sample_weeks.csv would silently
# move the two weeks every other scenario run is compared on.
w["key_file"]   = "Data/sample_weeks_diag_$(nwk)w.csv"
# With an intentionally uncongested high-LRF grid, the hourly NTC preprocessor
# only rediscovers EMPIRE's commercial caps, at the cost of several DC solves
# per delivery hour.  Use those caps directly through the static fallback.
ntc = get!(w, "ntc", Dict{String,Any}())
ntc["enabled"] = false
w["xb_ntc_margin"] = 1.0

# [crossborder] carries fixed injections for the 2024 study days only; the
# sampled horizon clears its own ES-FR/ES-PT exchange inside the 4-zone DA, and
# run_opf.jl refuses to start with both switched on.
cfg["crossborder"]["enabled"] = false

# Keep the normal operating derate. run_opf.jl applies the separate multiplier
# below only to same-NUTS3 Spanish branches.
cfg["network"]["line_rating_factor"] = 0.80
cfg["network"]["voltage_band"] = 0.10

rd = cfg["redispatch"]
rd["power_flow"] = pf
rd["from_saved"] = ""
rd["diagnostic_output"] = true
rd["diagnostic_intra_nuts_multiplier"] = mult
rd["diagnostic_inter_nuts_multiplier"] = imult
rd["diagnostic_international_multiplier"] = xmult
rd["crossborder_split"] = xbsplit
# The manual list is what we are deriving, so it must not be in the baseline.
# EMPIRE's own nodal corridor investment stays -- that is part of the scenario.
rd["extra_line_scale_file"] = ""

p = joinpath(@__DIR__, "config_diag_$(scen).toml")
open(p, "w") do io; TOML.print(io, cfg); end
println("wrote cluster/config_diag_$(scen).toml")
println("  power_flow=$pf  base_lrf=0.80  intra_nuts_multiplier=$mult  inter_nuts_multiplier=$imult  international_multiplier=$xmult")
println("  crossborder_split=$xbsplit (DA country totals remain exact)")
println("  n_weeks=$nwk (non-contiguous, seed 20260822)")
println("  key_file=$(w["key_file"])  hourly_ntc=off  diagnostic_output=on")
println("  crossborder=off  extra_line_scale_file=none")
