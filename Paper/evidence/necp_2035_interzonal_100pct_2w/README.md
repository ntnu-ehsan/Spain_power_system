# NECP 2035: 100% inter-NUTS3 reinforcement sensitivity

This package preserves the run with Spanish inter-NUTS3 operational limits
doubled relative to the EMPIRE-mapped case (`diagnostic_inter_nuts_multiplier
= 2.0`). International links remained fixed at 1.0. Same-NUTS3 Spanish
branches retained the 10x diagnostic multiplier. The temporal sample and all
market settings are identical to the fixed and +50% cases.

## Result

Doubling inter-NUTS3 capacity did not add any solver-successful hours beyond
the +50% case: both solved the same 115 of 336 hours. Successful hours without
material load shedding increased from 106 to 107, and shedding in solved hours
fell from 6,455.5 to 5,485.6 MWh. Relative to the fixed-interzonal baseline,
no-shedding success is only two hours higher (107 versus 105).

Four Spanish inter-NUTS3 assets still reached their doubled limits:

- `LTGES0254` (ES522--ES532)
- `LTGES0589` (ES220--ES243)
- `LTGES0668` (ES423--ES300)
- `NEWES_ES412_ES416` (ES412--ES416)

The same two fixed international assets also remained at 100%: `LTGES1027`
(FR--ES212) and `NEWXB_ES220_FR` (ES220--FR).

## Interpretation

A uniform doubling of every Spanish inter-NUTS3 branch is still insufficient
to restore nodal feasibility. The lack of additional solver-successful hours
between +50% and +100% indicates that at least one other constraint family is
already limiting many hours. The two saturated international links are a
candidate, but this run alone does not establish causality; generator freezing,
copper-plate schedules, corridor mapping, and network islands must also be
checked.

The persistent four inter-NUTS3 limits support targeted corridor reinforcement
rather than another uniform system-wide multiplier.

## Preserved files

- `summary.csv`: all 336 hourly statuses and adequacy outcomes.
- `branch_peaks.csv`: solved-hour peak loading and capacity policy per branch.
- `binding_branches.csv`: four doubled inter-NUTS3 and two fixed international
  assets that reached 100%.
- `sample_weeks.csv`: exact sample, identical across all three cases.
- `run_config.toml`: exact run configuration.
- `metrics.csv`: fixed-versus-50%-versus-100% comparison.
