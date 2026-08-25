# Running the 2035 chain on Solstorm

Everything here is a thin wrapper around the two scripts that already run on the
cluster — `midterm_sddp4.jl` and `run_opf.jl`. Nothing about the Julia
environment, Gurobi or Ipopt/HSL changes; only the settings the runs use.

## What is different from the version already on the cluster

| Setting | Was | Now | Why |
| ------- | --- | --- | --- |
| `[midterm4].end_penalty` | `150.0` | `0.0` | The end-of-horizon reservoir target printed an artificial −150 EUR/MWh ceiling onto the cut slopes (1.75 % of ES slopes sat exactly on it). Over 78 weekly stages the terminal effect only reaches back to week ~74, so the 52-week window the market chain uses is already clean without it. Verified on NECPEssentials and Trinity: the reservoir does not drain, and in Trinity the trajectory came out *fuller* (7 % of the year near empty against 15 % with the penalty). |
| `[redispatch].from_saved` | `"BAL"` | `""` | `"BAL"` skips market stages 1–5 and replays only the redispatch. Fine for tuning the OPF, but not a chain run. |
| `[redispatch].extra_line_scale_file` | Trinity's file for every scenario | per scenario | The reinforcement list was derived *for Trinity*; applying it elsewhere reinforces lines that scenario never overloaded. Only Trinity has one so far. |
| `Data/power_unit_tech_params.csv` | Gas CC ramp 100 %/h | 50 %/h | Changes CCGT unit staging in the day-ahead. Comes with `git pull`. |

`[weeks].enabled` stays **false**, matching the runs already in `results/<label>/`,
so this is a like-for-like re-verification. Turning it on switches to the sampled
multi-week horizon with the joint ES/PT/FR/EU day-ahead — a different experiment;
pass `--weeks=on` to `make_configs.jl` if that is what you want.

## Run it

```bash
git pull
julia --project=. cluster/make_configs.jl          # writes cluster/config_<label>.toml
nohup bash cluster/run_all.sh > cluster/run_all.log 2>&1 &
tail -f cluster/run_all.log
```

Runs are strictly sequential — each Julia process holds ~1.5 GB and one solver
thread, and two at once on one node gains nothing. Eight jobs: four scenarios ×
{midterm, chain}.

| Phase | Script | Per scenario | Writes |
| ----- | ------ | ------------ | ------ |
| `midterm` | `midterm_sddp4.jl` | ~40 min | `Data/{BellmanValuesOUT,Volume_Scen0_OUT,TurbineSchedule,ExchangeSchedule}_sddp4_<label>.csv` |
| `chain` | `run_opf.jl` | 1–3 h | `results/<label>/` |

The chain reads the cuts the midterm phase writes, so midterm runs first for each
scenario; if it fails, that scenario's chain is skipped rather than run on stale
cuts.

Subsets and re-runs:

```bash
SCENARIOS="GoRES REPowerEU++" bash cluster/run_all.sh
PHASES=midterm bash cluster/run_all.sh
FORCE=1 bash cluster/run_all.sh
```

**Resuming.** A phase is skipped only when its output is *newer than the config
that would produce it*. Regenerating the configs therefore invalidates every
previous result automatically — which matters here, because `results/<label>/`
and `Data/*_sddp4_<label>.csv` already hold output from the old settings, and a
plain existence check would silently skip the entire point of the run. A restart
after a crash still skips what this config already finished.

## Data

`git pull` carries the code and `Data/power_unit_tech_params.csv`. The bulk
EMPIRE data is tracked but has **uncommitted local modifications** (~516 MB
across 40 files the code reads — the `ScenarioData/*.csv` series plus
`genInstalledCap.tab`, `marginal_costs.csv`, `transmissionInstalledCap.tab` and
the storage tabs), and `Data/ES/{load,Solar,Wind Onshore}` is not tracked at all
(1 083 files, 4.8 MB).

Rather than guess which copy is current, compare them:

```bash
bash cluster/check_data.sh > local.txt      # on the workstation
bash cluster/check_data.sh > cluster.txt    # on Solstorm
diff local.txt cluster.txt
```

Every differing line is a file to re-copy; `MISSING` means the run will fail
there rather than merely use stale input. `QUICK=1` compares size instead of
md5 — seconds instead of minutes.

## Selective DC reinforcement diagnostic

This is separate from `run_all.sh`. Run it inside an allocated cluster node
(or call it from the site's sbatch wrapper):

```bash
bash cluster/run_reinforcement_diag.sh NECPEssentials 10 2 1.5
```

The runner generates its ignored per-run config on the cluster, writes to a
separate directory such as
`results/NECPEssentials_diag_dc2_intra10_inter1p5/`, and then
runs `derive_reinforcement.py`. The generated config uses DC redispatch,
`diagnostic_output = true`, the static EMPIRE commercial border caps, and no
manual reinforcement list. The normal 0.8 rating derate and EMPIRE's nodal
corridor capacities remain fixed. The multiplier applies only to Spanish
branches whose endpoints are in the same NUTS3 region. The optional fourth
argument gives Spanish inter-NUTS3 corridors (including `NEWES_*`) a bounded
diagnostic allowance; `1.0` keeps the original EMPIRE-derived limits and `1.5`
allows 50% more capacity. International links, including `NEWXB_*`, remain
fixed.

The memory-bounded output path retains only `summary.csv` and one peak-loading
row per branch in `branch_peaks.csv`; it does not materialise the full
hours-by-branches/units/buses tables. Hourly NTC preprocessing is disabled
because an intentionally uncongested high-LRF grid only rediscovers the EMPIRE
commercial caps while adding several DC solves per delivery hour.

Required SDDP outputs are checked before the run starts. If any branch still
eligible intrazonal branch still peaks at 99.9-100%, the derivation script
aborts; repeat with a larger intrazonal multiplier. Fixed EMPIRE corridors are
allowed to bind.
