# ============================================================
# Mid-term hydro-thermal scheduling by SDDP (in-house Bellman cuts)
#
# Replaces the SMS++/plan4res seasonal-storage-valuation output
# (Data/BellmanValuesOUT.csv + Data/Volume_Scen0_OUT.csv) with cuts
# computed here, so the whole market chain no longer depends on an
# external run.
#
# Model
#   • 3 zones FR / ES / PT coupled by the two interconnections in
#     Data/smspp_in/IN_Interconnections.csv (transport model).
#   • 78 weekly stages (Timestep 0..77) starting [bellman].bgn_date.
#     The exported last stage keeps the SMS++ convention of a single
#     trivial cut (77,0,0,0), but the model itself carries a soft
#     end-of-horizon reservoir target (end_fill × v0, penalised at
#     end_penalty EUR/MWh) — with a plain zero terminal value water is
#     free after stage 78 and the reservoirs are emptied into the end.
#   • 2 state variables: the FR and ES seasonal reservoirs
#     (SS_SeasonalStorage.csv).  Pumped storage and batteries cycle
#     within the week and are not states.
#   • Stagewise-independent uncertainty: each week samples one climate
#     year, and inflow / wind / solar / demand are taken jointly from
#     that year's column of the Data/ts profiles.
#   • The original FR ("BigFrance") and PT series are not in the repo;
#     their shapes come from the EMPIRE historical data (Data/ts/EMPIRE,
#     2015–2019, EU column = aggregated rest-of-Europe → FR zone),
#     rescaled to each unit's annual Energy / Capacity in Data/smspp_in.
#     Each climate-year scenario is paired with a fixed EMPIRE year
#     (cycling 2015..2019) so weekly samples stay single joint draws.
#
# Output (drop-in for the [bellman] inputs of run_opf.jl)
#   • cuts:   Timestep,a_0,a_1,b   with  cost-to-go(V) = max_cuts a_0·V_FR + a_1·V_ES + b
#   • volume: hourly FR/ES reservoir trajectory for the sim_year scenario
#
# Run:  julia --project=. midterm_sddp.jl
# ============================================================

using CSV, DataFrames, Dates, Printf, Random, Statistics, TOML
using JuMP, SDDP
import JSON

# ── configuration ────────────────────────────────────────────
cfg  = TOML.parsefile(joinpath(@__DIR__, "config.toml"))
mcfg = cfg["midterm"]

const BGN_DATE    = Date(cfg["bellman"]["bgn_date"])
const N_STAGES    = Int(mcfg["n_stages"])
const BLOCK_HOURS = Int(mcfg["block_hours"])
const NB          = div(168, BLOCK_HOURS)          # blocks per weekly stage
const ITERATIONS  = Int(mcfg["iterations"])
const VOLL        = Float64(mcfg["voll"])
# End-of-horizon reservoir target: the last stage must reach END_FILL × v0 or
# pay END_PENALTY per missing MWh.  END_PENALTY = 0 disables it (zero terminal
# value → reservoirs drained by stage N_STAGES).
const END_FILL    = Float64(get(mcfg, "end_fill", 1.0))
const END_PENALTY = Float64(get(mcfg, "end_penalty", 150.0))
const SOLVER      = lowercase(String(mcfg["solver"]))
const SIM_YEAR    = Int(mcfg["sim_year"])
const YEAR_STRIDE = Int(get(mcfg, "year_stride", 1))
const CUTS_OUT    = joinpath(@__DIR__, mcfg["cuts_out"])
const VOLUME_OUT  = joinpath(@__DIR__, mcfg["volume_out"])
const SMSPP_IN    = joinpath(@__DIR__, "Data", "smspp_in")
const TS_DIR      = joinpath(@__DIR__, "Data", "ts")

@assert 168 % BLOCK_HOURS == 0 && 24 % BLOCK_HOURS == 0 "block_hours must divide 24"

Random.seed!(Int(get(mcfg, "seed", 1234)))

