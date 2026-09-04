"""Publication figures for the 2035 market-chain scenario comparison.

The module reads the five copper-plate market stages written to
``results/<scenario>/`` and reduces them to compact, comparable metrics.  It is
deliberately independent of the AC-OPF redispatch outputs: the corresponding
notebook is about how the *market chain* differs across the four 2035
portfolios.

Energy is reported per equivalent day and market adjustments as a percentage
of balancing-stage demand.  These normalisations avoid the raw-GWh error in
which a longer simulation horizon appears larger merely because it has more
hours.  Final paper export is permitted only when all four scenarios contain
the same market stages and exactly the same timestamps.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import warnings

import matplotlib as mpl
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
import numpy as np
import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"
# Override with the SPAIN_FIG_DIR environment variable.
FIG_DIR = Path(os.environ.get("SPAIN_FIG_DIR", ROOT / "figures"))
TABLE_DIR = RESULTS / "comparison"

SCENARIOS = ("NECPEssentials", "GoRES", "REPowerEU++", "Trinity")
SCENARIO_LABEL = {
    "NECPEssentials": "NECP Essentials",
    "GoRES": "Go RES",
    "REPowerEU++": "REPowerEU++",
    "Trinity": "Trinity",
}
SCENARIO_COLOR = {
    "NECPEssentials": "#32688e",
    "GoRES": "#3a923a",
    "REPowerEU++": "#db7b2b",
    "Trinity": "#8d63a9",
}

# Matched 336-hour runs used in the 2035 results subsection.  Keeping this
# mapping separate from the four-scenario exploratory comparison above makes
# the paper build explicit and prevents an older ``results/<scenario>`` folder
# from being mixed into the new summer/winter experiment.
MARKET_2035_DIRS = {
    "NECPEssentials": RESULTS / "NECPEssentials_market_winter_summer_hourlyntc0p7_fullchain_ac",
    "Trinity": RESULTS / "Trinity_market_winter_summer_hourlyntc0p7_fullchain_ac",
}
MARKET_2035_REINFORCEMENT = {
    "NECPEssentials": RESULTS / "NECPEssentials_sens_hourlyntc0p7_intra3p0_inter5p0_da_rd"
    / "reinforcement_combined.csv",
    "Trinity": RESULTS / "Trinity_sens_hourlyntc0p7_intra2p5_inter3p0_da_rd"
    / "reinforcement_combined.csv",
}

GATES = ("da", "id2", "id3", "cid", "bal")
GATE_LABEL = {"da": "DA", "id2": "ID2", "id3": "ID3", "cid": "CID", "bal": "BAL"}

CATEGORY_ORDER = (
    "Nuclear", "Coal", "Gas", "Oil", "Biomass", "Waste", "Hydro",
    "Pumped storage", "Wind", "Solar", "Battery", "Cross-border",
    "Load shedding", "Slack",
)
CATEGORY_COLOR = {
    "Nuclear": "#8f63a9",
    "Coal": "#55443b",
    "Gas": "#6c6c6c",
    "Oil": "#a5a5a5",
    "Biomass": "#7a9a38",
    "Waste": "#a69c35",
    "Hydro": "#3578b8",
    "Pumped storage": "#55bfd2",
    "Wind": "#249d78",
    "Solar": "#efa13c",
    "Battery": "#26a6b5",
    "Cross-border": "#7e6a95",
    "Load shedding": "#cf3e73",
    "Slack": "#bdbdbd",
}


def use_paper_style():
    """Apply compact, print-legible defaults shared by all 2035 figures."""
    mpl.rcParams.update({
        "figure.dpi": 120,
        "savefig.dpi": 300,
        "savefig.bbox": "tight",
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
        "font.family": "serif",
        "font.size": 9,
        "axes.titlesize": 10,
        "axes.labelsize": 9,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.grid": True,
        "axes.axisbelow": True,
        "grid.alpha": 0.24,
        "grid.linewidth": 0.5,
        "legend.frameon": False,
        "legend.fontsize": 8,
        "xtick.labelsize": 8,
        "ytick.labelsize": 8,
    })


def default_scenario_dirs(results=RESULTS):
    """Canonical scenario-to-results-directory mapping (easy to override)."""
    results = Path(results)
    return {scenario: results / scenario for scenario in SCENARIOS}


def _price_path(root):
    for name in ("xb_flows.csv", "market_prices.csv"):
        path = root / name
        if path.exists():
            return path
    return None


def _time_index(root, gate="da"):
    """Read a stage's small profile file to get its represented timestamps."""
    path = root / f"{gate}_profiles.csv"
    if not path.exists():
        path = root / f"{gate}_dispatch.csv"
    if not path.exists():
        return set()
    frame = pd.read_csv(path, usecols=["date", "hour"])
    return set(zip(frame["date"].astype(str), frame["hour"].astype(int)))


def audit_scenarios(scenario_dirs=None):
    """Check completeness and timestamp comparability before paper export.

    Returns a dictionary with a display-ready table, detailed issues,
    ``core_ready`` (all market files and identical hours), and ``price_ready``.
    """
    dirs = default_scenario_dirs() if scenario_dirs is None else {
        key: Path(value) for key, value in scenario_dirs.items()
    }
    scenarios = SCENARIOS if scenario_dirs is None else tuple(dirs)
    rows, issues, time_sets = [], [], {}

    for scenario in scenarios:
        root = dirs.get(scenario, RESULTS / scenario)
        dispatch_ok = {g: (root / f"{g}_dispatch.csv").exists() for g in GATES}
        profile_ok = {g: (root / f"{g}_profiles.csv").exists() for g in GATES}
        times = _time_index(root, "da") if root.exists() else set()
        time_sets[scenario] = times
        dates = sorted({date for date, _ in times})
        price = _price_path(root)
        rows.append({
            "scenario": SCENARIO_LABEL.get(scenario, scenario),
            "directory": str(root),
            "dispatch gates": sum(dispatch_ok.values()),
            "profile gates": sum(profile_ok.values()),
            "prices": "yes" if price is not None else "no",
            "hours": len(times),
            "days": len(dates),
            "first date": dates[0] if dates else "",
            "last date": dates[-1] if dates else "",
        })
        if not root.exists():
            issues.append(f"{SCENARIO_LABEL.get(scenario, scenario)}: missing directory {root}")
        missing_dispatch = [GATE_LABEL[g] for g, ok in dispatch_ok.items() if not ok]
        missing_profiles = [GATE_LABEL[g] for g, ok in profile_ok.items() if not ok]
        if missing_dispatch:
            issues.append(f"{SCENARIO_LABEL.get(scenario, scenario)}: missing dispatch for {', '.join(missing_dispatch)}")
        if missing_profiles:
            issues.append(f"{SCENARIO_LABEL.get(scenario, scenario)}: missing profiles for {', '.join(missing_profiles)}")
        for gate in GATES:
            if dispatch_ok[gate] and profile_ok[gate]:
                gate_times = _time_index(root, gate)
                if gate_times != times:
                    issues.append(
                        f"{SCENARIO_LABEL.get(scenario, scenario)}: {GATE_LABEL[gate]} timestamps differ from DA"
                    )

    nonempty = [(scenario, time_sets[scenario]) for scenario in scenarios if time_sets[scenario]]
    if len(nonempty) > 1:
        reference_scenario, reference_times = nonempty[0]
        for scenario, times in nonempty[1:]:
            if times != reference_times:
                issues.append(
                    f"Timestamp mismatch: {SCENARIO_LABEL.get(scenario, scenario)} does not use the same "
                    f"hours as {SCENARIO_LABEL.get(reference_scenario, reference_scenario)}"
                )

    table = pd.DataFrame(rows).set_index("scenario")
    all_files = bool((table["dispatch gates"] == len(GATES)).all()) and bool(
        (table["profile gates"] == len(GATES)).all()
    )
    all_have_times = all(bool(time_sets[s]) for s in scenarios)
    same_times = all_have_times and all(
        time_sets[s] == time_sets[scenarios[0]] for s in scenarios[1:]
    )
    core_ready = all_files and same_times
    price_ready = core_ready and bool((table["prices"] == "yes").all())
    return {
        "table": table,
        "issues": issues,
        "core_ready": core_ready,
        "price_ready": price_ready,
        "time_sets": time_sets,
        "scenario_dirs": dirs,
        "scenarios": scenarios,
    }


