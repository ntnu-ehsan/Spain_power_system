# 2035 NECPEssentials — Market-Chain Feasibility on the 2024 Grid

**Date:** 2026-07-07
**Scenario:** OpenEMPIRE `NECPEssentials`, period 2 (2030–2035), `Data/2035/NECPEssentials`
**Model:** `run_opf.jl` market chain (DA → ID2 → ID3 → CID → Balancing → AC OPF redispatch), two
target days 2024-07-08 (summer) and 2024-12-02 (winter), 48 hourly AC OPFs.
**Bellman cuts:** `Data/BellmanValuesOUT_sddp4_NECPEssentials.csv` (in-house SDDP, 60 iters, bound
3.29e10, `numeric issues: 0`). **Outputs:** `results/NECPEssentials/`.

---

## Headline

The 2035 NECPEssentials fleet **clears every market stage** (DA/ID2/ID3/CID/Balancing all OPTIMAL,
valid ~28 €/MWh Iberian prices) but the **AC OPF redispatch is infeasible on the un-reinforced 2024
Spanish grid**. The infeasibility is **purely thermal** and can be resolved by reinforcing a **targeted
set of ~8 corridors to ~2.7× nominal** — not a system-wide upgrade. Voltage/reactive was ruled out.

## Root cause

`empire_scenario.jl` scales the **generation fleet**, **demand**, and **zonal NTCs** (ES/FR/PT/EU) to
2035, but leaves the **intra-Spain bus-level lines** at 2024 topology, derated to 80%
(`[network] line_rating_factor = 0.80`). So the AC OPF routes a 2035 operating point
(demand ~55 GW peak vs ~40 GW in 2024; solar ~59 GW at midday, exceeding load; concentrated on
today's solar/hydro buses scaled 2–3×) on the present internal grid. Line thermal limits (`rate_a`)
are hard inequalities with no slack, so the problem is infeasible. **EMPIRE did invest in transmission,
but the operational chain currently ingests only the *zonal* NTC reinforcements, not the *intra-Spain*
line reinforcements** — that is the coupling gap.

## Evidence — feasibility vs `line_rating_factor`

| `line_rating_factor` | `voltage_band` | Feasible hours | Congestion |
|---|---|---|---|
| 0.80 (baseline) | 0.05 | **0 / 48** | infeasible every hour |
| 2.0 | 0.10 | **36 / 48** | up to 11 lines at limit |
| 2.0, `gen_bus_vmax` 1.03→1.08 | 0.10 | **36 / 48** (identical) | — |
| 4.0 | 0.10 | **48 / 48** | 0 lines |

Key diagnostics:
- **Not voltage.** Raising the generator-bus voltage ceiling (`gen_bus_vmax` 1.03→1.08) had **zero
  effect** — same 36/48, same failing hours. If voltage were binding, it would have recovered hours.
- **Failures were the lowest-load hours** (summer h01–05, winter h00–06, load ~30 GW), not the midday
  RES peak. At those hours the mix is a flat **~11.6 GW northern hydro + ~10.6 GW wind** exporting south
  on corridors that 2× ratings can't carry. Midday solves because southern solar serves southern load
  locally.
- Failing-hour Ipopt logs show restoration → *"Converged to a point of local infeasibility"* with a
  small irreducible violation (~0.023 pu) — a modest thermal shortfall, not a gross overload.

## Quantified reinforcement need

From the feasible 4.0× solution (`results/NECPEssentials/branch_flows.csv`), each line's required
factor = `peak loading_pct × 4 / 100`:

- **System-minimum feasible `line_rating_factor` ≈ 2.73**, set by corridor **LTGES0690**. Consistent
  with the sweep (2.0 → 36/48 is below threshold; 4.0 → 48/48 is above).
- Targeted, not blanket — of **2345** branches:
  - **8** need > 2×
  - ~**50** need > 1.5×
  - **168** exceed nominal (> 1.0×)
  - **262** exceed the current 0.80 operating derate
  - **0** need > 3×

**Top binding corridors (min rating factor needed):**

| Branch | req. factor | peak loading @ 4× |
|---|---|---|
| LTGES0690 | 2.73 | 68.3 % |
| LTGES0691 | 2.39 | 59.7 % |
| LTGES1322 | 2.32 | 58.0 % |
| LTGES1133 | 2.05 | 51.3 % |
| LTGES0685a/b | 2.05 | 51.2 % |
| LTGES0333 | 2.05 | 51.2 % |
| LTGES1001 | 2.02 | 50.6 % |
| LTGES1021a/b | 1.98 | 49.5 % |
| LTGES0008 | 1.94 | 48.5 % |
| LTGES0755b | 1.93 | 48.3 % |

*Caveat:* first-order estimate — flows redistribute as limits bind, so ~2.73 is an approximate global
minimum. Validate with a run at `line_rating_factor ≈ 2.8` (expected 48/48).

## What is valid to use now

The **market-layer results are sound** (DA/ID2/ID3/CID/Balancing dispatch + prices in
`results/NECPEssentials/`). The **redispatch/network layer requires reinforcement** (or a raised rating
factor) to be feasible.

## Next steps

- **(A) Validate + usable dataset:** run `line_rating_factor ≈ 2.8` → clean 48/48 feasible 2035
  redispatch for plotting; confirms 2.73.
- **(B) Proper coupling fix:** ingest OpenEMPIRE's intra-Spain transmission reinforcements into
  bus-level `rate_a` in `empire_scenario.jl` / `data_preparation.jl`, mapping the req-factor list onto
  real corridor upgrades — the physically correct version of the uniform factor.
- **(C) Accept market-only** 2035 results.

## Update — refreshed NECPEssentials data (2026-07-07, evening)

Re-ran the whole pipeline (midterm retrain + resim + both market-chain runs) on a **new EMPIRE
NECPEssentials investment result** (the corrected data replacing the 13:34 copy; midterm bound rose
3.2948e10 → **3.5226e10**, +6.9%, confirming the new fleet loaded).

- **Baseline 0.80× still 0/48 infeasible** — the updated fleet is no more hostable on the 2024 grid
  (the coupling gap is unchanged).
- **4.0× still 48/48 feasible.**
- **Reinforcement need rose slightly and the binding corridor changed:**
  system-min `line_rating_factor` **2.73 → 2.99**, now set by **LTGES0333** (was LTGES0690).
  Of 2345 branches: **7** need > 2× (was 8), **54** need > 1.5× (was 50), **174** exceed nominal,
  **279** exceed the 0.80 derate.
  Top corridors: LTGES0333 2.99×, LTGES1133 2.98×, LTGES1001 2.72×, LTGES0690 2.66×, LTGES1322 2.40×,
  LTGES0691 2.35×, LTGES1428 2.01×, LTGES0685a 1.99×.

Numbers above (2.73, LTGES0690) are the *previous* data; the current `results/NECPEssentials/`
outputs and both notebooks now reflect the **new** data (2.99, LTGES0333).

## Config note

`config.toml [network]` is currently at TEST values: `line_rating_factor = 4.0`, `voltage_band = 0.10`
(`gen_bus_vmax` reverted to 1.03). **Restore `line_rating_factor = 0.80`, `voltage_band = 0.05` before
any 2024 baseline run.**
