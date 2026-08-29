# NECP 2035: +100% international diagnostic at +400% Spanish inter-NUTS3

This package preserves the controlled two-week DC diagnostic with physical
branch-rating multipliers of 10.0x for Spanish intra-NUTS3 branches, 5.0x
(+400%) for Spanish inter-NUTS3 branches, and 2.0x (+100%) for international
branches. The base security rating factor remained 0.8. The deterministic
336-hour sample is byte-identical to the earlier sensitivity runs.

The international multiplier changes only the physical border-branch ratings.
The market-chain exchange targets remained hard-fixed, and the run passed its
fixed-exchange validation for all 336 hours. This is therefore a diagnostic of
the nodal representation of the border interface, not a market run with larger
commercial exchange volumes.

## Result

All 336 hourly redispatch problems solved (322 `OPTIMAL`, 14
`LOCALLY_SOLVED`) with zero load shedding. Relative to the otherwise identical
international-fixed +400% Spanish inter-NUTS3 case, feasibility increased from
116 to 336 hours: all 220 previously failed hours were recovered. Load shedding
fell from 4,341.5 MWh to zero.

Two non-candidate corridors reached their diagnostic limits:

- `LTGES1027` (FR--ES212) reached 100% of its doubled 2,859.96 MW limit.
- `NEWES_ES412_ES416` reached 100% of its 5.0x 754.19 MW limit.

The maximum loading among the 1,997 intra-NUTS3 candidates was 34.8% of the
10x diagnostic limit, so the intrazonal network was uncongested at that probe
level.

## Conditional intrazonal reinforcement estimate

Because every hour solved without shedding, the run supports a first-order
intrazonal sizing list conditional on the 5.0x Spanish inter-NUTS3 and 2.0x
international allowances. Eighty intrazonal branches require an absolute
thermal rating above the normal 0.8-of-nameplate usable limit; 46 require more
than nameplate, 11 more than 1.5x nameplate, and five more than 2.0x nameplate.
The largest required absolute factor is 2.784, on `LTGES1367`, `LTGES1433`, and
`LTGES1368`. Equivalently, an uncongested uniform intrazonal diagnostic needs a
minimum multiplier of 3.48 relative to the normal 0.8 usable limit.

`reinforcement.csv` stores `factor` as the absolute required rating divided by
nameplate. The model loader performs the security-margin conversion once. This
corrects an extractor error that previously divided by 0.8 a second time and
would have overstated every proposed uprate by 25%.

## Interpretation and limitation

The complete recovery demonstrates that the fixed physical international
interface was the decisive cause of the previous feasibility plateau under
this configuration. It does not establish that doubling international capacity
is the required or policy-appropriate investment. One international and one
Spanish inter-NUTS3 branch remain binding, and the intrazonal sizing list is
conditional on these deliberately generous corridor allowances. The next
diagnostic should bracket the minimum international multiplier and then validate
the targeted intrazonal list under the selected corridor policy.

## Preserved files

- `summary.csv`: all 336 hourly statuses and adequacy outcomes.
- `branch_peaks.csv`: peak loading and capacity policy for every branch.
- `binding_branches.csv`: the two branches at 100%.
- `reinforcement.csv`: 80 conditional intrazonal candidates.
- `sample_weeks.csv`: exact temporal sample.
- `run_config.toml`: exact run configuration.
- `metrics.csv`: direct comparison with the international-fixed +400% case.