def print_audit(audit):
    """Print a concise readiness report and return its table for display()."""
    print("Core paper figures:", "READY" if audit["core_ready"] else "NOT READY")
    print("Price figure      :", "READY" if audit["price_ready"] else "NOT READY")
    if audit["issues"]:
        print("\nChecks to resolve before final export:")
        for issue in audit["issues"]:
            print(" -", issue)
    return audit["table"]


def _category(frame):
    category = frame["fuel"].astype("string").replace({
        "CrossBorder": "Cross-border",
        "LoadShed": "Load shedding",
        "Electricity Storage": "Battery",
    })
    pumped = (frame["fuel"] == "Hydro") & (frame["technology"] == "pumped_storage")
    return category.mask(pumped, "Pumped storage")


# The two gate families book the border exchange in different places: the DA gate is
# the 4-zone zonal clear, so da_dispatch.csv lists ES internal units ONLY and the
# exchange lives in xb_flows.csv, while the nodal gates (ID2…BAL) carry the SAME
# exchange as nine per-node `XB_*` units inside the dispatch file.  The exchange
# itself is fixed by crossborder.csv and merely disaggregated onto border nodes at
# the nodal stage - it is not a market decision and does not move through the gates
# (checked: hourly ID2 net vs DA zonal net correlate at 1.000000, max diff 0.11 MW).
#
# Reading the files raw therefore makes the whole exchange look like fresh DA→ID2
# rescheduling: on these runs that inflated the DA→ID2 movement from 1.19% to 5.68%
# of demand (Trinity) and 1.61% to 7.83% (NECPEssentials), and wrongly made DA→ID2
# look like the largest gate when ID3→CID actually is.  `_read_dispatch` injects the
# zonal net into DA, and `_dispatch_delta` compares the exchange in aggregate so the
# per-node split never counts as movement.
XB_PSEUDO_UNIT = "XB_ZONAL_NET"


def _da_crossborder_rows(root):
    """DA border exchange from xb_flows.csv as one pseudo-unit per (date, hour)."""
    path = root / "xb_flows.csv"
    if not (path.exists() and path.stat().st_size > 0):
        return None
    frame = pd.read_csv(path, dtype={"date": "string", "hour": "int16"})
    cols = [c for c in ("fr_mw", "pt_mw") if c in frame.columns]   # ES borders, not the EU corridor
    if not cols:
        return None
    return pd.DataFrame({
        "date": frame["date"].astype("string"),
        "hour": frame["hour"].astype("int16"),
        "gen_id": pd.array([XB_PSEUDO_UNIT] * len(frame), dtype="string"),
        "category": pd.array(["Cross-border"] * len(frame), dtype="string"),
        "dispatch_mw": frame[cols].sum(axis=1).astype("float64"),
    })


def _read_dispatch(path, root=None):
    frame = pd.read_csv(
        path,
        usecols=["date", "hour", "gen_id", "fuel", "technology", "dispatch_mw"],
        dtype={"date": "string", "hour": "int16", "gen_id": "string", "dispatch_mw": "float64"},
    )
    frame["category"] = _category(frame)
    frame = frame[["date", "hour", "gen_id", "category", "dispatch_mw"]]
    if root is not None and not (frame["category"] == "Cross-border").any():
        border = _da_crossborder_rows(root)
        if border is not None:
            frame = pd.concat([frame, border], ignore_index=True)
    return frame


def _read_profile(path):
    return pd.read_csv(path, dtype={"date": "string", "hour": "int16"})


def _mix_rows(frame, scenario, gate, equivalent_days):
    rows = []
    positive = frame.assign(value=frame["dispatch_mw"].clip(lower=0)).groupby("category")["value"].sum()
    negative = frame.assign(value=frame["dispatch_mw"].clip(upper=0)).groupby("category")["value"].sum()
    for category in sorted(set(positive.index) | set(negative.index)):
        for direction, value in (("supply", positive.get(category, 0.0)),
                                 ("sink", negative.get(category, 0.0))):
            if abs(value) > 1e-8:
                rows.append({
                    "scenario": scenario,
                    "gate": gate,
                    "category": category,
                    "direction": direction,
                    "gwh_per_day": value / 1000.0 / equivalent_days,
                })
    return rows


def _collapse_crossborder(frame):
    """Aggregate the per-node XB_* units into one pseudo-unit per (date, hour).

    The nodal split of a fixed border exchange is a modelling convention, so it must
    not register as rescheduling when a zonal gate is differenced against a nodal one
    (see the note above XB_PSEUDO_UNIT).  Only the delta path uses this - `_mix_rows`
    keeps the per-node rows, whose individual signs decide the supply/sink split.
    """
    border = frame["category"] == "Cross-border"
    if not border.any():
        return frame
    aggregated = (frame[border]
                  .groupby(["date", "hour"], as_index=False, observed=True)["dispatch_mw"].sum())
    aggregated["gen_id"] = pd.array([XB_PSEUDO_UNIT] * len(aggregated), dtype="string")
    aggregated["category"] = pd.array(["Cross-border"] * len(aggregated), dtype="string")
    return pd.concat([frame[~border], aggregated[frame.columns]], ignore_index=True)


def _dispatch_delta(before, after):
    keys = ["date", "hour", "gen_id"]
    before, after = _collapse_crossborder(before), _collapse_crossborder(after)
    left = before.rename(columns={"category": "category_before", "dispatch_mw": "before"})
    right = after.rename(columns={"category": "category_after", "dispatch_mw": "after"})
    delta = left.merge(right, on=keys, how="outer", validate="one_to_one")
    delta["before"] = delta["before"].fillna(0.0)
    delta["after"] = delta["after"].fillna(0.0)
    delta["category"] = delta["category_after"].fillna(delta["category_before"])
    delta["delta_mw"] = delta["after"] - delta["before"]
    return delta[["category", "delta_mw"]]


def _load_prices(root, scenario):
    rows = []
    market = root / "market_prices.csv"
    if market.exists():
        frame = pd.read_csv(market)
        if {"stage", "price_eur_mwh"} <= set(frame.columns):
            for stage, part in frame.groupby(frame["stage"].astype(str).str.upper()):
                if stage in set(GATE_LABEL.values()):
                    rows.extend({"scenario": scenario, "stage": stage, "price_eur_mwh": float(value)}
                                for value in part["price_eur_mwh"].dropna())

    # In a four-zone DA run, price_es is the appropriate Spanish DA price.
    xb = root / "xb_flows.csv"
    if xb.exists():
        frame = pd.read_csv(xb, usecols=lambda c: c in {"price_es"})
        if "price_es" in frame:
            rows = [row for row in rows if row["stage"] != "DA"]
            rows.extend({"scenario": scenario, "stage": "DA", "price_eur_mwh": float(value)}
                        for value in frame["price_es"].dropna())
    return rows


def _ordered_present(values, canonical):
    values = list(dict.fromkeys(values))
    return [item for item in canonical if item in values] + [item for item in values if item not in canonical]


def _sddp_log_rows(path):
    """Parse the iteration table and final policy estimate from an SDDP.jl log."""
    text = path.read_text(encoding="utf-8", errors="replace")
    rows = []
    for line in text.splitlines():
        match = re.match(
            r"\s*(\d+)[A-Z]?\s+([-\d.e+]+)\s+([-\d.e+]+)\s+([-\d.e+]+)\s+(\d+)",
            line,
            re.IGNORECASE,
        )
        if match:
            row = {
                "iteration": int(match.group(1)),
                "simulation_eur": float(match.group(2)),
                "bound_eur": float(match.group(3)),
            }
            # Some log files contain several appended training runs. Keep only
            # the most recent monotone iteration sequence.
            if rows and row["iteration"] <= rows[-1]["iteration"]:
                rows = []
            rows.append(row)
    convergence = pd.DataFrame(rows)
    best = re.findall(r"best bound\s*:\s*([-\d.e+]+)", text, re.IGNORECASE)
    policy = re.findall(r"simulation ci\s*:\s*([-\d.e+]+)", text, re.IGNORECASE)
    status = re.findall(r"status\s*:\s*([^\r\n]+)", text, re.IGNORECASE)
    return convergence, {
        "best_bound_eur": float(best[-1]) if best else np.nan,
        "policy_cost_eur": float(policy[-1]) if policy else np.nan,
        "status": status[-1].strip() if status else "unknown",
    }