# ── solver ───────────────────────────────────────────────────
if SOLVER == "gurobi"
    using Gurobi
    const GRB_ENV = Gurobi.Env()
    optimizer() = optimizer_with_attributes(
        () -> Gurobi.Optimizer(GRB_ENV), "OutputFlag" => 0, "Threads" => 1)
else
    using HiGHS
    optimizer() = optimizer_with_attributes(HiGHS.Optimizer,
        "output_flag" => false, "threads" => 1)
end

# ── smspp_in readers (semicolon CSVs) ────────────────────────
read_smspp(f) = CSV.read(joinpath(SMSPP_IN, f), DataFrame; delim = ';')

df_tu  = read_smspp("TU_ThermalUnits.csv")
df_res = read_smspp("RES_RenewableUnits.csv")
df_ss  = read_smspp("SS_SeasonalStorage.csv")
df_sts = read_smspp("STS_ShortTermStorage.csv")
df_in  = read_smspp("IN_Interconnections.csv")
df_zv  = read_smspp("ZV_ZoneValues.csv")

const ZONES = ["ES", "FR", "PT"]

# ── profile files (Data/ts) ──────────────────────────────────
# Resolutions: :hourly 8760 rows, :daily 365, :weekly 53.  Values are
#   load factors        (wind / PV — fraction of capacity), or
#   hourly coefficients (inflow / RoR / load — fraction of annual energy per hour).
struct Profile
    res    :: Symbol                 # :hourly | :daily | :weekly
    years  :: Vector{Int}
    data   :: Matrix{Float64}        # rows × years
end

function load_profile(fname::String, res::Symbol)::Profile
    df = CSV.read(joinpath(TS_DIR, fname), DataFrame)
    yrs = [parse(Int, String(n)) for n in names(df)[2:end]]
    Profile(res, yrs, Matrix{Float64}(df[:, 2:end]))
end

prof_wind_es = load_profile("EDF__WindOnshore-LoadFactor-PresentClimate-ES__13082019__13082019__v1.csv", :hourly)
prof_pv_es   = load_profile("EDF__PV-LoadFactor-PresentClimate-ES__13082019__13082019__v1.csv",         :hourly)
prof_ror_es  = load_profile("EDF__RunOfRiver-HourlyCoefficient-PresentClimate-ES__18092019__18092019__v1.csv", :daily)
prof_inf_es  = load_profile("EDF__Inflow-HourlyCoefficient-PresentClimate-ES__18092019__18092019__v1.csv",     :weekly)
prof_load    = load_profile("Profile-Iberia.csv", :hourly)   # the Profile-Iberia2.csv referenced by ZV_ZoneValues

# Climate years usable jointly across all profiles (load has 1982–2018)
const YEARS = sort(collect(intersect(Set(prof_wind_es.years), Set(prof_pv_es.years),
                                     Set(prof_ror_es.years),  Set(prof_inf_es.years),
                                     Set(prof_load.years))))[1:YEAR_STRIDE:end]
const NSCEN = length(YEARS)
ycol(p::Profile, y::Int) = findfirst(==(y), p.years)

# ── calendar mapping ─────────────────────────────────────────
# Absolute hour k (0-based from BGN_DATE 00:00) → profile row.  Profiles are
# indexed by day-of-year in a 365-day year (their dummy 2050 timestamps);
# the 78-week window Jul-2024 .. Dec-2025 contains no Feb 29.
function profile_row(p::Profile, k::Int)::Int
    dt  = DateTime(BGN_DATE) + Hour(k)
    doy = dayofyear(Date(2023, month(dt), day(dt)))       # non-leap day-of-year
    p.res == :hourly && return (doy - 1) * 24 + hour(dt) + 1
    p.res == :daily  && return doy
    return min(div(doy - 1, 7) + 1, 53)                   # :weekly
end

