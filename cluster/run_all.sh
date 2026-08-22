#!/usr/bin/env bash
# Sequential driver for the EMPIRE 2035 runs on Solstorm.
#
#   cd <repo>
#   julia --project=. cluster/make_configs.jl        # once, writes cluster/config_*.toml
#   nohup bash cluster/run_all.sh > cluster/run_all.log 2>&1 &
#
# Phases
#   midterm  midterm_sddp4.jl  — Bellman cuts, volume/turbine/exchange schedules
#   chain    run_opf.jl        — DA → ID2 → ID3 → CID → BAL → AC redispatch
# The chain reads the cuts the midterm phase writes, so midterm must finish
# first for a given scenario.  Runs are strictly sequential: each Julia process
# holds ~1.5 GB and one Gurobi/Ipopt thread, and running two at once on one node
# gains nothing while risking the node's memory.
#
# Resuming
# A phase is skipped only when its output is NEWER than the config that would
# produce it.  Regenerating cluster/config_*.toml therefore invalidates every
# result automatically — which is what you want here, since results/<label>/ and
# Data/*_sddp4_<label>.csv already hold output from the previous settings and a
# plain "does the file exist" check would silently skip the whole point of the
# run.  A restart after a crash still skips what this config already finished.
#
# Env overrides
#   SCENARIOS  space-separated subset          (default: all four)
#   PHASES     "midterm", "chain", or both     (default: both)
#   FORCE      1 = redo everything regardless  (default: 0)
set -u
cd "$(dirname "$0")/.." || exit 1

SCENARIOS=${SCENARIOS:-"NECPEssentials Trinity REPowerEU++ GoRES"}
PHASES=${PHASES:-"midterm chain"}
FORCE=${FORCE:-0}
LOGS=cluster/logs
mkdir -p "$LOGS"

say() { echo "[$(date '+%F %T')] $*"; }

# A phase is complete when its last output exists: the exchange schedule for the
# midterm (written after the cuts, volume and turbine files), the redispatch
# summary for the chain.
done_marker() {
  case $1 in
    midterm) echo "Data/ExchangeSchedule_sddp4_$2.csv" ;;
    chain)   echo "results/$2/summary.csv" ;;
  esac
}

script_for() {
  case $1 in
    midterm) echo "midterm_sddp4.jl" ;;
    chain)   echo "run_opf.jl" ;;
  esac
}

say "scenarios: $SCENARIOS"
say "phases   : $PHASES"

fail=0
for scen in $SCENARIOS; do
  cfg="cluster/config_${scen}.toml"
  if [ ! -f "$cfg" ]; then
    say "MISSING $cfg — run: julia --project=. cluster/make_configs.jl"
    fail=1; continue
  fi
  for phase in $PHASES; do
    marker=$(done_marker "$phase" "$scen")
    if [ "$FORCE" != "1" ] && [ -f "$marker" ] && [ "$marker" -nt "$cfg" ]; then
      say "SKIP  $scen/$phase — $marker is newer than $cfg"
      continue
    fi
    log="$LOGS/${scen}_${phase}.log"
    say "START $scen/$phase -> $log"
    start=$(date +%s)
    SPAIN_CONFIG="$cfg" julia --project=. "$(script_for "$phase")" > "$log" 2>&1
    rc=$?
    mins=$(( ($(date +%s) - start) / 60 ))
    if [ $rc -eq 0 ] && [ -f "$marker" ]; then
      say "OK    $scen/$phase in ${mins}m"
    else
      say "FAIL  $scen/$phase rc=$rc after ${mins}m — no $marker"
      tail -20 "$log" | sed 's/^/        /'
      fail=1
      # The chain depends on this scenario's cuts; skip it rather than run on stale ones.
      [ "$phase" = "midterm" ] && { say "SKIP  $scen/chain (its cuts are missing)"; break; }
    fi
  done
done

say "ALL DONE (exit $fail)"
exit $fail
