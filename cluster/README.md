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