# Mean profile value over block b of stage t (hours are 0-based)
function block_mean(p::Profile, y::Int, t::Int, b::Int)::Float64
    c  = ycol(p, y)
    k0 = (t - 1) * 168 + (b - 1) * BLOCK_HOURS
    return sum(p.data[profile_row(p, k0 + j), c] for j in 0:BLOCK_HOURS-1) / BLOCK_HOURS
end

# ── EMPIRE historical series → FR/PT shapes ──────────────────
# Data/ts/EMPIRE/*.csv: hourly 2015–2019, one column per region (EU = the
# aggregated rest-of-Europe, mapped onto the FR zone).  Wind/solar/RoR are
# capacity factors; electricload [MW] and hydroseasonal inflow [MW] are
# normalised to per-hour fractions of the annual total (the "hourly
# coefficient" convention).  Scenario year YEARS[i] is deterministically
# paired with EMPIRE year 2015 + (i-1) mod 5.
const EMPIRE_DIR = joinpath(TS_DIR, "EMPIRE")
const EMP_YEARS  = collect(2015:2019)

function read_empire(fname::String, col::String)::Dict{Int,Vector{Float64}}
    df = CSV.read(joinpath(EMPIRE_DIR, fname), DataFrame)
    ts = DateTime.(String.(df.time), dateformat"dd/mm/yyyy HH:MM")
    out = Dict{Int,Vector{Float64}}()
    for y in EMP_YEARS
        keep = (year.(ts) .== y) .& .!((month.(ts) .== 2) .& (day.(ts) .== 29))
        v = Float64.(df[keep, col])
        length(v) == 8760 || error("$fname/$col year $y: $(length(v)) rows, expected 8760")
        out[y] = v
    end
    return out
end

function empire_profile(byyear::Dict{Int,Vector{Float64}}; normalize::Bool = false)::Profile
    data = Matrix{Float64}(undef, 8760, NSCEN)
    for i in 1:NSCEN
        v = byyear[EMP_YEARS[1 + (i - 1) % length(EMP_YEARS)]]
        data[:, i] = normalize ? v ./ sum(v) : v
    end
    return Profile(:hourly, collect(YEARS), data)
end

emp_load     = Dict(z => empire_profile(read_empire("electricload.csv", c); normalize = true)
                    for (z, c) in (("FR", "EU"), ("PT", "PT")))
emp_wind_on  = Dict(z => empire_profile(read_empire("windonshore.csv", c))
                    for (z, c) in (("FR", "EU"), ("PT", "PT")))
emp_wind_off = Dict("FR" => empire_profile(read_empire("windoffshore.csv", "EU")))
emp_pv       = Dict(z => empire_profile(read_empire("solar.csv", c))
                    for (z, c) in (("FR", "EU"), ("PT", "PT")))
emp_ror      = Dict(z => empire_profile(read_empire("hydroror.csv", c); normalize = true)
                    for (z, c) in (("FR", "EU"), ("PT", "PT")))
emp_inf_fr   = empire_profile(read_empire("hydroseasonal.csv", "EU"); normalize = true)

# ── rescaling to the smspp_in annual targets ─────────────────
# Wind/solar shapes are iteratively rescaled (with cap at 1.0) so the mean
# capacity factor matches Energy / (Capacity·8760h).
function scaled_profile(base::Profile, target_cf::Float64)::Profile
    s = target_cf / max(mean(base.data), 1e-9)
    d = similar(base.data)
    for _ in 1:12
        @. d = min(1.0, s * base.data)
        m = mean(d)
        m ≥ target_cf - 1e-6 && break
        s *= target_cf / m
    end
    return Profile(base.res, base.years, d)
end

# ── renewable units → (zone, cap MW, profile, kind) ──────────
# kind :cf     → generation ≤ cap · profile           (wind / PV)
# kind :energy → generation ≤ min(cap, annualE · coeff) (run-of-river)
struct ResUnit
    zone    :: String
    name    :: String
    cap     :: Float64        # MW
    annualE :: Float64        # MWh (kind :energy only)
    kind    :: Symbol
    prof    :: Profile
