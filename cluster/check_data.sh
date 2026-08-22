#!/usr/bin/env bash
# Checksum every data file the chain actually reads, so a local copy and the
# Solstorm copy can be compared without guessing which one is current.
#
#   bash cluster/check_data.sh > local.txt      # on this machine
#   bash cluster/check_data.sh > cluster.txt    # on Solstorm
#   diff local.txt cluster.txt
#
# Lines that differ are the files to re-copy.  "MISSING" means the run will fail
# there, not that the file is merely stale.
#
# QUICK=1 compares size only.  It runs in seconds instead of minutes (the full
# set is ~700 MB, and hashing that under Git Bash on Windows is slow), and for
# these CSV/tab files a content edit that preserves the byte count is unlikely.
# Use the default md5 pass when you want certainty.
set -u
cd "$(dirname "$0")/.." || exit 1

SCENARIOS="NECPEssentials Trinity REPowerEU++ GoRES"

files() {
  # shared inputs
  cat <<'LIST'
Data/power_unit_tech_params.csv
Data/EU-EnVis-2060_Annual_Regional_CO2_Prices_v1.2.0.csv
Data/MIBGAS_Data_2024.csv
Data/Carbon Emissions Price.csv
Data/Generation.csv
Data/Transmission.csv
Data/Storage.csv
Data/generation_cost_pypsa_2024.csv
Data/Bus_Data.csv
Data/lines.csv
Data/generations.csv
Data/load_time_series.csv
Data/transformers_reactance.csv
Data/reactors.csv
Data/bus_nuts3.csv
Data/crossborder.csv
Data/sample_weeks.csv
Data/trinity_line_reinforcement_gt0.8.csv
LIST
  # smspp_in (ES fleet for the mid-term model) and the EDF/EMPIRE hourly series
  find Data/smspp_in -type f 2>/dev/null | sort
  find Data/ts -type f 2>/dev/null | sort
  # per-scenario EMPIRE inputs and outputs the code reads by name
  for s in $SCENARIOS; do
    for f in Output/genInstalledCap.tab Output/marginal_costs.csv \
             Output/transmissionInstalledCap.tab Output/storPWInstalledCap.tab \
             Output/storENInstalledCap.tab \
             Input/Tab/Generator_CO2Content.tab Input/Tab/General_CO2Price.tab \
             Input/Tab/Node_ElectricAnnualDemand.tab; do
      echo "Data/2035/$s/$f"
    done
    for f in solar windonshore windoffshore hydroror hydroseasonal electricload; do
      echo "Data/2035/$s/Input/Xlsx/ScenarioData/$f.csv"
    done
  done
  # market-chain profiles.  The chain builds the filename from the study day
  # (es_filename in run_opf.jl), so with [weeks] off only the TARGET_DAYS files
  # are read — but list the lot, since a stale copy of any of them is a silent
  # wrong answer once the target days or [weeks] change.
  find Data/ES -type f 2>/dev/null | sort
  find Data/ES_old -type f 2>/dev/null | sort
}

files | while IFS= read -r f; do
  if [ -f "$f" ]; then
    printf '%s  %10d  %s\n' "$(md5sum < "$f" | cut -d' ' -f1)" "$(wc -c < "$f")" "$f"
  else
    printf '%-32s %10s  %s\n' MISSING - "$f"
  fi
done
