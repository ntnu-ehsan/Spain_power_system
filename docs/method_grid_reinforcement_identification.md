# Method — Identifying Transmission Reinforcements from an Infeasible AC OPF

A reusable workflow for turning an **infeasible AC OPF redispatch** into a **ranked, sized list of
lines to expand**. Developed 2026-07-07 on the EMPIRE 2035 NECPEssentials coupling (see
`results/NECPEssentials/feasibility_findings.md`), but applies to any scenario where a future
generation/demand portfolio is run on an existing network.

## When to use it
The market/energy stages clear, but the AC OPF (redispatch) reports `LOCALLY_INFEASIBLE` /
"converged to a point of local infeasibility" on some or all hours. You want to know **whether the grid
is the wall** and, if so, **which corridors to reinforce and by how much**.

## Steps

### 1. Confirm it's network-bound, not a setup bug
Relax the network limits generously in one run — raise `line_rating_factor` (thermal headroom over
nominal) and `voltage_band` — and re-solve.
- Feasibility jumps (e.g. 0/48 → 36/48) ⇒ network-capacity-bound, continue.
- Still 0/48 even wide-open ⇒ a structural/modelling problem (fixed injections, frozen units, data);
  diagnose that instead.

### 2. Isolate thermal vs. voltage — change ONE dimension at a time
Relax only the voltage side (e.g. `gen_bus_vmax` 1.03 → 1.08, or `gen_bus_voltage_control = false`).
- **Zero change in feasible-hour count ⇒ not voltage-bound.** (This is the decisive test — a real
  voltage limit would recover at least one hour.)
- If it helps, the residual is reactive/voltage; pursue reactive support (reactors, gen Q-limits)
  instead of thermal ratings.

Also read *which* hours fail: clustering at **low-load hours** with **low congestion counts** points to
a few long-distance export corridors (e.g. remote hydro/wind to load centres), not broad overload.

### 3. Solve fully feasible and UNCONGESTED to get the natural flow pattern
Raise `line_rating_factor` high enough that every hour solves with **no binding lines** (e.g. 4× gave
48/48, congestion 0). This over-rated solve reveals where power *wants* to flow, unconstrained.

### 4. Back out each line's required rating factor
In the solver output, `limit_mw = line_rating_factor × nominal_rating`, and
`loading_pct = 100 · |flow| / limit_mw`. Therefore the minimum rating factor a line needs is:

```
req_factor(line) = max_over_hours( loading_pct ) × LRF_used / 100
```

(`LRF_used` = the high factor from step 3, e.g. 4.0.) Equivalently `req_factor = peak(|flow|)/nominal`.

### 5. Rank and size
- **System-minimum feasible `line_rating_factor` = max over all lines of `req_factor`** — set by the
  single worst corridor. (Sanity-check against the sweep: it must lie between the last infeasible and
  first feasible factor tested.)
- Reinforcement candidates = lines with `req_factor` above the current operating factor; rank
  descending. Count how many exceed 1.0× (nominal), 1.5×, 2.0× to show whether the need is targeted or
  systemic.

### 6. Validate
Re-run at (or just above) the system-minimum factor and confirm full feasibility. Because flows
**redistribute as limits bind**, the step-4 estimate from the uncongested solve is *first-order* — the
validation run is what confirms the sized list.

## Reference implementation (pandas)
```python
LRF_USED = 4.0                                   # the over-rated, uncongested solve
b = pd.read_csv('results/<scenario>/branch_flows.csv')   # date,hour,branch_id,branch_name,...,loading_pct
req = (b.groupby(['branch_id', 'branch_name'])
         .agg(peak_load_pct=('loading_pct', 'max')).reset_index())
req['req_factor'] = req['peak_load_pct'] * LRF_USED / 100.0
req = req.sort_values('req_factor', ascending=False)
system_min = req['req_factor'].max()             # min line_rating_factor for full feasibility
for t in (0.8, 1.0, 1.5, 2.0, 3.0):
    print(f'branches needing > {t}x:', int((req.req_factor > t).sum()))
```
Map it: draw branches (endpoints are 1-based bus indices into `Data/Bus_Data.csv`, x=lon/y=lat) colored
by `req_factor` — see the reinforcement-map cell in `results_plots_2035.ipynb`.

## Caveats
- First-order: uncongested flows differ from constrained flows; always validate (step 6).
- Assumes symmetric thermal limits and that curtailment/redispatch freedom is the same across the sweep.
- Only meaningful once step 2 has confirmed the binding mechanism is thermal.