def load_sddp_comparison(root=ROOT):
    """Load compact, cross-scenario diagnostics from the four SDDP runs.

    The large diagnostics files are read with only the columns required here.
    Prices are converted from per-block balance duals to EUR/MWh using
    ``midterm4.block_hours`` from ``config.toml``.
    """
    root = Path(root)
    config_text = (root / "config.toml").read_text(encoding="utf-8")
    match = re.search(r"\[midterm4\][\s\S]*?^\s*block_hours\s*=\s*(\d+)", config_text, re.MULTILINE)
    block_hours = int(match.group(1)) if match else 2

    summaries, convergence_rows = [], []
    duration_rows, reservoir_rows, issues = [], [], []
    volume_column = "Hydro|Reservoir_ES_0"

    for scenario in SCENARIOS:
        diag_path = root / "results" / f"midterm4_diag_{scenario}.csv"
        cuts_path = root / "Data" / f"BellmanValuesOUT_sddp4_{scenario}.csv"
        volume_path = root / "Data" / f"Volume_Scen0_OUT_sddp4_{scenario}.csv"
        log_path = root / "results" / f"midterm4_sddp_{scenario}.log"
        storage_path = root / "Data" / f"smspp_in_2035_{scenario}" / "SS_SeasonalStorage.csv"
        required = (diag_path, cuts_path, volume_path, log_path, storage_path)
        missing = [path for path in required if not path.exists()]
        if missing:
            issues.append(f"{SCENARIO_LABEL[scenario]}: missing {', '.join(path.name for path in missing)}")
            continue

        diag = pd.read_csv(diag_path, usecols=["rep", "pES", "shed"])
        prices = diag["pES"].to_numpy(dtype=float) / block_hours
        prices = prices[np.isfinite(prices)]
        cuts = pd.read_csv(cuts_path)
        volume = pd.read_csv(volume_path, usecols=["Timestep", volume_column])
        storage = pd.read_csv(storage_path, sep=";")
        es_storage = storage[(storage["Zone"] == "ES") & (storage["Name"] == "Reservoir")]
        vmax = float(es_storage["MaxVolume"].iloc[0])
        convergence, log_summary = _sddp_log_rows(log_path)

        if not convergence.empty:
            conv = convergence.copy()
            conv["scenario"] = scenario
            convergence_rows.append(conv)
        quantiles = np.linspace(0, 100, 301)
        duration_rows.extend({
            "scenario": scenario,
            "exceedance_pct": float(q),
            "price_eur_mwh": float(value),
        } for q, value in zip(quantiles, np.percentile(prices, 100 - quantiles)))

        # The exported trajectory is hourly; retain one point per week plus the final point.
        weekly = volume[(volume["Timestep"] % 168 == 0) | (volume.index == volume.index[-1])].copy()
        reservoir_rows.extend({
            "scenario": scenario,
            "week": float(timestep) / 168.0,
            "fill_pct": 100.0 * float(value) / vmax,
        } for timestep, value in weekly[["Timestep", volume_column]].itertuples(index=False, name=None))

        policy = log_summary["policy_cost_eur"]
        bound = log_summary["best_bound_eur"]
        gap = 100.0 * (policy - bound) / policy if np.isfinite(policy) and policy else np.nan
        summaries.append({
            "scenario": scenario,
            "iterations": int(convergence["iteration"].max()) if not convergence.empty else 0,
            "cuts": len(cuts),
            "policy_cost_bn_eur": policy / 1e9,
            "lower_bound_bn_eur": bound / 1e9,
            "policy_gap_pct": gap,
            "mean_es_price_eur_mwh": float(np.mean(prices)),
            "p95_es_price_eur_mwh": float(np.percentile(prices, 95)),
            "shed_blocks_pct": 100.0 * float((diag["shed"] > 1e-6).mean()),
            "initial_es_fill_pct": 100.0 * float(volume[volume_column].iloc[0]) / vmax,
            "final_es_fill_pct": 100.0 * float(volume[volume_column].iloc[-1]) / vmax,
            "policy_replications": int(diag["rep"].nunique()),
            "status": log_summary["status"],
        })

    return {
        "ready": len(summaries) == len(SCENARIOS) and not issues,
        "issues": issues,
        "block_hours": block_hours,
        "summary": pd.DataFrame(summaries),
        "convergence": pd.concat(convergence_rows, ignore_index=True) if convergence_rows else pd.DataFrame(),
        "price_duration": pd.DataFrame(duration_rows),
        "reservoir": pd.DataFrame(reservoir_rows),
    }


def sddp_summary_table(data):
    """Display-ready summary of training quality and the simulated SDDP policy."""
    frame = data["summary"]
    if frame.empty:
        return frame
    columns = {
        "iterations": "Iterations",
        "cuts": "Cuts",
        "policy_cost_bn_eur": "Policy cost [bn €]",
        "lower_bound_bn_eur": "Lower bound [bn €]",
        "policy_gap_pct": "Policy–bound gap [%]",
        "mean_es_price_eur_mwh": "Mean ES price [€/MWh]",
        "p95_es_price_eur_mwh": "P95 ES price [€/MWh]",
        "shed_blocks_pct": "Blocks with shedding [%]",
        "initial_es_fill_pct": "Initial ES fill [%]",
        "final_es_fill_pct": "Final ES fill [%]",
        "status": "Training status",
    }
    table = frame.set_index("scenario").rename(index=SCENARIO_LABEL, columns=columns)
    return table[list(columns.values())].round(2)


def fig_sddp_comparison(data, save=False, name="2035_sddp_scenario_comparison"):
    """Compare SDDP convergence, Spanish price duration, and reservoir policy."""
    if data["summary"].empty:
        raise ValueError("No scenario-specific SDDP outputs are available.")
    fig = plt.figure(figsize=(7.2, 6.2))
    grid = fig.add_gridspec(2, 2, height_ratios=[1, 1.05], hspace=0.38, wspace=0.30)
    convergence_ax = fig.add_subplot(grid[0, :])
    price_ax = fig.add_subplot(grid[1, 0])
    reservoir_ax = fig.add_subplot(grid[1, 1])

    convergence = data["convergence"]
    duration = data["price_duration"]
    reservoir = data["reservoir"]
    scenarios = [scenario for scenario in SCENARIOS
                 if scenario in set(data["summary"]["scenario"])]
    for scenario in scenarios:
        conv = convergence[convergence["scenario"] == scenario]
        convergence_ax.plot(conv["iteration"], conv["bound_eur"] / 1e9,
                            color=SCENARIO_COLOR[scenario], label=SCENARIO_LABEL[scenario])
        curve = duration[duration["scenario"] == scenario]
        price_ax.plot(curve["exceedance_pct"], curve["price_eur_mwh"],
                      color=SCENARIO_COLOR[scenario])
        trajectory = reservoir[reservoir["scenario"] == scenario]
        reservoir_ax.plot(trajectory["week"], trajectory["fill_pct"],
                          color=SCENARIO_COLOR[scenario])

    convergence_ax.set_title("(a) SDDP lower-bound convergence")
    convergence_ax.set_xlabel("Iteration")
    convergence_ax.set_ylabel("Expected cost lower bound [bn €]")
    convergence_ax.legend(ncol=2, loc="lower right")
    price_ax.set_title("(b) Spanish marginal-price duration")
    price_ax.set_xlabel("Share of blocks exceeded [%]")
    price_ax.set_ylabel("Mid-term price [€/MWh]")
    reservoir_ax.set_title("(c) Spanish reservoir trajectory")
    reservoir_ax.set_xlabel("Week")
    reservoir_ax.set_ylabel("Stored energy [% of capacity]")
    fig.suptitle("SDDP policy comparison across 2035 scenarios", y=0.995)
    return _save(fig, name, save)