end

res_units = ResUnit[]
for r in eachrow(df_res)
    lname = lowercase(r.Name)
    zone  = String(r.Zone)
    if occursin("river", lname) || occursin("run_of_river", lname)
        # MaxPower column holds annual energy [MWh], Capacity the MW limit
        prof = zone == "ES" ? prof_ror_es : emp_ror[zone]
        push!(res_units, ResUnit(zone, r.Name, Float64(r.Capacity) * r.NumberUnits,
                                 Float64(r.MaxPower), :energy, prof))
    else
        iswind = occursin("wind", lname)
        base = zone == "ES" ? (iswind ? prof_wind_es : prof_pv_es) :
               !iswind                      ? emp_pv[zone]       :
               occursin("offshore", lname)  ? emp_wind_off[zone] : emp_wind_on[zone]
        cap  = Float64(r.MaxPower) * r.NumberUnits
        if Float64(r.Energy) > 0.0    # FR/PT rows: rescale shape to the annual target
            cf = Float64(r.Energy) / (cap * 8760.0)
            base = scaled_profile(base, cf)
        end
        push!(res_units, ResUnit(zone, r.Name, cap, 0.0, :cf, base))
    end
end

# ── thermal units ────────────────────────────────────────────
therm = [(zone = String(r.Zone), name = String(r.Name),
          pmax = Float64(r.MaxPower) * r.NumberUnits,
          cost = Float64(r.VariableCost)) for r in eachrow(df_tu)]

# ── seasonal reservoirs (the SDDP states) ────────────────────
struct Reservoir
    zone      :: String
    pmax      :: Float64      # MW turbine
    vmax      :: Float64      # MWh
    vmin      :: Float64
    v0        :: Float64
    inflow_yr :: Float64      # MWh nominal annual inflow
    prof      :: Profile      # hourly-coefficient profile (weekly ES / hourly FR)
end
reservoirs = Dict{String,Reservoir}()
for r in eachrow(df_ss)
    z = String(r.Zone)
    reservoirs[z] = Reservoir(z,
        Float64(r.MaxPower) * r.NumberUnits, Float64(r.MaxVolume),
        Float64(r.MinVolume), Float64(r.InitialVolume),
        Float64(r.Inflows), z == "ES" ? prof_inf_es : emp_inf_fr)
end
const RZ = sort(collect(keys(reservoirs)))            # ["ES","FR"]

# ── short-term storage (weekly-cycling, not states) ──────────
sts = [(zone = String(r.Zone), name = String(r.Name),
        pmax = Float64(r.MaxPower), vmax = Float64(r.MaxVolume),
        eta_t = Float64(r.TurbineEfficiency), eta_p = Float64(r.PumpingEfficiency),
        v0 = Float64(r.InitialVolume)) for r in eachrow(df_sts)]

# ── interconnections & demand ────────────────────────────────
lines = [(from = String(r.StartLine), to = String(r.EndLine),
          fmax = Float64(r.MaxPowerFlow), fmin = Float64(r.MinPowerFlow))
         for r in eachrow(df_in)]

# Diagnostic overrides (sensitivity runs): MIDTERM_NTC_<FROM><TO>=MW caps a
# line symmetrically; MIDTERM_SUFFIX relabels the output files.
for (li, l) in enumerate(lines)
    v = get(ENV, "MIDTERM_NTC_$(l.from)$(l.to)", "")
    isempty(v) && continue
    ntc = parse(Float64, v)
    lines[li] = (from = l.from, to = l.to, fmax = ntc, fmin = -ntc)
    println("  override: $(l.from)>$(l.to) NTC → ±$(ntc) MW")
end
SUFFIX = get(ENV, "MIDTERM_SUFFIX", "")
add_suffix(p) = isempty(SUFFIX) ? p : replace(p, r"\.(csv|json|log)$" => s -> "$(SUFFIX)$(s)")

