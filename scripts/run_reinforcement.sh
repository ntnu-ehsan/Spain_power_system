#!/usr/bin/env bash
# One-shot grid-reinforcement workflow: diagnostic -> sized list -> validation.
#
#   bash scripts/run_reinforcement.sh [scenario] [intra_mult] [n_weeks] [inter_mult]
#   defaults:                          NECPEssentials  10.0        2         1.0
#
# Runs, in order:
#   1-3.  scripts/run_reinforcement_diag.sh  — the uncongested-intrazonal DC
#         diagnostic, then derive_reinforcement.py, giving a ranked and sized
#         reinforcement.csv  (steps 1-5 of the method doc).
#   6.    a validation chain with that list loaded and every diagnostic
#         multiplier back at 1.0, then reports the feasible-hour count.
#
# The validation step is what confirms the list: the step-4 sizing is read off
# an uncongested solve, and flows redistribute once the limits bind again.
#
# Requires the scenario's SDDP cuts on disk — run midterm_sddp4.jl first.
set -euo pipefail
cd "$(dirname "$0")/.."

scenario=${1:-NECPEssentials}
mult=${2:-10.0}
n_weeks=${3:-2}
inter_mult=${4:-1.0}
python_cmd=${PYTHON:-python3}

mult_tag=${mult//./p}
inter_tag=${inter_mult//./p}
diag_out="results/${scenario}_diag_dc${n_weeks}_intra${mult_tag}_inter${inter_tag}_xbcountry_total_hourlyntc0p7_da_rd"
list="$diag_out/reinforcement.csv"
val_out="results/${scenario}_validate_intra${mult_tag}_inter${inter_tag}"
val_log="scripts/logs/${scenario}_validate_intra${mult_tag}_inter${inter_tag}.log"

echo "=== 1-5. diagnostic and sizing ==================================="
bash scripts/run_reinforcement_diag.sh "$scenario" "$mult" "$n_weeks" "$inter_mult"

[ -f "$list" ] || { echo "ABORT: $list was not produced" >&2; exit 1; }
echo
echo "reinforcement list : $list  ($(($(wc -l < "$list") - 1)) lines to expand)"

echo
echo "=== 6. validation chain ========================================="
mkdir -p scripts/logs "$val_out"
julia --project=. scripts/make_validation_config.jl "$scenario" "$list" "$n_weeks" DC

SPAIN_CONFIG="scripts/config_validate_${scenario}.toml" SPAIN_RESULTS="$val_out" \
    julia --project=. run_market_chain.jl 2>&1 | tee "$val_log"

echo
echo "=== result ======================================================"
"$python_cmd" - "$val_out/summary.csv" <<'PY'
import sys, pandas as pd
s = pd.read_csv(sys.argv[1])
ok = s.status.isin(["OPTIMAL", "LOCALLY_SOLVED"])
print(f"feasible hours : {ok.sum()}/{len(s)}")
if "load_shed_mw" in s:
    print(f"max load shed  : {pd.to_numeric(s.load_shed_mw, errors='coerce').max():.1f} MW")
if not ok.all():
    print("\nunsolved hours (raise the intrazonal multiplier and repeat):")
    print(s.loc[~ok, ["date", "hour", "status"]].to_string(index=False))
    sys.exit(1)
print("\nreinforcement list validated: every hour solved.")
PY
echo "results : $val_out"
