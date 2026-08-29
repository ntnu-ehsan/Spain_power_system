# NECP 2035: country-total border redistribution at +400% inter-NUTS3

This package preserves the controlled 336-hour DC diagnostic with Spanish
intra-NUTS3 branches at 10.0x, Spanish inter-NUTS3 branches at 5.0x (+400%),
and physical international branches fixed at 1.0x. The total DA exchange with
France and Portugal remains an exact hard constraint in every redispatch hour,
but its allocation among each country's boundary buses may change within the
physical bus capacities.

The allocation is sign-consistent: an importing country cannot simultaneously
export at another boundary bus, and vice versa. A small quadratic penalty keeps
the allocation near the DA rating-proportional shares unless network feasibility
requires movement. The same deterministic 336-hour sample was used in all
comparison cases.

## Result

The country-total split solved 125 of 336 hours, compared with 116 under fixed
DA bus shares. All 116 previously feasible hours remained feasible and nine
additional hours were recovered; only two of those nine were free of load
shedding. Successful hours without material shedding increased from 108 to 118,
and shedding in solved hours decreased from 4,341.5 to 4,049.4 MWh. A further
211 hours remained unsuccessful (206 infeasible and five numerical errors).

The audit contains 1,125 bus rows for 125 solved hours. The maximum country-total
difference calculated from the rounded CSV is 0.003 MW, while the model equality
is exact. No sign violation occurred. A total of 287 bus-hour allocations moved
by more than 0.01 MW, with a maximum individual reallocation of 3,235.44 MW.
The DA `xb_flows.csv` is byte-identical to both earlier +400% cases, confirming
that the market exchange itself did not change.

Ten of the 15 fixed international physical branches reached 100% in solved
hours, together with `NEWES_ES412_ES416` at its 5.0x Spanish inter-NUTS3 limit.
No intra-NUTS3 branch reached its 10x diagnostic limit; its solved-hour maximum
was 25.1%.

## Interpretation

Fixed proportional DA bus shares explain only a small part of the feasibility
gap. Allowing physically bounded, same-direction redistribution recovered nine
hours, but it did not make the unchanged DA exchanges deliverable through the
fixed international network. The optimizer instead used ten international
branches up to their limits in the subset of hours it could solve.

No intrazonal reinforcement list is valid from this run because 211 hours lack
a feasible flow solution. The next controlled test should keep international
capacity at 1.0x and the country-total split enabled, but replace the static DA
exchange bounds with hourly network-based NTCs. This will test whether lowering
DA exchange to nodally deliverable levels removes the remaining infeasibility
without international reinforcement.

## Preserved files

- `summary.csv`: all 336 hourly statuses and adequacy outcomes.
- `branch_peaks.csv`: solved-hour peak loading for every branch.
- `binding_branches.csv`: ten international and one inter-NUTS3 binding branch.
- `xb_redispatch.csv`: DA shares and redispatched boundary-bus allocations.
- `xb_flows.csv`: unchanged DA country exchanges and zonal prices.
- `recovered_hours.csv`: the nine hours recovered relative to fixed bus shares.
- `sample_weeks.csv`: exact temporal sample.
- `run_config.toml`: exact run configuration.
- `metrics.csv`: comparison with fixed shares and doubled international ratings.