demand_yr = Dict(String(r.Zone) => Float64(r.value) for r in eachrow(df_zv))
prof_load_z = Dict("ES" => prof_load, "FR" => emp_load["FR"], "PT" => emp_load["PT"])

# ── precompute stochastic data  [t][ω] ───────────────────────
println("Mid-term SDDP: $(N_STAGES) weekly stages × $(NB) blocks of $(BLOCK_HOURS) h, ",
        "$(NSCEN) climate-year scenarios ($(first(YEARS))–$(last(YEARS))), solver=$(SOLVER)")
println("  FR/PT shapes from Data/ts/EMPIRE (EU = rest-of-Europe → FR zone), ",
        "scenario years paired cyclically with EMPIRE $(first(EMP_YEARS))–$(last(EMP_YEARS))")
println(END_PENALTY > 0 ?
    @sprintf("  end-of-horizon target: %.0f%% of the initial volume, penalty %.0f EUR/MWh",
             100 * END_FILL, END_PENALTY) :
    "  end-of-horizon target: none (zero terminal value → reservoirs drained)")

# demand [MW], res availability [MW], reservoir inflow per block [MWh]
DEM  = Array{Float64}(undef, N_STAGES, NSCEN, length(ZONES), NB)
AVL  = Array{Float64}(undef, N_STAGES, NSCEN, length(res_units), NB)
INF  = Array{Float64}(undef, N_STAGES, NSCEN, length(RZ), NB)
for t in 1:N_STAGES, (w, y) in enumerate(YEARS)
    for (zi, z) in enumerate(ZONES), b in 1:NB
        DEM[t, w, zi, b] = demand_yr[z] * block_mean(prof_load_z[z], y, t, b)
    end
    for (ui, u) in enumerate(res_units), b in 1:NB
        m = block_mean(u.prof, y, t, b)
        AVL[t, w, ui, b] = u.kind == :cf ? u.cap * m : min(u.cap, u.annualE * m)
    end
    for (ri, rz) in enumerate(RZ), b in 1:NB
        r = reservoirs[rz]
        INF[t, w, ri, b] = r.inflow_yr * block_mean(r.prof, y, t, b) * BLOCK_HOURS
    end
end

# ── SDDP model ───────────────────────────────────────────────
zidx = Dict(z => i for (i, z) in enumerate(ZONES))

