# NECP 2035: hourly NTC, DA-to-redispatch diagnostic

This evidence bundle records the two-week (336-hour) DC diagnostic run completed
on 2026-08-29.  Intraday ID2, ID3, CID, and balancing were bypassed: the
day-ahead schedule and DA load/VRE profiles feed redispatch directly.

## Configuration

- Scenario: `NECPEssentials`, EMPIRE period 2 (2035)
- Sample: the same two non-contiguous diagnostic weeks used by the preceding
  static-NTC sensitivities (`Data/sample_weeks_diag_2w.csv`)
- Redispatch: DC, diagnostic output, DA anchor, country-total cross-border split
- Base line rating factor: 0.80
- Intra-NUTS3 diagnostic multiplier: 10.0
- Inter-NUTS3 diagnostic multiplier: 5.0 (+400%)
- International diagnostic multiplier: 1.0 (physical ratings fixed)
- Hourly coordinated NTC: enabled, fresh calculation, reliability margin 0.70
- Hourly NTC boundary distribution: sign-consistent free bus allocation with
  the FR and PT country totals fixed

## Result

- Redispatch solved: 336/336 hours (335 `OPTIMAL`, one `LOCALLY_SOLVED`)
- Load shedding: 0.0 MWh
- Maximum country-total exchange error after redispatch: 0.002 MW
- Bus-level border allocations moved in 1,032 bus-hours; maximum movement from
  the rating-proportional DA share was 444.427 MW
- The zero-exchange NTC reference used no emergency generation in any hour
- The coordinated FR/PT corner reduced at least one independent directional
  bound slightly in every hour (`joint_scale` 0.990--1.000)
- DA exchange bound binding: FR in 266 hours, PT in 1 hour (either in 266 hours)
- Only two branches reached 100% in their recorded peak hour, both international:
  `LTGES0177` and `LTGES1027`

Directional NTC ranges after the 0.70 reliability margin:

| Direction | Minimum MW | Mean MW | Maximum MW |
|---|---:|---:|---:|
| FR import to ES | 3,643.41 | 3,832.97 | 3,941.97 |
| ES export to FR | 4,781.84 | 4,847.17 | 4,903.02 |
| PT import to ES | 7,239.97 | 7,267.72 | 7,285.66 |
| ES export to PT | 7,263.13 | 7,275.14 | 7,280.13 |

## Comparison with the static-NTC run

The otherwise comparable static-NTC, country-total-split run solved only
125/336 hours: 206 were infeasible and 5 ended with a numerical error. It used
4,049.4 MWh of diagnostic load shedding. The hourly network-derived NTC run
solved all 336 hours with zero shedding while leaving international physical
ratings unchanged.

This strongly supports the interpretation that the earlier failures were caused
primarily by a market/grid seam: independent static commercial exchange limits
admitted DA schedules that the detailed nodal network could not deliver. It does
not prove that a 0.70 margin is optimal, nor does it replace AC or N-1 validation.
The result is a DC feasibility diagnostic with highly reinforced Spanish lines.

## Files

- `run_config.toml`: exact configuration used
- `hourly_ntc.csv`: network-derived directional limits and reference diagnostics
- `xb_flows.csv`: DA exchange, active limits, and zonal prices
- `xb_redispatch.csv`: fixed country totals and optimized border-bus allocation
- `summary.csv`: hourly redispatch status, balance, and load shedding
- `branch_peaks.csv`: one peak-loading observation per physical branch
- `binding_branches.csv`: branches whose recorded peak reached 100%
- `comparison.csv`: compact static-versus-hourly NTC result comparison
