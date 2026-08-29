# NECP 2035: 400% inter-NUTS3 reinforcement sensitivity

This package preserves the run with 400% additional Spanish inter-NUTS3
capacity, represented by a 5.0x multiplier on the EMPIRE-mapped operational
limits. International links remained fixed at 1.0, and same-NUTS3 Spanish
branches retained the 10x diagnostic multiplier. The same 336-hour sample and
market settings were used in all five sensitivities.

## Result

The +400% case solved 116 of 336 hours: exactly the same successful-hour set as
the +200% case. Successful hours without material load shedding increased by
one, from 107 to 108, because shedding changed within an already feasible hour;
no failed hour became feasible. Load shedding in solved hours fell from 5,475.5
to 4,341.5 MWh.

No Spanish inter-NUTS3 branch reached its enlarged limit. The maximum was 95.5%
of the 5.0x limit. The only transmission assets at 100% were the two fixed
international links: `LTGES1027` (FR--ES212) and `NEWXB_ES220_FR`
(ES220--FR).

## Interpretation

The domestic inter-NUTS3 thermal constraint has been removed as an explanation
for the feasibility plateau in the successfully solved hours, yet 220 of 336
hours still fail. Therefore, uniform domestic corridor expansion alone cannot
resolve the chain. The next diagnostic should separate the fixed international
limits from non-transmission mechanisms such as frozen generation, islanded
network pockets, and incompatibility between the copper-plate schedule and the
redispatch degrees of freedom.

This does not prove that the two saturated international links cause all 220
failures; branch-loading data do not exist for failed hours. A controlled run
that relaxes only international links is needed to test that hypothesis.

## Preserved files

- `summary.csv`: all 336 hourly statuses and adequacy outcomes.
- `branch_peaks.csv`: solved-hour peak loading and capacity policy per branch.
- `binding_branches.csv`: the two fixed international assets at 100%.
- `sample_weeks.csv`: exact temporal sample.
- `run_config.toml`: exact run configuration.
- `metrics.csv`: five-case comparison.
