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
#
# anchor : previous gate's schedule for the TRADABLE hours (net-idx ⇒ unit ⇒ MW).
#          When given, the gate is solved as an *adjustment* market: dispatch cost
#          is minimised first (cheapest units / merit order, exactly as the DA),
#          then — among all cost-optimal solutions — the total movement away from
#          the previous gate is minimised.  This removes the cost-degenerate
#          reshuffles (reservoir water reallocation, LP degeneracy) that otherwise
#          let flexible units drift in opposite directions, while leaving any
#          genuine merit-order change intact.  `nothing` ⇒ plain cost re-clear.
function solve_da(nets, reservoir_gen_ids::Vector{Int}, cuts, v_es_0::Float64, optimizer;
                  free_hours::Union{Nothing,Set{Int}} = nothing,
                  prev_sched::Union{Nothing,Dict{Int,Dict{String,Float64}}} = nothing,
                  anchor::Union{Nothing,Dict{Int,Dict{String,Float64}}} = nothing)
    H     = length(nets)
    # Net indices (1-based) whose generation is tradable at this gate.  Hours not
    # in `free` are frozen at the previous gate's schedule (`prev_sched`, MW): they
    # carry NO power-balance constraint (their forecast error is left to a later
    # gate) but still consume their share of the reservoir, so the Bellman cost-to-
    # go only reallocates the water remaining after the frozen hours.
    free  = free_hours === nothing ? Set(1:H) : free_hours
    model = JuMP.Model(optimizer)

    # Per-hour, per-generator active power [pu].  Bounds and starts come straight
    # from the assembled network (fixed cross-border imports carry pmin == pmax,
    # so they enter the balance as a constant supply term automatically).
    pg = Dict{Tuple{Int,String},JuMP.VariableRef}()
    for h in 1:H
        frozen = !(h in free)
        ps     = (frozen && prev_sched !== nothing) ? get(prev_sched, h, nothing) : nothing
        for (k, g) in nets[h].gens
            v = JuMP.@variable(model, lower_bound = g["pmin"], upper_bound = g["pmax"])
            JuMP.set_start_value(v, g["pg"])
            pg[(h, k)] = v
            if frozen
                mw     = ps === nothing ? nothing : get(ps, g["name"], nothing)
                fixval = mw === nothing ? g["pg"] : mw / BASEMVA
                JuMP.fix(v, fixval; force = true)
            end
        end
    end

    # System-wide power balance per hour (copper plate): Σ generation == Σ load.
    # Frozen hours are carried verbatim from the previous gate (no re-balancing).
    for h in 1:H
        h in free || continue
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

    # ── Li-Ion BESS: intra-day SOC window ([scenario] only) ────────────────────
    # Battery units carry pmin = −pmax (negative pg ⇒ charging).  Starting from
    # half-full, the running state of charge  soc_h = soc0 − Σ_{j≤h} pg_j  must
    # stay inside [0, E] and return to soc0 at end of day (energy-neutral, so the
    # battery only shifts energy within the day).  Lossless in this LP — the
    # round-trip loss is second order at the fleet sizes EMPIRE builds.  Frozen
    # hours participate through their fixed pg, so rolling CID gates cannot
    # reallocate energy backwards in time.
    for (k, g) in nets[1].gens
        g["fuel"] == "Battery" || continue
        e_puh = g["energy_mwh"] / BASEMVA
        soc0  = 0.5 * e_puh
        for h in 1:H
            JuMP.@constraint(model, 0.0 <= soc0 - sum(pg[(j, k)] for j in 1:h) <= e_puh)
        end
        JuMP.@constraint(model, sum(pg[(j, k)] for j in 1:H) == 0.0)
    end

    # Primary objective: linear generation cost (reservoir cost is 0 here) + future
    # cost.  This sets the merit order and therefore which units clear.
    op = JuMP.AffExpr(0.0)
    for h in 1:H, (k, g) in nets[h].gens
        JuMP.add_to_expression!(op, g["cost"][1], pg[(h, k)])
    end
    cost_expr = op + θ_future

    # ── Minimum-movement anchor (intraday gates only) ─────────────────────────
    # For every tradable-hour unit that has a previous-gate set-point, add L1
    # deviation variables d_up/d_down with  pg − p_prev = d_up − d_down.  Their
    # sum is the secondary objective; the lexicographic solve below holds the
    # dispatch cost at its optimum first, so the cheapest units are still used.
    move_expr  = JuMP.AffExpr(0.0)
    has_anchor = anchor !== nothing && any(!isempty(v) for v in values(anchor))
    if has_anchor
        for h in 1:H
            h in free || continue
            ap = get(anchor, h, nothing)
            ap === nothing && continue
            for (k, g) in nets[h].gens
                mw = get(ap, g["name"], nothing)
                mw === nothing && continue
                p_ref = mw / BASEMVA
                du = JuMP.@variable(model, lower_bound = 0.0)
                dd = JuMP.@variable(model, lower_bound = 0.0)
                JuMP.@constraint(model, pg[(h, k)] - p_ref == du - dd)
                JuMP.add_to_expression!(move_expr, du)
                JuMP.add_to_expression!(move_expr, dd)
            end
        end
    end

    JuMP.@objective(model, Min, cost_expr)
    JuMP.optimize!(model)
    status = string(JuMP.termination_status(model))

    # Lexicographic pass 2: pin the dispatch cost at its optimum (within a tiny
    # tolerance so the merit order is preserved), then minimise total movement
    # from the previous gate.  Among cost-equal solutions this picks the one
    # closest to the previous schedule, so flexible units only move to cover the
    # net load/RES change — and in a single direction.
    if has_anchor && status in ("OPTIMAL", "LOCALLY_SOLVED")
        c_star   = JuMP.objective_value(model)
        cost_tol = 1e-6 * abs(c_star) + 1e-3
        JuMP.@constraint(model, cost_expr <= c_star + cost_tol)
        JuMP.@objective(model, Min, move_expr)
        JuMP.optimize!(model)
        status = string(JuMP.termination_status(model))
    end

    sched = Dict{Int,Dict{String,Float64}}()
    objval = NaN
    if status in ("OPTIMAL", "LOCALLY_SOLVED")
        # Always report the dispatch cost, even after the pass-2 movement solve.
        objval = JuMP.value(cost_expr)
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