model = SDDP.LinearPolicyGraph(;
    stages = N_STAGES, sense = :Min, lower_bound = 0.0, optimizer = optimizer(),
) do sp, t
    Δh = BLOCK_HOURS
    # states: reservoir volumes [MWh]
    @variable(sp, reservoirs[r].vmin <= vres[r in RZ] <= reservoirs[r].vmax,
              SDDP.State, initial_value = reservoirs[r].v0)
    # intra-week reservoir trajectory (keeps volume feasible inside the week)
    @variable(sp, reservoirs[r].vmin <= vtraj[r in RZ, b in 0:NB] <= reservoirs[r].vmax)
    @variable(sp, 0 <= turb[r in RZ, 1:NB] <= reservoirs[r].pmax)     # MW
    @variable(sp, spill[RZ, 1:NB] >= 0)                               # MW
    @constraint(sp, [r in RZ], vtraj[r, 0] == vres[r].in)
    @constraint(sp, vdyn[r in RZ, b in 1:NB],
        vtraj[r, b] - vtraj[r, b-1] + Δh * (turb[r, b] + spill[r, b]) == 0.0)  # RHS ← inflow
    @constraint(sp, [r in RZ], vres[r].out == vtraj[r, NB])

    # thermal
    @variable(sp, 0 <= gth_b[i in 1:length(therm), 1:NB] <= therm[i].pmax)

    # renewables (upper bound set per scenario)
    @variable(sp, gres[u in 1:length(res_units), 1:NB] >= 0)

    # short-term storage
    ns = length(sts)
    @variable(sp, 0 <= sturb[j in 1:ns, 1:NB] <= sts[j].pmax)
    @variable(sp, 0 <= spump[j in 1:ns, 1:NB] <= abs(sts[j].pmax))
    @variable(sp, 0 <= svol[j in 1:ns, 0:NB] <= sts[j].vmax)
    @constraint(sp, [j in 1:ns], svol[j, 0] == sts[j].v0)
    @constraint(sp, [j in 1:ns, b in 1:NB],
        svol[j, b] == svol[j, b-1] + Δh * (sts[j].eta_p * spump[j, b] - sturb[j, b] / sts[j].eta_t))

    # interconnection flows (positive = from → to) and shedding
    @variable(sp, lines[l].fmin <= flow[l in 1:length(lines), 1:NB] <= lines[l].fmax)
    @variable(sp, shed[1:length(ZONES), 1:NB] >= 0)

    # zonal balance (demand on the RHS, set per scenario)
    @constraint(sp, bal[zi in 1:length(ZONES), b in 1:NB],
        sum(gth_b[i, b] for i in 1:length(therm) if zidx[therm[i].zone] == zi)
      + sum(gres[u, b]  for u in 1:length(res_units) if zidx[res_units[u].zone] == zi)
      + sum(turb[r, b]  for r in RZ if zidx[r] == zi)
      + sum(sturb[j, b] - spump[j, b] for j in 1:ns if zidx[sts[j].zone] == zi)
      + sum(flow[l, b] * (lines[l].to == ZONES[zi] ? 1 : lines[l].from == ZONES[zi] ? -1 : 0)
            for l in 1:length(lines))
      + shed[zi, b] == 0.0)                                            # RHS ← demand

    cost = BLOCK_HOURS * (
        sum(therm[i].cost * gth_b[i, b] for i in 1:length(therm), b in 1:NB)
      + VOLL * sum(shed))

    # Soft end-of-horizon target: penalise only the shortfall, so a dry final
    # week stays feasible instead of forcing load shedding to refill.
    if t == N_STAGES && END_PENALTY > 0
        @variable(sp, vdef[r in RZ] >= 0)                          # shortfall [MWh]
        @constraint(sp, [r in RZ],
            vres[r].out + vdef[r] >= END_FILL * reservoirs[r].v0)
        @stageobjective(sp, cost + END_PENALTY * sum(vdef[r] for r in RZ))
    else
        @stageobjective(sp, cost)
    end

    SDDP.parameterize(sp, 1:NSCEN) do w
        for zi in 1:length(ZONES), b in 1:NB
            set_normalized_rhs(bal[zi, b], DEM[t, w, zi, b])
        end
        for u in 1:length(res_units), b in 1:NB
            set_upper_bound(gres[u, b], AVL[t, w, u, b])
        end
        for (ri, r) in enumerate(RZ), b in 1:NB
            set_normalized_rhs(vdyn[r, b], INF[t, w, ri, b])
        end
    end
end