def build_paper_data(scenario_dirs=None, require_complete=False):
    """Reduce the available scenario CSVs to publication-scale tables.

    With ``require_complete=False`` (the notebook default), available scenarios
    are processed for preview and missing runs are reported by the audit.  Set
    it to ``True`` for a final paper build.
    """
    audit = audit_scenarios(scenario_dirs)
    if require_complete and not audit["core_ready"]:
        raise RuntimeError("The requested scenarios are not paper-ready; run print_audit(audit) for details.")
    if not audit["core_ready"]:
        warnings.warn(
            "Building a preview from incomplete or non-matching scenario runs. "
            "Do not use it in the paper until the audit is READY.",
            RuntimeWarning,
            stacklevel=2,
        )

    mix_rows, movement_rows, adjustment_rows = [], [], []
    curtailment_rows, price_rows, kpi_rows = [], [], []
    loaded_scenarios = []

    for scenario in audit["scenarios"]:
        root = audit["scenario_dirs"].get(scenario, RESULTS / scenario)
        available_gates = [g for g in GATES if (root / f"{g}_dispatch.csv").exists()]
        profile_gates = [g for g in GATES if (root / f"{g}_profiles.csv").exists()]
        if not available_gates or not profile_gates:
            continue
        loaded_scenarios.append(scenario)

        profiles = {g: _read_profile(root / f"{g}_profiles.csv") for g in profile_gates}
        reference_profile = profiles.get("bal", profiles[profile_gates[-1]])
        n_hours = len(reference_profile[["date", "hour"]].drop_duplicates())
        equivalent_days = n_hours / 24.0
        if equivalent_days <= 0:
            continue
        load_mwh = float(reference_profile["load_mw"].sum())

        previous = None
        previous_gate = None
        stage_res = {}
        for gate in GATES:
            path = root / f"{gate}_dispatch.csv"
            if not path.exists():
                continue
            current = _read_dispatch(path, root)
            mix_rows.extend(_mix_rows(current, scenario, gate, equivalent_days))

            res_dispatch_mwh = float(
                current.loc[current["category"].isin(["Wind", "Solar"]), "dispatch_mw"].clip(lower=0).sum()
            )
            stage_res[gate] = res_dispatch_mwh
            if previous is not None:
                delta = _dispatch_delta(previous, current)
                movement_rows.append({
                    "scenario": scenario,
                    "transition": f"{GATE_LABEL[previous_gate]}→{GATE_LABEL[gate]}",
                    "movement_pct_demand": 100.0 * delta["delta_mw"].abs().sum() / load_mwh,
                })
            previous, previous_gate = current, gate

        if "da" in available_gates and "bal" in available_gates:
            day_ahead = _read_dispatch(root / "da_dispatch.csv", root)
            balancing = previous if previous_gate == "bal" else _read_dispatch(root / "bal_dispatch.csv", root)
            delta = _dispatch_delta(day_ahead, balancing)
            for category, part in delta.groupby("category"):
                up = float(part["delta_mw"].clip(lower=0).sum())
                down = float(part["delta_mw"].clip(upper=0).sum())
                if up > 1e-8:
                    adjustment_rows.append({"scenario": scenario, "category": category,
                                            "direction": "up", "pct_demand": 100.0 * up / load_mwh})
                if down < -1e-8:
                    adjustment_rows.append({"scenario": scenario, "category": category,
                                            "direction": "down", "pct_demand": 100.0 * down / load_mwh})
            da_bal_movement = 100.0 * delta["delta_mw"].abs().sum() / load_mwh
        else:
            da_bal_movement = np.nan

        for gate in GATES:
            if gate not in profiles or gate not in stage_res:
                continue
            profile = profiles[gate]
            available_mwh = float(profile[["solar_mw", "wind_mw"]].sum().sum())
            curtailed_mwh = max(available_mwh - stage_res[gate], 0.0)
            curtailment_rows.append({
                "scenario": scenario,
                "gate": gate,
                "available_gwh_day": available_mwh / 1000.0 / equivalent_days,
                "dispatched_gwh_day": stage_res[gate] / 1000.0 / equivalent_days,
                "curtailed_gwh_day": curtailed_mwh / 1000.0 / equivalent_days,
                "curtailment_pct": 100.0 * curtailed_mwh / available_mwh if available_mwh else np.nan,
            })

        price_rows.extend(_load_prices(root, scenario))

        balancing_frame = previous if previous_gate == "bal" else None
        load_shed_mwh = 0.0
        slack_mwh = 0.0
        if balancing_frame is not None:
            load_shed_mwh = float(
                balancing_frame.loc[balancing_frame["category"] == "Load shedding", "dispatch_mw"].clip(lower=0).sum()
            )
            slack_mwh = float(
                balancing_frame.loc[balancing_frame["category"] == "Slack", "dispatch_mw"].abs().sum()
            )
        bal_cur = next((row for row in curtailment_rows
                        if row["scenario"] == scenario and row["gate"] == "bal"), None)
        bal_res_gwh_day = np.nan if bal_cur is None else bal_cur["dispatched_gwh_day"]
        demand_gwh_day = load_mwh / 1000.0 / equivalent_days
        kpi_rows.append({
            "scenario": scenario,
            "hours": n_hours,
            "equivalent_days": equivalent_days,
            "demand_gwh_day": demand_gwh_day,
            "mean_load_gw": load_mwh / n_hours / 1000.0,
            "bal_vre_gwh_day": bal_res_gwh_day,
            "bal_vre_share_demand_pct": 100.0 * bal_res_gwh_day / demand_gwh_day,
            "bal_curtailment_pct": np.nan if bal_cur is None else bal_cur["curtailment_pct"],
            "da_to_bal_movement_pct_demand": da_bal_movement,
            "bal_load_shed_pct_demand": 100.0 * load_shed_mwh / load_mwh,
            "bal_slack_pct_demand": 100.0 * slack_mwh / load_mwh,
        })

    prices = pd.DataFrame(price_rows)
    kpis = pd.DataFrame(kpi_rows)
    if not kpis.empty and not prices.empty:
        da_prices = prices[prices["stage"] == "DA"].groupby("scenario")["price_eur_mwh"]
        price_summary = pd.DataFrame({
            "da_price_mean_eur_mwh": da_prices.mean(),
            "da_price_p95_eur_mwh": da_prices.quantile(0.95),
        }).reset_index()
        kpis = kpis.merge(price_summary, on="scenario", how="left")
    elif not kpis.empty:
        kpis["da_price_mean_eur_mwh"] = np.nan
        kpis["da_price_p95_eur_mwh"] = np.nan

    return {
        "audit": audit,
        "scenarios": loaded_scenarios,
        "mix": pd.DataFrame(mix_rows),
        "movement": pd.DataFrame(movement_rows),
        "adjustment": pd.DataFrame(adjustment_rows),
        "curtailment": pd.DataFrame(curtailment_rows),
        "prices": prices,
        "kpis": kpis,
    }


def headline_table(data):
    """Return the compact scenario KPI table intended to support paper prose."""
    if data["kpis"].empty:
        return data["kpis"]
    columns = {
        "hours": "Hours",
        "mean_load_gw": "Mean load [GW]",
        "bal_vre_share_demand_pct": "BAL VRE / demand [%]",
        "bal_curtailment_pct": "BAL VRE curtailment [%]",
        "da_to_bal_movement_pct_demand": "DA→BAL movement / demand [%]",
        "bal_load_shed_pct_demand": "Load shedding / demand [%]",
        "da_price_mean_eur_mwh": "Mean DA price [€/MWh]",
        "da_price_p95_eur_mwh": "P95 DA price [€/MWh]",
    }
    table = data["kpis"].set_index("scenario").rename(index=SCENARIO_LABEL, columns=columns)
    table = table[[column for column in columns.values() if column in table.columns]]
    return table.round(2)


def _save(fig, name, save):
    if save:
        FIG_DIR.mkdir(parents=True, exist_ok=True)
        path = FIG_DIR / f"{name}.pdf"
        fig.savefig(path)
        print("wrote", path.relative_to(ROOT))
    return fig


def _scenario_order(data):
    return [scenario for scenario in SCENARIOS if scenario in data["scenarios"]]


