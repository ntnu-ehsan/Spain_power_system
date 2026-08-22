# Generate one config per EMPIRE 2035 scenario for a cluster run.
#
# Reads the tracked config.toml and applies only the overrides a cluster run
# needs, so nothing here depends on whatever local iteration state config.toml
# happens to carry.  Writes cluster/config_<label>.toml, which both
# midterm_sddp4.jl and run_opf.jl accept through SPAIN_CONFIG.
#
#   julia --project=. cluster/make_configs.jl [--weeks=on|off] [--solver=gurobi|highs]
#
# --weeks  off (default) reproduces the two fixed 2024 study days on the 2035
#          fleet, which is what the existing results/<label>/ runs used, so a
#          redispatch re-verification is comparable.  on switches to the sampled
#          multi-week horizon with the joint ES/PT/FR/EU day-ahead — a different
#          experiment, not a like-for-like check.
using TOML

const ROOT = normpath(joinpath(@__DIR__, ".."))
const SCENARIOS = ["NECPEssentials", "Trinity", "REPowerEU++", "GoRES"]

# Manual per-line reinforcement for the AC redispatch.  Only Trinity has one so
# far; the others start unreinforced and the run's overload ranking is what
# produces theirs (docs/method_grid_reinforcement_identification.md).
const REINFORCEMENT = Dict(
    "Trinity" => "Data/trinity_line_reinforcement_gt0.8.csv",
)

argval(k, default) = something(
    findfirst(a -> startswith(a, "--$k="), ARGS) |> i ->
        i === nothing ? nothing : split(ARGS[i], "=", limit = 2)[2],
    default)

weeks_on = lowercase(argval("weeks", "off")) in ("on", "true", "1")
solver   = lowercase(argval("solver", "gurobi"))
solver in ("gurobi", "highs") || error("--solver must be gurobi or highs")

for scen in SCENARIOS
    cfg = TOML.parsefile(joinpath(ROOT, "config.toml"))

    cfg["scenario"]["label"]      = scen
    cfg["scenario"]["empire_dir"] = "Data/2035/$scen"

    m = cfg["midterm4"]
    # The end-of-horizon reservoir target is dropped: over 78 weekly stages the
    # terminal effect reaches back only to week ~74, so the 52-week window the
    # market chain uses is already clean, while the penalty printed an
    # artificial -150 EUR/MWh ceiling onto the cut slopes.
    m["end_penalty"] = 0.0
    m["solver"]      = solver

    cfg["weeks"]["enabled"] = weeks_on

    rd = cfg["redispatch"]
    rd["from_saved"] = ""                      # full chain, not a redispatch-only replay
    rd["extra_line_scale_file"] = get(REINFORCEMENT, scen, "")

    path = joinpath(@__DIR__, "config_$(scen).toml")
    open(path, "w") do io; TOML.print(io, cfg); end
    println("wrote cluster/config_$(scen).toml  " *
            "(end_penalty=$(m["end_penalty"]), solver=$(m["solver"]), " *
            "weeks=$(cfg["weeks"]["enabled"]), " *
            "reinforcement=$(isempty(rd["extra_line_scale_file"]) ? "none" : rd["extra_line_scale_file"]))")
end
