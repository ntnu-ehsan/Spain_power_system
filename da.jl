# ============================================================
# Stage 1 — Day-Ahead market (copper-plate economic dispatch)
# ============================================================
# Clears energy for the whole day at once with NO transmission or
# voltage limits (a single system-wide power balance per hour).
# Reservoir hydro is coupled across all 24 hours through the full
# Bellman cost-to-go, exactly as in the multi-network AC build:
# the recentred cuts give reservoir units their opportunity cost so
# the intra-day hydro schedule respects the long-term water value.
#
# Inputs are the per-hour networks already assembled by
# prepare_network (so RES availability, cross-border imports, the
# slack unit and the load-shed units are all included as ordinary
# generators).  Reservoir units must carry zero linear cost in those
# networks (build them with hydro_reservoir_cost = 0.0); their cost
# comes from the θ_future term instead.
#
# Returns the cleared per-unit schedule keyed by hour, which becomes
# the reference the redispatch stage is anchored to:
#     sched :: Dict{Int, Dict{String,Float64}}   hour ⇒ (unit ⇒ MW)
# ============================================================

using JuMP

# nets               : Vector of prepare_network outputs, index h ⇒ hour (h-1)
# reservoir_gen_ids  : Int gen ids of Spanish reservoir hydro (stable across hours)
# cuts, v_es_0       : Bellman cuts and starting reservoir volume [MWh] for the day
function solve_da(nets, reservoir_gen_ids::Vector{Int}, cuts, v_es_0::Float64, optimizer)
    H     = length(nets)
    model = JuMP.Model(optimizer)

    # Per-hour, per-generator active power [pu].  Bounds and starts come straight
    # from the assembled network (fixed cross-border imports carry pmin == pmax,
    # so they enter the balance as a constant supply term automatically).
    pg = Dict{Tuple{Int,String},JuMP.VariableRef}()
    for h in 1:H
        for (k, g) in nets[h].gens
            v = JuMP.@variable(model, lower_bound = g["pmin"], upper_bound = g["pmax"])
            JuMP.set_start_value(v, g["pg"])
            pg[(h, k)] = v
        end
    end

    # System-wide power balance per hour (copper plate): Σ generation == Σ load.
    for h in 1:H
        load_pu = sum(l["pd"] for l in values(nets[h].loads); init = 0.0)
        JuMP.@constraint(model, sum(pg[(h, k)] for k in keys(nets[h].gens)) == load_pu)
    end

    # ── Reservoir hydro coupled across the day via the Bellman cost-to-go ──────
    # Mirrors build_mn_bellman in run_opf.jl: energy is carried in pu·h so the
    # volume variables sit at the same scale as pg, the cuts are recentred about
    # the starting volume v_es_0 (dropping the dispatch-independent constant), and
    # both auxiliary variables are lower-bounded with interior starts.
    v_es_0_puh = v_es_0 / BASEMVA
    total_hydro_puh = isempty(reservoir_gen_ids) ? JuMP.AffExpr(0.0) :
        sum(pg[(h, string(gid))] for h in 1:H for gid in reservoir_gen_ids)

    JuMP.@variable(model, V_ES_puh >= 0)   # reservoir volume at end of day [pu·h]
    JuMP.@variable(model, θ_future >= 0)   # future cost relative to its value at v_es_0 [EUR]
    JuMP.set_start_value(V_ES_puh, v_es_0_puh)
    JuMP.set_start_value(θ_future, 1.0e3)
    JuMP.@constraint(model, V_ES_puh == v_es_0_puh - total_hydro_puh)

    θ_ref = isempty(cuts) ? 0.0 : maximum(c.b + c.a1 * v_es_0 for c in cuts)
    for cut in cuts
        const_term = cut.b + cut.a1 * v_es_0 - θ_ref
        JuMP.@constraint(model,
            θ_future >= const_term + cut.a1 * BASEMVA * (V_ES_puh - v_es_0_puh))
    end

    # Objective: linear generation cost (reservoir cost is 0 here) + future cost.
    op = JuMP.AffExpr(0.0)
    for h in 1:H, (k, g) in nets[h].gens
        JuMP.add_to_expression!(op, g["cost"][1], pg[(h, k)])
    end
    JuMP.@objective(model, Min, op + θ_future)

    JuMP.optimize!(model)
    status = string(JuMP.termination_status(model))

    sched = Dict{Int,Dict{String,Float64}}()
    objval = NaN
    if status in ("OPTIMAL", "LOCALLY_SOLVED")
        objval = JuMP.objective_value(model)
        for h in 1:H
            d = Dict{String,Float64}()
            for (k, g) in nets[h].gens
                d[g["name"]] = JuMP.value(pg[(h, k)]) * BASEMVA
            end
            sched[h] = d
        end
    end
    return (sched = sched, status = status, objective = objval)
end