def fig_balancing_mix(data, save=False, name="2035_scenario_balancing_mix"):
    """Average daily BAL supply mix; storage charging and exports are negative."""
    frame = data["mix"]
    if frame.empty:
        raise ValueError("No market dispatch data are available.")
    frame = frame[frame["gate"] == "bal"]
    scenarios = _scenario_order(data)
    categories = _ordered_present(frame["category"], CATEGORY_ORDER)
    x = np.arange(len(scenarios))
    fig, ax = plt.subplots(figsize=(7.2, 4.2))
    positive_bottom = np.zeros(len(scenarios))
    negative_bottom = np.zeros(len(scenarios))

    for category in categories:
        part = frame[frame["category"] == category]
        positive = np.array([
            part[(part["scenario"] == scenario) & (part["direction"] == "supply")]["gwh_per_day"].sum()
            for scenario in scenarios
        ])
        negative = np.array([
            part[(part["scenario"] == scenario) & (part["direction"] == "sink")]["gwh_per_day"].sum()
            for scenario in scenarios
        ])
        color = CATEGORY_COLOR.get(category, "#999999")
        if np.any(positive):
            ax.bar(x, positive, bottom=positive_bottom, width=0.68, color=color,
                   label=category, edgecolor="white", linewidth=0.25)
            positive_bottom += positive
        if np.any(negative):
            ax.bar(x, negative, bottom=negative_bottom, width=0.68, color=color,
                   edgecolor="white", linewidth=0.25)
            negative_bottom += negative

    kpis = data["kpis"].set_index("scenario")
    demand = [kpis.loc[scenario, "demand_gwh_day"] for scenario in scenarios]
    ax.scatter(x, demand, marker="_", s=260, linewidth=1.5, color="black", label="Demand")
    ax.axhline(0, color="0.3", lw=0.7)
    ax.set_xticks(x, [SCENARIO_LABEL[s] for s in scenarios])
    ax.set_ylabel("Average daily energy [GWh/day]")
    ax.set_title("Balancing-stage energy mix across 2035 scenarios")
    ax.legend(ncol=3, loc="upper center", bbox_to_anchor=(0.5, -0.16))
    fig.subplots_adjust(bottom=0.29)
    return _save(fig, name, save)


def fig_gate_movement(data, save=False, name="2035_scenario_gate_movement"):
    """Gross unit-level rescheduling at each consecutive market transition."""
    frame = data["movement"]
    if frame.empty:
        raise ValueError("At least two market stages are needed for gate movement.")
    scenarios = _scenario_order(data)
    transitions = [f"{GATE_LABEL[a]}→{GATE_LABEL[b]}" for a, b in zip(GATES[:-1], GATES[1:])]
    x = np.arange(len(transitions))
    width = 0.8 / max(len(scenarios), 1)
    fig, ax = plt.subplots(figsize=(7.2, 3.8))
    for index, scenario in enumerate(scenarios):
        part = frame[frame["scenario"] == scenario].set_index("transition")
        values = [part["movement_pct_demand"].get(transition, np.nan) for transition in transitions]
        offset = (index - (len(scenarios) - 1) / 2) * width
        ax.bar(x + offset, values, width=width, color=SCENARIO_COLOR[scenario],
               label=SCENARIO_LABEL[scenario])
    ax.set_xticks(x, transitions)
    ax.set_ylabel("Gross dispatch movement [% of BAL demand]")
    ax.set_title("Rescheduling introduced by each market gate")
    ax.legend(ncol=2, loc="upper left")
    return _save(fig, name, save)


def fig_adjustment_by_fuel(data, save=False, name="2035_scenario_adjustment_by_fuel"):
    """Gross upward/downward change from DA to BAL, split by technology family."""
    frame = data["adjustment"]
    if frame.empty:
        raise ValueError("DA and BAL dispatch are needed for the adjustment figure.")
    scenarios = _scenario_order(data)
    categories = _ordered_present(frame["category"], CATEGORY_ORDER)
    ncols = 2
    nrows = int(np.ceil(len(scenarios) / ncols))
    fig, axes = plt.subplots(nrows, ncols, figsize=(7.2, 2.8 * nrows), sharex=True)
    axes = np.atleast_1d(axes).ravel()
    y = np.arange(len(categories))
    for ax, scenario in zip(axes, scenarios):
        part = frame[frame["scenario"] == scenario]
        up = [part[(part["category"] == category) & (part["direction"] == "up")]["pct_demand"].sum()
              for category in categories]
        down = [part[(part["category"] == category) & (part["direction"] == "down")]["pct_demand"].sum()
                for category in categories]
        ax.barh(y, up, color="#3b8f5a", label="Upward")
        ax.barh(y, down, color="#c6534f", label="Downward")
        ax.axvline(0, color="0.3", lw=0.7)
        ax.set_yticks(y, categories)
        ax.invert_yaxis()
        ax.set_title(SCENARIO_LABEL[scenario])
    for ax in axes[len(scenarios):]:
        ax.set_visible(False)
    fig.legend(
        handles=[Patch(facecolor="#3b8f5a", label="Upward"),
                 Patch(facecolor="#c6534f", label="Downward")],
        loc="upper center", bbox_to_anchor=(0.5, 0.945), ncol=2,
    )
    fig.supxlabel("DA→BAL adjustment [% of BAL demand]", y=0.018)
    fig.suptitle("Technology providing market-chain adjustments", y=0.995)
    fig.tight_layout(rect=(0, 0.055, 1, 0.88))
    return _save(fig, name, save)


def fig_curtailment(data, save=False, name="2035_scenario_vre_curtailment"):
    """VRE curtailment through the gates and final VRE contribution to demand."""
    frame = data["curtailment"]
    if frame.empty:
        raise ValueError("Market profiles and dispatch are needed for curtailment.")
    scenarios = _scenario_order(data)
    fig, (left, right) = plt.subplots(1, 2, figsize=(7.2, 3.7), gridspec_kw={"width_ratios": [1.6, 1]})
    x = np.arange(len(GATES))
    for scenario in scenarios:
        part = frame[frame["scenario"] == scenario].set_index("gate")
        values = [part["curtailment_pct"].get(gate, np.nan) for gate in GATES]
        left.plot(x, values, marker="o", ms=3.5, color=SCENARIO_COLOR[scenario],
                  label=SCENARIO_LABEL[scenario])
    left.set_xticks(x, [GATE_LABEL[g] for g in GATES])
    left.set_ylabel("Curtailed available wind + solar [%]")
    left.set_title("Curtailment through the market chain")
    left.legend(fontsize=7.5)

    kpis = data["kpis"].set_index("scenario")
    values = [kpis.loc[scenario, "bal_vre_share_demand_pct"] for scenario in scenarios]
    right.bar(np.arange(len(scenarios)), values,
              color=[SCENARIO_COLOR[scenario] for scenario in scenarios], width=0.68)
    right.set_xticks(np.arange(len(scenarios)), [SCENARIO_LABEL[s] for s in scenarios], rotation=25, ha="right")
    right.set_ylabel("BAL wind + solar [% of demand]")
    right.set_title("Final VRE contribution")
    fig.tight_layout()
    return _save(fig, name, save)


def fig_prices(data, save=False, name="2035_scenario_prices"):
    """Spanish price-duration curves and mean price at each available stage."""
    frame = data["prices"]
    if frame.empty:
        raise ValueError("No price output is available (xb_flows.csv or market_prices.csv).")
    scenarios = [s for s in _scenario_order(data) if s in set(frame["scenario"])]
    fig, (left, right) = plt.subplots(1, 2, figsize=(7.2, 3.7), gridspec_kw={"width_ratios": [1.3, 1]})
    for scenario in scenarios:
        values = frame[(frame["scenario"] == scenario) & (frame["stage"] == "DA")]["price_eur_mwh"].dropna()
        if values.empty:
            continue
        ordered = np.sort(values.to_numpy())[::-1]
        exceedance = np.linspace(0, 100, len(ordered), endpoint=True)
        left.plot(exceedance, ordered, color=SCENARIO_COLOR[scenario], label=SCENARIO_LABEL[scenario])
    left.set_xlabel("Share of hours exceeded [%]")
    left.set_ylabel("Spanish DA price [€/MWh]")
    left.set_title("Day-ahead price duration")
    left.legend(fontsize=7.5)

    stages = [GATE_LABEL[g] for g in GATES]
    x = np.arange(len(stages))
    for scenario in scenarios:
        means = frame[frame["scenario"] == scenario].groupby("stage")["price_eur_mwh"].mean()
        right.plot(x, [means.get(stage, np.nan) for stage in stages], marker="o", ms=3.5,
                   color=SCENARIO_COLOR[scenario], label=SCENARIO_LABEL[scenario])
    right.set_xticks(x, stages)
    right.set_ylabel("Mean price [€/MWh]")
    right.set_title("Mean price by market gate")
    fig.tight_layout()
    return _save(fig, name, save)


