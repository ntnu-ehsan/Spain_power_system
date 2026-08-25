# NECP 2035: 50% inter-NUTS3 reinforcement sensitivity

This package preserves the sensitivity requested after the fixed-interzonal
diagnostic in `../necp_2035_selective_reinforcement_2w/`.

The same 336 hours and market-chain settings were used. Same-NUTS3 Spanish
branches retained the 10x diagnostic multiplier. Spanish inter-NUTS3 branches,
including `NEWES_*` corridors, were allowed 50% more thermal capacity than the
EMPIRE-mapped operational limit (`diagnostic_inter_nuts_multiplier = 1.5`).
International branches remained fixed.

## Result

The allowance increased solver-successful hours from 112 to 115 of 336. All
three newly solved hours required large load shedding (1.15--1.56 GW), and the
allowance also changed shedding within hours that already solved in the
baseline. Consequently, the number of successful hours without material load
shedding improved by only one, from 105 to 106. Total load shedding in solved
hours increased from 5,368.6 to 6,455.5 MWh.

Five Spanish inter-NUTS3 assets still reached their enlarged 1.5x limits:

- `LTGES0193` (ES414--ES412)
- `LTGES0254` (ES522--ES532)
- `LTGES0589` (ES220--ES243)
- `LTGES0668` (ES423--ES300)
- `NEWES_ES412_ES416` (ES412--ES416)

Two fixed international assets also remained at 100%: `LTGES1027` (FR--ES212)
and `NEWXB_ES220_FR` (ES220--FR).

The change from 77 numerical errors to 15, accompanied by an increase from 147
to 206 explicit infeasibility reports, should not be interpreted as a physical
worsening. It mainly indicates that the solver classified more failed hours
decisively. The robust comparison is solver success (112 versus 115) and
success without load shedding (105 versus 106).

## Interpretation

A uniform 50% addition to all Spanish inter-NUTS3 limits is insufficient to
restore nodal feasibility for this sample. It relieves eleven of the sixteen
previously binding inter-NUTS3 branches, but the remaining five corridors and
two fixed international links continue to constrain the physical solution.
The result supports targeted corridor analysis rather than applying a uniform
percentage to every interzonal asset.

## Preserved files

- `summary.csv`: all 336 hourly statuses and adequacy outcomes.
- `branch_peaks.csv`: solved-hour peak loading and capacity policy per branch.
- `sample_weeks.csv`: exact temporal sample, identical to the baseline.
- `run_config.toml`: exact run configuration.
- `metrics.csv`: direct baseline-versus-sensitivity comparison.
