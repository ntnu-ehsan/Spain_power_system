# NECP 2035 selective reinforcement diagnostic

This directory preserves the compact evidence from the 336-hour DC diagnostic
run completed on 2026-08-25. The run used repository commit `5f2ef21` and the
NECPEssentials 2035 scenario.

## Experimental design

- Two non-contiguous sampled weeks (336 hours): 20--26 August 2024 using
  climate-year 2016 data, and 24--30 June 2025 using climate-year 2017 data.
- Normal branch derate: 0.80 of nameplate.
- Only Spanish branches with both endpoints in the same NUTS3 region were
  given a diagnostic thermal multiplier of 10.
- Inter-NUTS3 and international branches, including synthetic `NEWES_*` and
  `NEWXB_*` corridors, retained the capacities obtained from EMPIRE and their
  normal derate.
- Redispatch used a DC power-flow formulation and was anchored to the balancing
  schedule produced by the preceding market chain.

## Result

Only 112 of 336 hours solved successfully; 147 were reported infeasible and 77
ended with a numerical error after the infeasibility checks. Seven solved hours
contained load shedding, totalling 5,368.6 MWh.

Among branches for which a solved-hour peak was available, none of the 1,997
diagnostically relaxed intrazonal branches reached its diagnostic limit; their
maximum was 24.8% of the deliberately 10x limit. In contrast, 16 of 338 fixed
inter-NUTS3 branches and two of 15 fixed international branches reached 100%.
The synthetic EMPIRE corridor `NEWES_ES412_ES416` was correctly treated as
inter-NUTS3 and reached its fixed limit.

The 24.8% figure must not be described as utilization of the original grid. It
is utilization of an intentionally tenfold diagnostic limit and would
correspond to 248% of the normal derated limit if the same flow pattern held.
Moreover, peak statistics exist only for the 112 successfully solved hours.

## Interpretation for the paper

This experiment provides evidence of a **spatial-resolution gap**: the
aggregate corridor capacities selected by a transport-style investment model
did not guarantee a feasible branch-level DC operating point after being
mapped to the physical network, even when within-NUTS3 limits were made
effectively non-binding. It supports the methodological conclusion that zonal
transmission expansion results require nodal validation and may need feedback
from the nodal model.

It does not, by itself, prove that zonal TEP is generally inaccurate. The
result may also reflect the mapping of aggregate corridor capacity to physical
parallel branches, the 20% operating derate, synthetic-corridor placement, the
copper-plate market schedule, frozen redispatch decisions, or the sampled
weeks. These mechanisms should be separated before making a causal claim.

## Preserved files

- `summary.csv`: status and adequacy result for every requested hour.
- `branch_peaks.csv`: one peak-loading solved hour per branch, including NUTS3
  class and reinforcement eligibility.
- `sample_weeks.csv`: the exact temporal sample.
- `run_config.toml`: the exact generated configuration.
- `metrics.csv`: compact headline statistics used above.

The large IIS files and console logs are intentionally excluded; they remain
in the local run directory and can be regenerated with:

```bash
bash cluster/run_reinforcement_diag.sh NECPEssentials 10 2
```