# ─── Same visual format as paper_figures_2024 ──────────────────────────────────
# `fig_balancing_mix` above uses this module's own category scheme (CATEGORY_COLOR)
# to compare all four scenarios in one bar chart. The two helpers below instead
# reuse `paper_figures_2024`'s categorisation, colours, stacking order and paper
# style verbatim, so a single scenario's DA generation mix renders as the exact
# same figure family as `paper_figures_2024.fig_da_mix` -- just without the OMIE
# reference row, since there is no observed 2035 market to check it against.
try:
    from plotting import paper_figures_2024 as _p24
except ModuleNotFoundError:  # Support ``python plotting/paper_figures_2035.py``.
    import paper_figures_2024 as _p24


def load_chain_scenario(scenario: str, results_root=RESULTS):
    """`paper_figures_2024.load_chain`, pointed at one 2035 scenario folder
    (e.g. `results/Trinity`) instead of the 2024 validation `results/`."""
    return _p24.load_chain(results=Path(results_root) / scenario)


_MONTHS = ("January", "February", "March", "April", "May", "June", "July",
           "August", "September", "October", "November", "December")


def _day_label(date: str) -> str:
    """'2024-07-08' -> '8 July', matching `paper_figures_2024.DAY_LABEL`."""
    year, month, day = (int(part) for part in str(date).split("-"))
    return f"{day} {_MONTHS[month - 1]}"


def representative_days(ch, gate="da"):
    """The days to draw as panels, derived from the run rather than hard-coded.

    The 2035 scenarios do not share a horizon: three of them carry the two
    representative days of the 2024 validation, while NECPEssentials carries a
    contiguous fortnight.  Hard-coding `paper_figures_2024.DAYS` therefore drew
    empty panels (and raised) on any scenario whose horizon differs.

    The horizon is split into runs of consecutive calendar days, each run into
    7-day weeks (a trailing remainder shorter than four days joins the week
    before it), and the peak-demand day of every week becomes one panel.  Two
    separated single days give two panels; a fortnight gives two panels; so the
    figure keeps the two-panel shape of the 2024 original in either case.
    """
    frame = ch["gates"][gate]
    days = sorted(frame["date"].astype(str).unique())
    if not days:
        return []

    demand = ch.get("profiles", {}).get(gate)
    if demand is not None and "load_mw" in demand:
        weight = demand.assign(date=demand["date"].astype(str)).groupby("date")["load_mw"].sum()
    else:                                   # no profile file: fall back on dispatch
        weight = frame.groupby(frame["date"].astype(str))["dispatch_mw"].sum()

    stamps = pd.to_datetime(pd.Series(days))
    breaks = (stamps.diff().dt.days.fillna(1) != 1).to_numpy()
    blocks, current = [], []
    for day, is_break in zip(days, breaks):
        if is_break and current:
            blocks.append(current)
            current = []
        current.append(day)
    blocks.append(current)

    weeks = []
    for block in blocks:
        chunks = [block[i:i + 7] for i in range(0, len(block), 7)]
        if len(chunks) > 1 and len(chunks[-1]) < 4:
            chunks[-2] = chunks[-2] + chunks.pop()
        weeks.extend(chunks)
    return [max(week, key=lambda day: weight.get(day, 0.0)) for week in weeks]


def fig_da_mix_model(ch, scenario: str, days=None, save=False, name=None):
    """Day-ahead generation mix in the exact `paper_figures_2024.fig_da_mix` format --
    one stacked-area panel per representative day, sharing a y-axis -- for a
    scenario with no observed reference to plot alongside it.

    `days` defaults to `representative_days(ch)`; pass an explicit list of
    'YYYY-MM-DD' strings to choose the panels by hand.
    """
    days = list(days) if days is not None else representative_days(ch)
    if not days:
        raise ValueError(f"{scenario}: no day-ahead dispatch to plot")

    fig, axes = plt.subplots(1, len(days), figsize=(4.5 * len(days), 3.6),
                             sharex=True, sharey=True)
    axes = np.atleast_1d(axes)
    for j, date in enumerate(days):
        mix = _p24.gate_mix(ch, "da", date)
        if mix.empty or not len(mix.columns):
            raise ValueError(f"{scenario}: no dispatch on {date}; "
                             f"available days are {sorted(ch['gates']['da']['date'].astype(str).unique())}")
        _p24._stack(axes[j], mix, f"{scenario} — {_day_label(date)}",
                    ylabel="MW" if j == 0 else None, xlabel=True)
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=6, bbox_to_anchor=(0.5, -0.18))
    fig.tight_layout()
    return _p24._save(fig, name or f"2035_{scenario.lower()}_da_mix", save)


# ── Matched winter/summer market-chain and AC-redispatch experiment ──────────

def _season_from_date(values):
    """Map the February and June study weeks to display labels."""
    month = pd.to_datetime(values).dt.month
    return pd.Series(np.where(month <= 3, "Winter", "Summer"), index=values.index)


def _market_to_ac_delta(balancing, ac_dispatch):
    """Unit-level BAL-to-AC movement, retaining time for seasonal summaries."""
    keys = ["date", "hour", "gen_id"]
    balancing = _collapse_crossborder(balancing)
    ac_dispatch = _collapse_crossborder(ac_dispatch)
    left = balancing.rename(columns={"category": "category_before", "dispatch_mw": "before"})
    right = ac_dispatch.rename(columns={"category": "category_after", "dispatch_mw": "after"})
    delta = left.merge(right, on=keys, how="outer", validate="one_to_one")
    delta["before"] = delta["before"].fillna(0.0)
    delta["after"] = delta["after"].fillna(0.0)
    delta["category"] = delta["category_after"].fillna(delta["category_before"])
    delta["delta_mw"] = delta["after"] - delta["before"]
    delta["season"] = _season_from_date(delta["date"])
    return delta[["date", "hour", "season", "category", "delta_mw"]]


def _read_ac_dispatch(path):
    """Read AC output using ``unit_name``, the market-stage unit identifier.

    ``gen_dispatch.csv`` also contains a numeric internal ``gen_id``.  That ID
    is not the Gxxxx/XB_xxxx identifier used by the market dispatch files and
    would make every unit appear to be replaced at the BAL-to-AC boundary.
    """
    frame = pd.read_csv(
        path,
        usecols=["date", "hour", "unit_name", "fuel", "technology", "dispatch_mw"],
        dtype={"date": "string", "hour": "int16", "unit_name": "string", "dispatch_mw": "float64"},
    ).rename(columns={"unit_name": "gen_id"})
    frame["category"] = _category(frame)
    return frame[["date", "hour", "gen_id", "category", "dispatch_mw"]]


