#!/usr/bin/env bash
# Run the memory-bounded grid-reinforcement diagnostic (steps 1-3 of
# docs/method_grid_reinforcement_identification.md).
#
#   bash scripts/run_reinforcement_diag.sh [scenario] [intra_multiplier] [n_weeks] [inter_multiplier] [international_multiplier] [xb_split]
#   defaults:                                  NECPEssentials  10.0              2         1.0               1.0                       country_total
set -euo pipefail
cd "$(dirname "$0")/.."

scenario=${1:-NECPEssentials}
mult=${2:-10.0}
n_weeks=${3:-2}
inter_mult=${4:-1.0}
international_mult=${5:-1.0}
xb_split=${6:-country_total}
mult_tag=${mult//./p}
inter_tag=${inter_mult//./p}
international_tag=${international_mult//./p}
python_cmd=${PYTHON:-python3}

# Preserve the established result path when the international diagnostic is
# not requested; add a suffix only for the explicit sensitivity.
international_suffix=""
case "$international_mult" in
    1|1.0|1.00) ;;
    *) international_suffix="_international${international_tag}" ;;
esac
xb_suffix=""
case "$xb_split" in
    fixed) ;;
    *) xb_suffix="_xb${xb_split}" ;;
esac

cfg="scripts/config_diag_${scenario}.toml"
out="results/${scenario}_diag_dc${n_weeks}_intra${mult_tag}_inter${inter_tag}${international_suffix}${xb_suffix}_hourlyntc0p7_da_rd"
log="scripts/logs/${scenario}_diag_dc${n_weeks}_intra${mult_tag}_inter${inter_tag}${international_suffix}${xb_suffix}_hourlyntc0p7_da_rd.log"

mkdir -p scripts/logs "$out"

for f in \
    "Data/BellmanValuesOUT_sddp4_${scenario}.csv" \
    "Data/Volume_Scen0_OUT_sddp4_${scenario}.csv" \
    "Data/TurbineSchedule_sddp4_${scenario}.csv"; do
    if [ ! -f "$f" ]; then
        echo "MISSING $f — run midterm_sddp4.jl for this scenario first" >&2
        exit 1
    fi
done

julia --project=. scripts/make_diag_config.jl "$scenario" "$mult" "$n_weeks" DC "$inter_mult" "$international_mult" "$xb_split"

echo "diagnostic config : $cfg"
echo "results           : $out"
echo "log               : $log"

SPAIN_CONFIG="$cfg" SPAIN_RESULTS="$out" \
    julia --project=. run_market_chain.jl 2>&1 | tee "$log"

"$python_cmd" scripts/derive_reinforcement.py \
    "$out" "$out/reinforcement.csv" | tee -a "$log"

echo "reinforcement list: $out/reinforcement.csv"