# ── resim mode: reload cuts and dump zonal diagnostics ───────
# `julia --project=. midterm_sddp.jl resim` skips training, loads the cuts of
# the last run and writes per-block prices / flows / dispatch of simulated
# policies to results/midterm_diag.csv (for validating the trained policy).
if "resim" in ARGS
    SDDP.read_cuts_from_file(model, add_suffix(joinpath(@__DIR__, "results", "midterm_cuts.json")))
    iES  = [i for i in 1:length(therm) if therm[i].zone == "ES"]
    coal = [i for i in iES if occursin("coal", lowercase(therm[i].name))]
    peak = [i for i in iES if therm[i].cost > 100.0]            # gas/oil/diesel
    nuc  = [i for i in iES if occursin("nuclear", lowercase(therm[i].name))]
    lFR  = findfirst(l -> Set([lines[l].from, lines[l].to]) == Set(["ES", "FR"]), 1:length(lines))
    lPT  = findfirst(l -> Set([lines[l].from, lines[l].to]) == Set(["ES", "PT"]), 1:length(lines))
    esr  = [u for u in 1:length(res_units) if res_units[u].zone == "ES"]
    rec = Dict{Symbol,Function}(
        :price => sp -> [JuMP.dual(sp[:bal][zi, b]) for zi in 1:3, b in 1:NB],
        :fFR   => sp -> [JuMP.value(sp[:flow][lFR, b]) for b in 1:NB],
        :fPT   => sp -> [JuMP.value(sp[:flow][lPT, b]) for b in 1:NB],
        :coal  => sp -> [sum(JuMP.value(sp[:gth_b][i, b]) for i in coal) for b in 1:NB],
        :peak  => sp -> [sum(JuMP.value(sp[:gth_b][i, b]) for i in peak) for b in 1:NB],
        :nuc   => sp -> [sum(JuMP.value(sp[:gth_b][i, b]) for i in nuc)  for b in 1:NB],
        :res   => sp -> [sum(JuMP.value(sp[:gres][u, b])  for u in esr)  for b in 1:NB],
        :turb  => sp -> [JuMP.value(sp[:turb]["ES", b]) for b in 1:NB],
        :shed  => sp -> [JuMP.value(sp[:shed][1, b]) for b in 1:NB],
        :dem   => sp -> [normalized_rhs(sp[:bal][1, b]) for b in 1:NB])
    nrep = 20
    dsims = SDDP.simulate(model, nrep, Symbol[]; custom_recorders = rec)
    diag = DataFrame(rep = Int[], t = Int[], b = Int[], pES = Float64[], pFR = Float64[],
                     pPT = Float64[], fFR = Float64[], fPT = Float64[], coal = Float64[],
                     peak = Float64[], nuc = Float64[], res = Float64[], turb = Float64[],
                     shed = Float64[], dem = Float64[])
    for (k, sim) in enumerate(dsims), (t, st) in enumerate(sim), b in 1:NB
        push!(diag, (k, t, b, st[:price][1, b], st[:price][2, b], st[:price][3, b],
                     st[:fFR][b], st[:fPT][b], st[:coal][b], st[:peak][b], st[:nuc][b],
                     st[:res][b], st[:turb][b], st[:shed][b], st[:dem][b]))
    end
    out_diag = add_suffix(joinpath(@__DIR__, "results", "midterm_diag.csv"))
    CSV.write(out_diag, diag)
    println("Wrote $(nrow(diag)) diagnostic rows ($nrep replications) → $out_diag")
    exit(0)
end

# ── train ────────────────────────────────────────────────────
log_file = add_suffix(joinpath(@__DIR__, "results", "midterm_sddp.log"))
SDDP.train(model; iteration_limit = ITERATIONS, log_file = log_file)
lb = SDDP.calculate_bound(model)
@printf "Training done: %d iterations, lower bound %.4e EUR\n" ITERATIONS lb

# ── export cuts in BellmanValuesOUT format ───────────────────
# Node t's cuts bound the expected cost of stages t+1..T as a function of node
# t's outgoing volumes — i.e. "Timestep t-1" in the SMS++ convention (cost-to-go
# at end of week t-1, 0-based).  The JSON intercept convention varies between
# SDDP.jl versions (absolute  θ ≥ b + a·x  vs relative to the sampled state
# θ ≥ b + a·(x − x̂)), so both are evaluated against SDDP.ValueFunction and the
# matching one is used.
cuts_json = add_suffix(joinpath(@__DIR__, "results", "midterm_cuts.json"))
SDDP.write_cuts_to_file(model, cuts_json)
nodes = JSON.parsefile(cuts_json)

key_fr, key_es = "vres[FR]", "vres[ES]"
raw = Dict{Int,Vector{Any}}(parse(Int, nd["node"]) => nd["single_cuts"] for nd in nodes)

b_abs(c) = c["intercept"]
b_rel(c) = c["intercept"] - sum(c["coefficients"][k] * c["state"][k]
                                for k in keys(c["coefficients"]))