def build_market_2035_results(scenario_dirs=None, reinforcement_files=None):
    """Build the paper dataset for the matched 2035 summer/winter runs.

    In addition to the copper-plate market metrics produced by
    :func:`build_paper_data`, this reads the final AC solution and reports
    domestic redispatch, fixed-country-total border redistribution, losses,
    voltage feasibility and branch-loading statistics.
    """
    dirs = MARKET_2035_DIRS if scenario_dirs is None else {
        key: Path(value) for key, value in scenario_dirs.items()
    }
    reinforcement_files = (MARKET_2035_REINFORCEMENT if reinforcement_files is None else {
        key: Path(value) for key, value in reinforcement_files.items()
    })
    data = build_paper_data(dirs, require_complete=True)
    redispatch_rows, loading_parts = [], []
    network_rows, kpi_rows, reinforcement_rows = [], [], []

    for scenario in data["scenarios"]:
        root = dirs[scenario]
        summary = pd.read_csv(root / "summary.csv", dtype={"date": "string", "hour": "int16"})
        summary["season"] = _season_from_date(summary["date"])
        total_load = float(summary["total_load_mw"].sum())
        hours = len(summary[["date", "hour"]].drop_duplicates())

        balancing = _read_dispatch(root / "bal_dispatch.csv", root)
        ac_dispatch = _read_ac_dispatch(root / "gen_dispatch.csv")
        delta = _market_to_ac_delta(balancing, ac_dispatch)
        domestic = delta[~delta["category"].isin(["Cross-border", "Load shedding", "Slack"])]
        for (season, category), part in domestic.groupby(["season", "category"], observed=True):
            season_load = float(summary.loc[summary["season"] == season, "total_load_mw"].sum())
            redispatch_rows.append({
                "scenario": scenario,
                "season": season,
                "category": category,
                "up_pct_demand": 100.0 * float(part["delta_mw"].clip(lower=0).sum()) / season_load,
                "down_pct_demand": 100.0 * float(part["delta_mw"].clip(upper=0).sum()) / season_load,
            })
        for category, part in domestic.groupby("category", observed=True):
            redispatch_rows.append({
                "scenario": scenario,
                "season": "Both weeks",
                "category": category,
                "up_pct_demand": 100.0 * float(part["delta_mw"].clip(lower=0).sum()) / total_load,
                "down_pct_demand": 100.0 * float(part["delta_mw"].clip(upper=0).sum()) / total_load,
            })

        branch = pd.read_csv(
            root / "branch_flows.csv",
            usecols=["date", "hour", "branch_id", "branch_name", "asset_class", "loading_pct"],
            dtype={"date": "string", "hour": "int16", "branch_id": "string",
                   "branch_name": "string", "asset_class": "category", "loading_pct": "float32"},
        )
        branch["season"] = _season_from_date(branch["date"])
        loading_parts.append(branch[["season", "loading_pct"]].assign(scenario=scenario))
        for season, part in list(branch.groupby("season", observed=True)) + [("Both weeks", branch)]:
            network_rows.append({
                "scenario": scenario,
                "season": season,
                "branch_hours": len(part),
                "above_50_pct": 100.0 * float((part["loading_pct"] >= 50.0).mean()),
                "above_70_pct": 100.0 * float((part["loading_pct"] >= 70.0).mean()),
                "above_90_pct": 100.0 * float((part["loading_pct"] >= 90.0).mean()),
                "above_100_pct": 100.0 * float((part["loading_pct"] > 100.0 + 1e-6).mean()),
                "peak_loading_pct": float(part["loading_pct"].max()),
                "branches_peak_90": int((part.groupby("branch_id", observed=True)["loading_pct"].max() >= 90.0).sum()),
            })

        voltages = pd.read_csv(root / "bus_voltages.csv", usecols=["vm_pu"])
        xb = pd.read_csv(root / "xb_redispatch.csv")
        xb_country = xb.groupby(["date", "hour", "country"], observed=True)[
            ["da_share_mw", "redispatch_mw"]
        ].sum()
        xb_country_error = (xb_country["redispatch_mw"] - xb_country["da_share_mw"]).abs()
        domestic_gross = float(domestic["delta_mw"].abs().sum())
        loss_mwh = float((summary["total_gen_mw"] - summary["total_load_mw"]).sum())
        kpi_rows.append({
            "scenario": scenario,
            "hours": hours,
            "load_twh": total_load / 1e6,
            "mean_load_gw": total_load / hours / 1000.0,
            "ac_solved_hours": int(summary["status"].isin(["LOCALLY_SOLVED", "OPTIMAL"]).sum()),
            "load_shed_mwh": float(summary["load_shed_mw"].clip(lower=0).sum()),
            "loss_pct_demand": 100.0 * loss_mwh / total_load,
            "domestic_redispatch_pct_demand": 100.0 * domestic_gross / total_load,
            "border_redistribution_pct_demand": 100.0 * float(xb["delta_mw"].abs().sum()) / total_load,
            "max_country_total_border_error_mw": float(xb_country_error.max()),
            "min_voltage_pu": float(voltages["vm_pu"].min()),
            "max_voltage_pu": float(voltages["vm_pu"].max()),
        })

        reinforcement_path = reinforcement_files.get(scenario)
        if reinforcement_path is not None and reinforcement_path.exists():
            reinforcement = pd.read_csv(reinforcement_path)
            asset_lookup = branch[["branch_name", "asset_class"]].drop_duplicates("branch_name")
            classified = reinforcement.merge(asset_lookup, left_on="line_id", right_on="branch_name", how="left")
            reinforcement_rows.append({
                "scenario": scenario,
                "line_scale_entries": len(reinforcement),
                "intra_nuts3_entries": int((classified["asset_class"] == "intra_nuts3").sum()),
                "inter_nuts3_entries": int((classified["asset_class"] == "inter_nuts3").sum()),
                "entries_above_base_rating": int((reinforcement["factor"] > 1.0 + 1e-6).sum()),
                "median_capacity_factor": float(reinforcement["factor"].median()),
                "maximum_capacity_factor": float(reinforcement["factor"].max()),
            })

    operational_kpis = pd.DataFrame(kpi_rows)
    if reinforcement_rows:
        operational_kpis = operational_kpis.merge(pd.DataFrame(reinforcement_rows), on="scenario", how="left")
    data.update({
        "operational_kpis": operational_kpis,
        "redispatch": pd.DataFrame(redispatch_rows),
        "network": pd.DataFrame(network_rows),
        "loading": pd.concat(loading_parts, ignore_index=True),
    })
    return data


def fig_market_outcomes_2035(data, save=False, name="2035_winter_summer_market_outcomes"):
    """Four-panel summary of the matched market-chain results."""
    scenarios = _scenario_order(data)
    fig, axes = plt.subplots(2, 2, figsize=(7.4, 6.2))
    mix_ax, movement_ax, curtail_ax, price_ax = axes.ravel()

    mix = data["mix"]
    mix = mix[(mix["gate"] == "bal") & (mix["direction"] == "supply")]
    categories = _ordered_present(mix["category"], CATEGORY_ORDER)
    x = np.arange(len(scenarios))
    bottom = np.zeros(len(scenarios))
    for category in categories:
        part = mix[mix["category"] == category]
        values = np.array([part.loc[part["scenario"] == scenario, "gwh_per_day"].sum()
                           for scenario in scenarios])
        if np.any(values):
            mix_ax.bar(x, values, bottom=bottom, width=0.65,
                       color=CATEGORY_COLOR.get(category, "#999999"), label=category,
                       edgecolor="white", linewidth=0.2)
            bottom += values
    mix_ax.set_xticks(x, [SCENARIO_LABEL[s] for s in scenarios])
    mix_ax.set_ylabel("Energy [GWh/day]")
    mix_ax.set_title("(a) Balancing-stage supply mix")

    movement = data["movement"]
    transitions = [f"{GATE_LABEL[a]}→{GATE_LABEL[b]}" for a, b in zip(GATES[:-1], GATES[1:])]
    width = 0.8 / len(scenarios)
    tx = np.arange(len(transitions))
    for index, scenario in enumerate(scenarios):
        part = movement[movement["scenario"] == scenario].set_index("transition")
        values = [part["movement_pct_demand"].get(transition, np.nan) for transition in transitions]
        movement_ax.bar(tx + (index - (len(scenarios) - 1) / 2) * width, values,
                        width=width, color=SCENARIO_COLOR[scenario], label=SCENARIO_LABEL[scenario])
    movement_ax.set_xticks(tx, transitions)
    movement_ax.set_ylabel("Gross movement [% demand]")
    movement_ax.set_title("(b) Consecutive-gate rescheduling")
    movement_ax.legend(fontsize=7)

    curtailment = data["curtailment"]
    for scenario in scenarios:
        part = curtailment[curtailment["scenario"] == scenario].set_index("gate")
        curtail_ax.plot(np.arange(len(GATES)), [part["curtailment_pct"].get(g, np.nan) for g in GATES],
                        marker="o", ms=3, color=SCENARIO_COLOR[scenario], label=SCENARIO_LABEL[scenario])
    curtail_ax.set_xticks(np.arange(len(GATES)), [GATE_LABEL[g] for g in GATES])
    curtail_ax.set_ylabel("Available wind + solar curtailed [%]")
    curtail_ax.set_title("(c) VRE curtailment")

    prices = data["prices"]
    for scenario in scenarios:
        values = prices[(prices["scenario"] == scenario) & (prices["stage"] == "DA")]["price_eur_mwh"].dropna()
        ordered = np.sort(values.to_numpy())[::-1]
        price_ax.plot(np.linspace(0, 100, len(ordered)), ordered,
                      color=SCENARIO_COLOR[scenario], label=SCENARIO_LABEL[scenario])
    price_ax.set_xlabel("Share of hours exceeded [%]")
    price_ax.set_ylabel("Spanish DA price [€/MWh]")
    price_ax.set_title("(d) Day-ahead price duration")

    handles, labels = mix_ax.get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=6, bbox_to_anchor=(0.5, -0.01), fontsize=7)
    fig.tight_layout(rect=(0, 0.09, 1, 1))
    return _save(fig, name, save)


