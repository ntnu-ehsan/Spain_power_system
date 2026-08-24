#!/usr/bin/env bash
# Run the memory-bounded grid-reinforcement diagnostic inside an allocated
# cluster node (or from an sbatch wrapper).
#
#   bash cluster/run_reinforcement_diag.sh [scenario] [intra_multiplier] [n_weeks]
#   defaults:                                  NECPEssentials  10.0              2
set -euo pipefail
cd "$(dirname "$0")/.."

scenario=${1:-NECPEssentials}
mult=${2:-10.0}
n_weeks=${3:-2}
mult_tag=${mult//./p}
python_cmd=${PYTHON:-python3}

cfg="cluster/config_diag_${scenario}.toml"
out="results/${scenario}_diag_dc${n_weeks}_intra${mult_tag}"
log="cluster/logs/${scenario}_diag_dc${n_weeks}_intra${mult_tag}.log"

mkdir -p cluster/logs "$out"

for f in \
    "Data/BellmanValuesOUT_sddp4_${scenario}.csv" \
    "Data/Volume_Scen0_OUT_sddp4_${scenario}.csv" \
    "Data/TurbineSchedule_sddp4_${scenario}.csv"; do
    if [ ! -f "$f" ]; then
        echo "MISSING $f — copy the matching SDDP output to the cluster first" >&2
        exit 1
    fi
done

julia --project=. cluster/make_diag_config.jl "$scenario" "$mult" "$n_weeks" DC

echo "diagnostic config : $cfg"
echo "results           : $out"
echo "log               : $log"

SPAIN_CONFIG="$cfg" SPAIN_RESULTS="$out" \
    julia --project=. run_opf.jl 2>&1 | tee "$log"

"$python_cmd" cluster/derive_reinforcement.py \
    "$out" "$out/reinforcement.csv" | tee -a "$log"

echo "reinforcement list: $out/reinforcement.csv"