maxcut(cuts, bfun, vfr, ves) =
    maximum(bfun(c) + c["coefficients"][key_fr] * vfr + c["coefficients"][key_es] * ves
            for c in cuts)

bfun = let t = 1, vfr = reservoirs["FR"].v0, ves = reservoirs["ES"].v0
    V    = SDDP.ValueFunction(model; node = t)
    vref = SDDP.evaluate(V, Dict(key_fr => vfr, key_es => ves))[1]
    da   = abs(vref - maxcut(raw[t], b_abs, vfr, ves))
    dr   = abs(vref - maxcut(raw[t], b_rel, vfr, ves))
    @printf "Cut intercept convention: |Δ| absolute %.3e, relative %.3e → using %s\n" da dr (da <= dr ? "absolute" : "relative")
    min(da, dr) > 1e-3 * max(abs(vref), 1.0) &&
        error("Neither cut-intercept convention matches SDDP.ValueFunction (ref $vref)")
    da <= dr ? b_abs : b_rel
end

out = DataFrame(Timestep = Int[], a_0 = Float64[], a_1 = Float64[], b = Float64[])
for (t, cuts) in raw
    t == N_STAGES && continue          # terminal node: written as the trivial row below
    for c in cuts
        push!(out, (t - 1, c["coefficients"][key_fr], c["coefficients"][key_es], bfun(c)))
    end
end
push!(out, (N_STAGES - 1, 0.0, 0.0, 0.0))       # trivial terminal cut, as in the SMS++ file
sort!(out, :Timestep)

CSV.write(add_suffix(CUTS_OUT), out)
println("Wrote $(nrow(out)) cuts → $(add_suffix(CUTS_OUT))")

# ── simulate the policy for the volume trajectory ────────────
w_sim = findfirst(==(SIM_YEAR), YEARS)
w_sim === nothing && error("sim_year $SIM_YEAR not among usable climate years $YEARS")
scheme = SDDP.Historical([(t, w_sim) for t in 1:N_STAGES])
recorders = Dict{Symbol,Function}(
    :vfr => sp -> JuMP.value.([sp[:vtraj]["FR", b] for b in 0:NB]),
    :ves => sp -> JuMP.value.([sp[:vtraj]["ES", b] for b in 0:NB]))
sims = SDDP.simulate(model, 1, Symbol[]; sampling_scheme = scheme,
                     custom_recorders = recorders)

# hourly volumes by linear interpolation inside each block
nH = N_STAGES * 168
vol = DataFrame(Timestep = 0:nH,
                var"Hydro|Reservoir_FR_0" = zeros(nH + 1),
                var"Hydro|Reservoir_ES_0" = zeros(nH + 1),
                var"Hydro|Pumped Storage_ES_0" = zeros(nH + 1),
                var"Hydro|Pumped Storage_FR_0" = zeros(nH + 1),
                var"Battery|Lithium-Ion_FR_0"  = zeros(nH + 1),
                var"Battery|Lithium-Ion_PT_0"  = zeros(nH + 1))
for (t, stage) in enumerate(sims[1]), (col, key) in
        (("Hydro|Reservoir_FR_0", :vfr), ("Hydro|Reservoir_ES_0", :ves))
    v = stage[key]
    for b in 1:NB, j in 0:BLOCK_HOURS-1
        h = (t - 1) * 168 + (b - 1) * BLOCK_HOURS + j
        vol[h + 1, col] = v[b] + (v[b+1] - v[b]) * j / BLOCK_HOURS
    end
    t == N_STAGES && (vol[nH + 1, col] = v[NB + 1])
end
CSV.write(add_suffix(VOLUME_OUT), vol)
println("Wrote volume trajectory (climate year $SIM_YEAR) → $(add_suffix(VOLUME_OUT))")
println("\nTo use these cuts in the market chain, point [bellman] in config.toml at:")
println("  bellman_file = \"$(mcfg["cuts_out"])\"")
println("  volume_file  = \"$(mcfg["volume_out"])\"")
