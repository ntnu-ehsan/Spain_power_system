# NECP 2035: 200% inter-NUTS3 reinforcement sensitivity

This package preserves the run with 200% additional Spanish inter-NUTS3
capacity, represented by a 3.0x multiplier on the EMPIRE-mapped operational
limits. International links remained fixed at 1.0, and same-NUTS3 Spanish
branches retained the 10x diagnostic multiplier. The same 336-hour sample and
market settings were used in all four sensitivities.

## Result

The +200% case solved 116 of 336 hours, one more than both the +50% and +100%
cases. The newly solved hour required 1,181.5 MW of load shedding, however, so
successful hours without material shedding remained unchanged at 107. Relative
to the fixed-interzonal case, no-shedding success increased by only two hours
(105 to 107).

Only one Spanish inter-NUTS3 asset still reached its tripled limit:
`NEWES_ES412_ES416` (ES412--ES416). The same two fixed international assets
also remained at 100%: `LTGES1027` (FR--ES212) and `NEWXB_ES220_FR`
(ES220--FR).

## Interpretation

Increasing the uniform domestic inter-NUTS3 allowance from +100% to +200%
does not improve no-shedding feasibility. The result has reached a practical
plateau: almost all enlarged domestic corridors cease to bind, but 220 hours
still fail and two international links remain saturated. This makes another
uniform increase to every domestic corridor difficult to justify as the next
diagnostic.

The persistent `NEWES_ES412_ES416` constraint merits a targeted sensitivity.
Separately, the international links and operational restrictions should be
tested to determine which constraint family explains the feasibility plateau.

## Preserved files

- `summary.csv`: all 336 hourly statuses and adequacy outcomes.
- `branch_peaks.csv`: solved-hour peak loading and capacity policy per branch.
- `binding_branches.csv`: the tripled inter-NUTS3 and fixed international
  assets that reached 100%.
- `sample_weeks.csv`: exact temporal sample.
- `run_config.toml`: exact run configuration.
- `metrics.csv`: four-case comparison.