def fig_network_redispatch_2035(data, save=False, name="2035_winter_summer_network_redispatch"):
    """Domestic AC redispatch, loading duration, and seasonal congestion."""
    scenarios = _scenario_order(data)
    redispatch = data["redispatch"]
    overall = redispatch[redispatch["season"] == "Both weeks"]
    categories = _ordered_present(overall["category"], CATEGORY_ORDER)
    fig = plt.figure(figsize=(7.4, 6.2))
    grid = fig.add_gridspec(2, 2, height_ratios=[1.1, 1])
    redispatch_axes = [fig.add_subplot(grid[0, i]) for i in range(2)]
    duration_ax = fig.add_subplot(grid[1, 0])
    threshold_ax = fig.add_subplot(grid[1, 1])

    for ax, scenario in zip(redispatch_axes, scenarios):
        part = overall[overall["scenario"] == scenario].set_index("category")
        up = [part["up_pct_demand"].get(category, 0.0) for category in categories]
        down = [part["down_pct_demand"].get(category, 0.0) for category in categories]
        y = np.arange(len(categories))
        ax.barh(y, up, color="#3b8f5a", label="Upward")
        ax.barh(y, down, color="#c6534f", label="Downward")
        ax.axvline(0, color="0.25", lw=0.7)
        ax.set_yticks(y, categories if ax is redispatch_axes[0] else [])
        ax.invert_yaxis()
        ax.set_title(SCENARIO_LABEL[scenario])
        ax.set_xlabel("BAL→AC change [% demand]")
    redispatch_axes[0].legend(fontsize=7, loc="lower right")

    loading = data["loading"]
    for scenario in scenarios:
        values = np.sort(loading.loc[loading["scenario"] == scenario, "loading_pct"].to_numpy())[::-1]
        duration_ax.plot(np.linspace(0, 100, len(values)), values,
                         color=SCENARIO_COLOR[scenario], label=SCENARIO_LABEL[scenario])
    duration_ax.axhline(100, color="0.2", lw=0.7, ls="--")
    duration_ax.set_ylim(bottom=0)
    duration_ax.set_xlabel("Share of branch-hours exceeded [%]")
    duration_ax.set_ylabel("Branch loading [%]")
    duration_ax.set_title("Loading-duration curve")
    duration_ax.legend(fontsize=7)

    network = data["network"]
    seasonal = network[network["season"].isin(["Winter", "Summer"])]
    labels = [f"{SCENARIO_LABEL[s]}\n{season}" for s in scenarios for season in ("Winter", "Summer")]
    positions = np.arange(len(labels))
    for offset, (column, label, color) in enumerate((
        ("above_70_pct", "≥70%", "#e19b35"),
        ("above_90_pct", "≥90%", "#b94b4b"),
    )):
        values = []
        for scenario in scenarios:
            part = seasonal[seasonal["scenario"] == scenario].set_index("season")
            values.extend([part[column].get(season, np.nan) for season in ("Winter", "Summer")])
        threshold_ax.bar(positions + (offset - 0.5) * 0.36, values, width=0.36, color=color, label=label)
    threshold_ax.set_xticks(positions, labels, rotation=20, ha="right")
    threshold_ax.set_ylabel("Branch-hours [%]")
    threshold_ax.set_title("Seasonal high-loading exposure")
    threshold_ax.legend(fontsize=7)
    fig.suptitle("AC redispatch and network feasibility", y=0.995)
    fig.tight_layout()
    return _save(fig, name, save)


def fig_reinforcement_sensitivity_2035(
        path=ROOT / "docs" / "paper_grid_reinforcement_sensitivity.csv",
        save=False,
        name="2035_reinforcement_sensitivity"):
    """Near-binding domestic branches in the two-stage DC sizing sweep."""
    frame = pd.read_csv(path)
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.25), sharey=False)
    specifications = (
        ("inter", "inter_multiplier", "inter_lines_gt95", "(a) Inter-NUTS3 sweep"),
        ("intra", "intra_multiplier", "intra_lines_gt95", "(b) Intra-NUTS3 sweep"),
    )
    selected = {("NECPEssentials", "inter"): 5.0, ("Trinity", "inter"): 3.0,
                ("NECPEssentials", "intra"): 3.0, ("Trinity", "intra"): 2.5}
    for ax, (sweep, x_column, y_column, title) in zip(axes, specifications):
        for scenario in ("NECPEssentials", "Trinity"):
            part = frame[(frame["scenario"] == scenario) & (frame["sweep"] == sweep)].copy()
            # NECP's 5x inter point is recorded by every row of the following
            # intra sweep; add its common zero count to close the curve.
            if scenario == "NECPEssentials" and sweep == "inter":
                follow = frame[(frame["scenario"] == scenario) & (frame["sweep"] == "intra")]
                if not follow.empty:
                    part = pd.concat([part, pd.DataFrame([{x_column: 5.0, y_column: int(follow[y_column].iloc[0])}])])
            part = part.sort_values(x_column)
            ax.plot(part[x_column], part[y_column], marker="o", ms=4,
                    color=SCENARIO_COLOR[scenario], label=SCENARIO_LABEL[scenario])
            choice = selected[(scenario, sweep)]
            ax.axvline(choice, color=SCENARIO_COLOR[scenario], ls=":", lw=0.9, alpha=0.8)
        ax.axhline(0, color="0.25", lw=0.6)
        ax.set_xlabel("Diagnostic capacity multiplier")
        ax.set_title(title)
        ax.set_ylim(bottom=-0.5)
    for ax in axes:
        ax.set_ylabel("Domestic branches above 95% loading")
    axes[0].legend(fontsize=7)
    fig.tight_layout()
    return _save(fig, name, save)


def export_market_2035_results(data):
    """Export the figures and reproducible KPI tables used by the paper text."""
    figure_specs = [
        (fig_reinforcement_sensitivity_2035(save=True), "2035_reinforcement_sensitivity"),
        (fig_market_outcomes_2035(data, save=True), "2035_winter_summer_market_outcomes"),
        (fig_network_redispatch_2035(data, save=True), "2035_winter_summer_network_redispatch"),
    ]
    figures = []
    for figure, name in figure_specs:
        figures.append(figure)
        preview = FIG_DIR / f"{name}.png"
        figure.savefig(preview, dpi=180)
        print("wrote", preview.relative_to(ROOT))
    TABLE_DIR.mkdir(parents=True, exist_ok=True)
    tables = {
        "paper_2035_market_kpis.csv": headline_table(data).reset_index(),
        "paper_2035_gate_movement.csv": data["movement"],
        "paper_2035_vre_curtailment.csv": data["curtailment"],
        "paper_2035_balancing_mix.csv": data["mix"].query("gate == 'bal'"),
        "paper_2035_operational_kpis.csv": data["operational_kpis"],
        "paper_2035_redispatch_by_fuel.csv": data["redispatch"],
        "paper_2035_network_loading.csv": data["network"],
    }
    for filename, table in tables.items():
        path = TABLE_DIR / filename
        table.to_csv(path, index=False)
        print("wrote", path.relative_to(ROOT))
    return figures


def export_all(data):
    """Write every paper-ready PDF and the headline KPI CSV.

    Core export is blocked until all four scenario runs cover the same hours.
    The price panel is exported only when every scenario also has price output.
    """
    if not data["audit"]["core_ready"]:
        raise RuntimeError("Export blocked: all four scenarios must pass the coverage audit.")
    figures = [
        fig_balancing_mix(data, save=True),
        fig_gate_movement(data, save=True),
        fig_adjustment_by_fuel(data, save=True),
        fig_curtailment(data, save=True),
    ]
    if data["audit"]["price_ready"]:
        figures.append(fig_prices(data, save=True))
    else:
        print("price PDF skipped: at least one scenario has no price output")
    TABLE_DIR.mkdir(parents=True, exist_ok=True)
    table_path = TABLE_DIR / "paper_2035_scenario_kpis.csv"
    headline_table(data).to_csv(table_path)
    print("wrote", table_path.relative_to(ROOT))
    return figures


if __name__ == "__main__":
    use_paper_style()
    market_2035 = build_market_2035_results()
    print(print_audit(market_2035["audit"]))
    print("\nMarket KPIs\n", headline_table(market_2035))
    print("\nOperational KPIs\n", market_2035["operational_kpis"].round(4))
    export_market_2035_results(market_2035)
