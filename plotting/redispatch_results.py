"""Reusable analysis and mapping helpers for redispatch_results.ipynb.

The plotting notebook deliberately keeps its cells short.  Data validation,
AC/DC run detection, comparisons with the redispatch anchor, Plotly figures,
and the self-contained Folium map live here so they can be tested without
having to execute a notebook interactively.
"""

from __future__ import annotations

import json
import math
from html import escape
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import folium
import numpy as np
import pandas as pd
import plotly.graph_objects as go
from plotly.subplots import make_subplots


SCENARIOS = ("2024", "GoRES", "NECPEssentials", "REPowerEU++", "Trinity")
POWER_FLOWS = ("AC", "DC")
SCENARIO_YEARS = {scenario: (2024 if scenario == "2024" else 2035) for scenario in SCENARIOS}
REQUIRED_OUTPUTS = (
    "summary.csv",
    "gen_dispatch.csv",
    "branch_flows.csv",
    "bus_voltages.csv",
)

FUEL_COLORS = {
    "Nuclear": "#7b1fa2",
    "Hydro": "#1976d2",
    "Wind": "#43a047",
    "Solar": "#f9a825",
    "Gas": "#ef6c00",
    "Coal": "#5d4037",
    "Oil": "#37474f",
    "Biomass": "#8bc34a",
    "Battery": "#00acc1",
    "CrossBorder": "#607d8b",
    "Other": "#9e9e9e",
}


def project_root(start: str | Path | None = None) -> Path:
    """Find the repository root from a notebook or module working directory."""
    here = Path(start or Path.cwd()).resolve()
    for candidate in (here, *here.parents):
        if (candidate / "config.toml").exists() and (candidate / "Data").is_dir():
            return candidate
    raise FileNotFoundError(
        f"Could not find project root above {here}; expected config.toml and Data/."
    )


def _has_outputs(path: Path) -> bool:
    return path.is_dir() and all((path / name).exists() for name in REQUIRED_OUTPUTS)


def detect_power_flow(path: str | Path) -> str | None:
    """Infer whether a result directory contains AC or DC redispatch outputs.

    DC output intentionally writes ``vm_pu=1`` and ``flow_mvar=0`` placeholders.
    Any non-trivial voltage-magnitude deviation or reactive branch flow therefore
    identifies an AC result.  An optional ``redispatch_metadata.json`` can make
    the identification explicit for future archived runs.
    """
    path = Path(path)
    metadata = path / "redispatch_metadata.json"
    if metadata.exists():
        try:
            value = str(json.loads(metadata.read_text(encoding="utf-8"))["power_flow"]).upper()
            if value in POWER_FLOWS:
                return value
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            pass

    voltage_file, flow_file = path / "bus_voltages.csv", path / "branch_flows.csv"
    if not voltage_file.exists() or not flow_file.exists():
        return None

    saw_numeric = False
    try:
        for chunk in pd.read_csv(voltage_file, usecols=["vm_pu"], chunksize=100_000):
            vm = pd.to_numeric(chunk["vm_pu"], errors="coerce").dropna()
            saw_numeric = saw_numeric or not vm.empty
            if ((vm - 1.0).abs() > 1e-5).any():
                return "AC"
        for chunk in pd.read_csv(flow_file, usecols=["flow_mvar"], chunksize=100_000):
            q = pd.to_numeric(chunk["flow_mvar"], errors="coerce").dropna()
            saw_numeric = saw_numeric or not q.empty
            if (q.abs() > 1e-4).any():
                return "AC"
    except (pd.errors.EmptyDataError, ValueError, KeyError):
        return None
    return "DC" if saw_numeric else None


def _candidate_result_dirs(root: Path, scenario: str, power_flow: str) -> list[Path]:
    """Return canonical, alternative, and legacy result locations in priority order."""
    pf, scenario = power_flow.upper(), str(scenario)
    candidates = [
        root / "results" / scenario / pf,       # canonical archive layout
        root / "results" / pf / scenario,
        root / "results" / f"{scenario}_{pf}",
        root / "results" / f"{scenario}-{pf}",
    ]
    if scenario == "2024":
        candidates.extend([root / "results" / pf, root / "results"])
    else:
        candidates.append(root / "results" / scenario)
    return list(dict.fromkeys(candidates))


def resolve_results_dir(
    root: str | Path, scenario: str, power_flow: str, *, strict: bool = True
) -> Path | None:
    """Resolve a selected run without ever labelling DC placeholders as AC results."""
    root, pf = Path(root), power_flow.upper()
    if scenario not in SCENARIOS:
        raise ValueError(f"scenario must be one of {SCENARIOS}; got {scenario!r}")
    if pf not in POWER_FLOWS:
        raise ValueError(f"power_flow must be AC or DC; got {power_flow!r}")

    mismatches: list[tuple[Path, str | None]] = []
    for candidate in _candidate_result_dirs(root, scenario, pf):
        if not _has_outputs(candidate):
            continue
        detected = detect_power_flow(candidate)
        if detected == pf:
            return candidate
        mismatches.append((candidate, detected))

    if not strict:
        return None
    details = "\n".join(f"  - {p} (detected {kind or 'unknown'})" for p, kind in mismatches)
    canonical = root / "results" / scenario / pf
    raise FileNotFoundError(
        f"No {pf} redispatch output found for {scenario}.\n"
        f"Archive that run at {canonical} (set SPAIN_RESULTS to this directory when running Julia)."
        + (f"\nExisting incompatible output(s):\n{details}" if details else "")
    )


def available_runs(root: str | Path | None = None) -> pd.DataFrame:
    """Tabulate which scenario/power-flow combinations can currently be loaded."""
    root = project_root(root)
    rows = []
    for scenario in SCENARIOS:
        for pf in POWER_FLOWS:
            path = resolve_results_dir(root, scenario, pf, strict=False)
            rows.append(
                {
                    "scenario": scenario,
                    "power_flow": pf,
                    "available": path is not None,
                    "results_directory": str(path.relative_to(root)) if path else "",
                }
            )
    return pd.DataFrame(rows)


def _read_output(path: Path, name: str, *, required: bool = True) -> pd.DataFrame:
    file = path / name
    if not file.exists():
        if required:
            raise FileNotFoundError(file)
        return pd.DataFrame()
    frame = pd.read_csv(file)
    if "date" in frame.columns:
        frame["date"] = frame["date"].astype(str)
    if "hour" in frame.columns:
        frame["hour"] = pd.to_numeric(frame["hour"], errors="raise").astype(int)
        frame["timestamp"] = pd.to_datetime(frame["date"]) + pd.to_timedelta(frame["hour"], unit="h")
    return frame


def _read_static(root: Path, name: str, **kwargs) -> pd.DataFrame:
    return pd.read_csv(root / "Data" / name, **kwargs)


def _prepare_generation_changes(rd: pd.DataFrame, anchor: pd.DataFrame) -> pd.DataFrame:
    rd_cols = [
        "date", "hour", "timestamp", "unit_name", "fuel", "technology", "bus_i",
        "capacity_mw", "dispatch_mw", "dispatch_mvar", "utilization_pct",
        "cost_eur_per_mwh",
    ]
    rd_work = rd[[c for c in rd_cols if c in rd.columns]].copy()
    rd_work["unit_name"] = rd_work["unit_name"].astype(str)
    rd_work = rd_work.rename(columns={"dispatch_mw": "redispatch_mw"})

    anchor_work = anchor[["date", "hour", "gen_id", "dispatch_mw"]].copy()
    anchor_work["gen_id"] = anchor_work["gen_id"].astype(str)
    anchor_work = (
        anchor_work.groupby(["date", "hour", "gen_id"], as_index=False)["dispatch_mw"].sum()
        .rename(columns={"gen_id": "unit_name", "dispatch_mw": "anchor_mw"})
    )
    changes = rd_work.merge(anchor_work, on=["date", "hour", "unit_name"], how="left")
    changes["anchor_mw"] = changes["anchor_mw"].fillna(0.0)
    changes["delta_mw"] = changes["redispatch_mw"] - changes["anchor_mw"]
    changes["abs_delta_mw"] = changes["delta_mw"].abs()
    changes["direction"] = np.select(
        [changes["delta_mw"] > 1e-6, changes["delta_mw"] < -1e-6],
        ["Up", "Down"],
        default="Unchanged",
    )
    return changes


@dataclass
class RedispatchRun:
    root: Path
    results_dir: Path
    scenario: str
    power_flow: str
    anchor_stage: str
    summary: pd.DataFrame
    generation: pd.DataFrame
    anchor: pd.DataFrame
    generation_changes: pd.DataFrame
    branch_flows: pd.DataFrame
    bus_voltages: pd.DataFrame
    fuel_mix: pd.DataFrame
    buses: pd.DataFrame
    lines: pd.DataFrame
    transformers: pd.DataFrame
    generators: pd.DataFrame
    loads: pd.DataFrame

    @property
    def timestamps(self) -> pd.DatetimeIndex:
        values = self.summary["timestamp"].drop_duplicates().sort_values()
        return pd.DatetimeIndex(values)

    @property
    def dates(self) -> list[str]:
        return sorted(self.summary["date"].unique().tolist())

    @property
    def scenario_year(self) -> int:
        return SCENARIO_YEARS.get(self.scenario, 2024)

    @property
    def label(self) -> str:
        return f"{self.scenario} {self.scenario_year}" if self.scenario != "2024" else "2024"

    def describe(self) -> pd.DataFrame:
        return run_summary(self)


def load_run(
    scenario: str = "2024",
    power_flow: str = "DC",
    anchor_stage: str = "bal",
    root: str | Path | None = None,
) -> RedispatchRun:
    """Load and validate one scenario/AC-DC selection."""
    root = project_root(root)
    results_dir = resolve_results_dir(root, scenario, power_flow)
    stage = anchor_stage.lower()
    if stage not in {"da", "id2", "id3", "cid", "bal"}:
        raise ValueError("anchor_stage must be one of da, id2, id3, cid, bal")

    summary = _read_output(results_dir, "summary.csv")
    generation = _read_output(results_dir, "gen_dispatch.csv")
    anchor = _read_output(results_dir, f"{stage}_dispatch.csv")
    branch_flows = _read_output(results_dir, "branch_flows.csv")
    bus_voltages = _read_output(results_dir, "bus_voltages.csv")
    fuel_mix = _read_output(results_dir, "fuel_mix.csv", required=False)

    required_columns = {
        "summary.csv": (summary, {"date", "hour", "status", "objective_eur_h", "load_shed_mw"}),
        "gen_dispatch.csv": (generation, {"date", "hour", "unit_name", "dispatch_mw", "bus_i"}),
        "branch_flows.csv": (branch_flows, {"date", "hour", "branch_name", "loading_pct"}),
        "bus_voltages.csv": (bus_voltages, {"date", "hour", "bus_id", "vm_pu", "va_deg"}),
    }
    for name, (frame, columns) in required_columns.items():
        missing = columns - set(frame.columns)
        if missing:
            raise ValueError(f"{results_dir / name} is missing columns: {sorted(missing)}")

    changes = _prepare_generation_changes(generation, anchor)
    buses = _read_static(root, "Bus_Data.csv", encoding="utf-8-sig")
    buses["bus_i"] = np.arange(1, len(buses) + 1)
    lines = _read_static(root, "lines.csv")
    transformers = _read_static(root, "transformers_reactance.csv")
    generators = _read_static(root, "generations.csv")
    loads = _read_static(root, "load.csv")

    return RedispatchRun(
        root=root,
        results_dir=results_dir,
        scenario=scenario,
        power_flow=power_flow.upper(),
        anchor_stage=stage.upper(),
        summary=summary,
        generation=generation,
        anchor=anchor,
        generation_changes=changes,
        branch_flows=branch_flows,
        bus_voltages=bus_voltages,
        fuel_mix=fuel_mix,
        buses=buses,
        lines=lines,
        transformers=transformers,
        generators=generators,
        loads=loads,
    )


def _date_filter(frame: pd.DataFrame, date: str | None) -> pd.DataFrame:
    return frame if date in (None, "All") else frame[frame["date"] == str(date)]


def display_date(run: RedispatchRun, raw_date: str | pd.Timestamp, *, show_source: bool = False) -> str:
    """Format the scenario date while retaining the profile-source date on request."""
    value = pd.Timestamp(raw_date)
    if run.scenario == "2024":
        return value.strftime("%Y-%m-%d")
    scenario_date = f"{run.scenario_year:04d}-{value.month:02d}-{value.day:02d}"
    if show_source:
        return f"{scenario_date} (profile source {value:%Y-%m-%d})"
    return scenario_date


def display_timestamp(
    run: RedispatchRun, timestamp: str | pd.Timestamp, *, show_source: bool = False
) -> str:
    value = pd.Timestamp(timestamp)
    label = f"{display_date(run, value)} {value.hour:02d}:00"
    if show_source and run.scenario != "2024":
        label += f" (profile source {value:%Y-%m-%d %H}:00)"
    return label


def date_selector_options(run: RedispatchRun, *, include_all: bool = True) -> list[tuple[str, str]]:
    """Notebook-ready (visible label, raw value) options for profile dates."""
    options = [(display_date(run, date, show_source=run.scenario != "2024"), date) for date in run.dates]
    return ([('All profile days', 'All')] if include_all else []) + options


def _profile_axis(run: RedispatchRun, timestamps: Iterable[pd.Timestamp]) -> dict:
    """Build a compact sequential time axis so representative days are not joined across months."""
    times = pd.DatetimeIndex(sorted(pd.Timestamp(value) for value in set(timestamps)))
    positions = np.arange(len(times), dtype=float)
    lookup = {timestamp: float(position) for timestamp, position in zip(times, positions)}
    days = list(dict.fromkeys(timestamp.normalize() for timestamp in times))
    day_positions = [int(np.flatnonzero(times.normalize() == day)[0]) for day in days]

    tick_values: list[float] = []
    tick_text: list[str] = []
    if len(days) <= 2:
        for index, timestamp in enumerate(times):
            if timestamp.hour % 6 != 0:
                continue
            tick_values.append(float(index))
            tick_text.append(
                f"{display_date(run, timestamp)}<br>{timestamp.hour:02d}:00"
                if timestamp.hour == 0 else f"{timestamp.hour:02d}:00"
            )
    elif len(days) <= 7:
        for index, timestamp in enumerate(times):
            if timestamp.hour not in (0, 12):
                continue
            tick_values.append(float(index))
            tick_text.append(
                f"{display_date(run, timestamp)}<br>00:00"
                if timestamp.hour == 0 else "12:00"
            )
    else:
        stride = max(1, math.ceil(len(days) / 7))
        for day_index, position in enumerate(day_positions):
            if day_index % stride == 0 or day_index == len(days) - 1:
                tick_values.append(float(position))
                tick_text.append(display_date(run, times[position]))

    separators = [float(position) - 0.5 for position in day_positions[1:]]
    return {
        "run": run,
        "times": times,
        "positions": positions,
        "lookup": lookup,
        "tick_values": tick_values,
        "tick_text": tick_text,
        "separators": separators,
        "hover_labels": [display_timestamp(run, timestamp, show_source=run.scenario != "2024") for timestamp in times],
    }


def _series_with_day_gaps(series: pd.Series, axis: dict) -> tuple[list, list, list]:
    """Convert a timestamp-indexed series to a numeric x-axis with gaps between profile days."""
    x_values: list[float | None] = []
    y_values: list[float | None] = []
    hover: list[str | None] = []
    previous_day = None
    for timestamp, value in series.sort_index().items():
        timestamp = pd.Timestamp(timestamp)
        current_day = timestamp.normalize()
        if previous_day is not None and current_day != previous_day:
            x_values.append(None)
            y_values.append(None)
            hover.append(None)
        x_values.append(axis["lookup"][timestamp])
        y_values.append(None if pd.isna(value) else float(value))
        hover.append(display_timestamp(run=axis["run"], timestamp=timestamp, show_source=axis["run"].scenario != "2024"))
        previous_day = current_day
    return x_values, y_values, hover


def _set_profile_axis(fig: go.Figure, axis: dict, *, row: int, col: int) -> None:
    fig.update_xaxes(
        tickmode="array", tickvals=axis["tick_values"], ticktext=axis["tick_text"],
        range=[-0.5, max(len(axis["times"]) - 0.5, 0.5)], fixedrange=False,
        row=row, col=col,
    )
    for separator in axis["separators"]:
        fig.add_vline(x=separator, line_color="#bdbdbd", line_dash="dot", line_width=1, row=row, col=col)


def run_summary(run: RedispatchRun, congestion_threshold: float = 99.9) -> pd.DataFrame:
    """Return a compact KPI board for the selected redispatch run."""
    changes = run.generation_changes
    physical = changes[~changes["fuel"].astype(str).isin(["LoadShed", "Slack"])]
    up = physical["delta_mw"].clip(lower=0).sum()
    down = -physical["delta_mw"].clip(upper=0).sum()
    flow = run.branch_flows
    voltage = run.bus_voltages
    congested = flow[flow["loading_pct"] >= congestion_threshold]
    load_shed = pd.to_numeric(run.summary["load_shed_mw"], errors="coerce").fillna(0).sum()
    objective = pd.to_numeric(run.summary["objective_eur_h"], errors="coerce").sum()
    metrics = [
        ("Scenario", run.label, ""),
        ("Profile days", ", ".join(display_date(run, date) for date in run.dates), ""),
        ("Power flow", run.power_flow, ""),
        ("Redispatch anchor", run.anchor_stage, ""),
        ("Solved hours", int(run.summary["timestamp"].nunique()), "h"),
        ("Upward redispatch", up, "MWh"),
        ("Downward redispatch", down, "MWh"),
        ("Total unit movement", physical["abs_delta_mw"].sum(), "MWh"),
        ("Redispatch objective", objective, "EUR"),
        ("Load shedding", load_shed, "MWh"),
        ("Peak branch loading", pd.to_numeric(flow["loading_pct"], errors="coerce").max(), "%"),
        (f"Branch-hours >= {congestion_threshold:g}%", len(congested), "branch-h"),
        ("Congested branches", congested["branch_name"].nunique(), "branches"),
        ("Maximum angle spread", voltage.groupby("timestamp")["va_deg"].agg(lambda x: x.max() - x.min()).max(), "deg"),
    ]
    if run.power_flow == "AC":
        vm = pd.to_numeric(voltage["vm_pu"], errors="coerce")
        metrics.extend(
            [
                ("Minimum voltage", vm.min(), "p.u."),
                ("Maximum voltage", vm.max(), "p.u."),
                ("Voltage observations outside 0.95-1.05", int(((vm < 0.95) | (vm > 1.05)).sum()), "bus-h"),
            ]
        )
    else:
        metrics.append(("Voltage magnitude", "not available in DC", ""))
    return pd.DataFrame(metrics, columns=["metric", "value", "unit"])


def generation_figure(run: RedispatchRun, date: str | None = None) -> go.Figure:
    """Four complementary views of how redispatch changed unit output."""
    data = _date_filter(run.generation_changes, date)
    data = data[~data["fuel"].astype(str).isin(["LoadShed", "Slack"])]
    hourly = data.groupby("timestamp")["delta_mw"].agg(
        upward=lambda x: x.clip(lower=0).sum(),
        downward=lambda x: -x.clip(upper=0).sum(),
    )
    fuel = data.groupby("fuel")["delta_mw"].agg(
        upward=lambda x: x.clip(lower=0).sum(),
        downward=lambda x: -x.clip(upper=0).sum(),
        net="sum",
    )
    fuel["movement"] = fuel["upward"] + fuel["downward"]
    fuel = fuel.sort_values("movement")
    units = data.groupby(["unit_name", "fuel"], as_index=False).agg(
        movement=("abs_delta_mw", "sum"), net=("delta_mw", "sum")
    ).nlargest(18, "movement").sort_values("movement")
    energy = data.groupby(["unit_name", "fuel"], as_index=False).agg(
        anchor=("anchor_mw", "sum"), redispatch=("redispatch_mw", "sum")
    )
    axis = _profile_axis(run, hourly.index)
    up_x, up_y, up_hover = _series_with_day_gaps(hourly["upward"], axis)
    down_x, down_y, down_hover = _series_with_day_gaps(hourly["downward"], axis)
    down_y = [None if value is None else -value for value in down_y]

    fig = make_subplots(
        rows=2, cols=2,
        subplot_titles=("Hourly movement (up: +red; down: −blue)", "Movement by fuel (up: +red; down: −blue)",
                        "Units with the largest movement", "Unit energy: anchor vs redispatch"),
        horizontal_spacing=0.16, vertical_spacing=0.17,
    )
    fig.add_trace(go.Scatter(
        x=up_x, y=up_y, customdata=up_hover, name="Upward", showlegend=False,
        line=dict(color="#d73027", width=2),
        hovertemplate="%{customdata}<br>upward=%{y:,.1f} MW<extra></extra>",
    ), row=1, col=1)
    fig.add_trace(go.Scatter(
        x=down_x, y=down_y, customdata=down_hover, name="Downward", showlegend=False,
        line=dict(color="#4575b4", width=2),
        hovertemplate="%{customdata}<br>downward=%{y:,.1f} MW<extra></extra>",
    ), row=1, col=1)
    fig.add_trace(go.Bar(
        x=fuel["upward"], y=fuel.index, orientation="h", marker_color="#d73027", showlegend=False,
        hovertemplate="%{y}<br>upward=%{x:,.1f} MWh<extra></extra>",
    ), row=1, col=2)
    fig.add_trace(go.Bar(
        x=-fuel["downward"], y=fuel.index, orientation="h", marker_color="#4575b4", showlegend=False,
        customdata=fuel["downward"], hovertemplate="%{y}<br>downward=%{customdata:,.1f} MWh<extra></extra>",
    ), row=1, col=2)
    fig.add_trace(go.Bar(
        x=units["movement"], y=units["unit_name"], orientation="h", showlegend=False,
        marker_color=[FUEL_COLORS.get(f, FUEL_COLORS["Other"]) for f in units["fuel"]],
        customdata=np.c_[units["fuel"], units["net"]],
        hovertemplate="%{y}<br>%{customdata[0]}<br>movement=%{x:.1f} MWh<br>net=%{customdata[1]:.1f} MWh<extra></extra>",
    ), row=2, col=1)
    for fuel_name, group in energy.groupby("fuel"):
        fig.add_trace(go.Scatter(
            x=group["anchor"], y=group["redispatch"], mode="markers", name=str(fuel_name),
            showlegend=False, marker=dict(color=FUEL_COLORS.get(str(fuel_name), FUEL_COLORS["Other"]), size=7, opacity=0.7),
            text=group["unit_name"], hovertemplate="%{text}<br>anchor=%{x:.1f} MWh<br>redispatch=%{y:.1f} MWh<extra></extra>",
        ), row=2, col=2)
    energy_min = min(float(energy[["anchor", "redispatch"]].min().min()), 0.0)
    energy_max = max(float(energy[["anchor", "redispatch"]].max().max()), 1.0)
    energy_pad = max((energy_max - energy_min) * 0.03, 1.0)
    identity_min, identity_max = energy_min - energy_pad, energy_max + energy_pad
    fig.add_trace(go.Scatter(
        x=[identity_min, identity_max], y=[identity_min, identity_max], mode="lines",
        line=dict(color="#555", dash="dash"), showlegend=False, hoverinfo="skip",
    ), row=2, col=2)
    fig.update_layout(
        title=dict(text=f"Generation redispatch — {run.label} / {run.power_flow} (anchor: {run.anchor_stage})", x=0.01),
        template="plotly_white", barmode="relative", height=900,
        margin=dict(l=145, r=35, t=85, b=65), showlegend=False,
    )
    fig.update_yaxes(title_text="MW", row=1, col=1)
    fig.update_xaxes(title_text="redispatch movement [MWh]", row=1, col=2)
    fig.update_xaxes(title_text="total |change| [MWh]", row=2, col=1)
    fig.update_xaxes(title_text="anchor energy [MWh]", row=2, col=2)
    fig.update_yaxes(title_text="redispatch energy [MWh]", row=2, col=2)
    fig.update_yaxes(automargin=True)
    _set_profile_axis(fig, axis, row=1, col=1)
    return fig


def transmission_figure(
    run: RedispatchRun, date: str | None = None, congestion_threshold: float = 99.9
) -> go.Figure:
    """Loading duration, congestion exposure, heatmap, and system stress."""
    data = _date_filter(run.branch_flows, date).copy()
    data["loading_pct"] = pd.to_numeric(data["loading_pct"], errors="coerce")
    stats = data.groupby("branch_name").agg(
        peak=("loading_pct", "max"), mean=("loading_pct", "mean"),
        congested_hours=("loading_pct", lambda x: int((x >= congestion_threshold).sum())),
        limit_mw=("limit_mw", "max"),
    ).sort_values("peak", ascending=False)
    top = stats.head(20).sort_values("peak")
    congested = stats[stats["congested_hours"] > 0].head(20).sort_values("congested_hours")
    heat_ids = stats.head(18).index
    heat = data[data["branch_name"].isin(heat_ids)].pivot_table(
        index="branch_name", columns="timestamp", values="loading_pct", aggfunc="max"
    ).reindex(heat_ids)
    system = data.groupby("timestamp")["loading_pct"].agg(
        maximum="max", p95=lambda x: x.quantile(0.95), median="median"
    )
    axis = _profile_axis(run, system.index)
    heat = heat.reindex(columns=axis["times"])

    fig = make_subplots(
        rows=2, cols=2,
        subplot_titles=("Highest branch loading", "Congestion exposure",
                        "Loading of the most stressed branches",
                        "System envelope (max: red; p95: orange; median: blue)"),
        vertical_spacing=0.18, horizontal_spacing=0.16,
    )
    fig.add_trace(go.Bar(
        x=top["peak"], y=top.index, orientation="h", showlegend=False,
        marker=dict(color=top["peak"], colorscale="YlOrRd", cmin=0, cmax=max(100, top["peak"].max())),
        customdata=np.c_[top["mean"], top["limit_mw"]],
        hovertemplate="%{y}<br>peak=%{x:.1f}%<br>mean=%{customdata[0]:.1f}%<br>limit=%{customdata[1]:.0f} MW<extra></extra>",
    ), row=1, col=1)
    fig.add_vline(x=congestion_threshold, line_color="#d73027", line_dash="dash", row=1, col=1)
    if not congested.empty:
        fig.add_trace(go.Bar(x=congested["congested_hours"], y=congested.index, orientation="h", marker_color="#d73027", showlegend=False), row=1, col=2)
    else:
        fig.add_annotation(
            text=f"No branch reached {congestion_threshold:g}%", x=0.5, y=0.5,
            xref="x2 domain", yref="y2 domain", showarrow=False, row=1, col=2,
        )
    fig.add_trace(go.Heatmap(
        x=axis["positions"], y=heat.index, z=heat.values, colorscale="Turbo", zmin=0,
        zmax=max(100, float(np.nanmax(heat.values)) if heat.size else 100),
        colorbar=dict(title="loading %", len=0.34, y=0.21, x=0.47, thickness=12),
        customdata=np.tile(np.asarray(axis["hover_labels"], dtype=object), (len(heat.index), 1)),
        hovertemplate="%{y}<br>%{customdata}<br>loading=%{z:.1f}%<extra></extra>",
    ), row=2, col=1)
    for column, color in (("maximum", "#d73027"), ("p95", "#fc8d59"), ("median", "#4575b4")):
        x_values, y_values, hover = _series_with_day_gaps(system[column], axis)
        fig.add_trace(go.Scatter(
            x=x_values, y=y_values, customdata=hover, name=column, showlegend=False,
            line=dict(color=color, width=2),
            hovertemplate=f"%{{customdata}}<br>{column}=%{{y:.1f}}%<extra></extra>",
        ), row=2, col=2)
    fig.add_hline(y=congestion_threshold, line_color="#d73027", line_dash="dash", row=2, col=2)
    fig.update_layout(
        title=dict(text=f"Transmission utilization and congestion — {run.label} / {run.power_flow}", x=0.01),
        template="plotly_white", height=930, margin=dict(l=145, r=45, t=85, b=65), showlegend=False,
    )
    fig.update_xaxes(title_text="loading [%]", row=1, col=1)
    fig.update_xaxes(title_text="congested hours", row=1, col=2)
    fig.update_yaxes(title_text="loading [%]", row=2, col=2)
    fig.update_yaxes(automargin=True)
    _set_profile_axis(fig, axis, row=2, col=1)
    _set_profile_axis(fig, axis, row=2, col=2)
    return fig


def voltage_angle_figure(run: RedispatchRun, date: str | None = None) -> go.Figure:
    """Voltage quality for AC runs and angle stress for both formulations."""
    data = _date_filter(run.bus_voltages, date).copy()
    data["vm_pu"] = pd.to_numeric(data["vm_pu"], errors="coerce")
    data["va_deg"] = pd.to_numeric(data["va_deg"], errors="coerce")
    angle = data.groupby("timestamp")["va_deg"].agg(minimum="min", maximum="max", mean="mean")
    angle["span"] = angle["maximum"] - angle["minimum"]
    axis = _profile_axis(run, angle.index)

    if run.power_flow == "DC":
        by_bus = data.groupby("bus_id")["va_deg"].agg(
            max_abs=lambda x: x.abs().max(), mean="mean"
        ).nlargest(20, "max_abs").sort_values("max_abs")
        fig = make_subplots(
            rows=1, cols=2,
            subplot_titles=("Angle envelope (max: red; min: blue; span: purple)",
                            "Buses with largest absolute angle"),
            horizontal_spacing=0.17,
        )
        for column, color, dash in (
            ("maximum", "#d73027", "solid"), ("minimum", "#4575b4", "solid"),
            ("span", "#7b3294", "dash"),
        ):
            x_values, y_values, hover = _series_with_day_gaps(angle[column], axis)
            fig.add_trace(go.Scatter(
                x=x_values, y=y_values, customdata=hover, name=column, showlegend=False,
                line=dict(color=color, dash=dash, width=2),
                hovertemplate=f"%{{customdata}}<br>{column}=%{{y:.2f}} deg<extra></extra>",
            ), row=1, col=1)
        fig.add_trace(go.Bar(x=by_bus["max_abs"], y=by_bus.index, orientation="h", marker_color="#7b3294", showlegend=False), row=1, col=2)
        fig.update_layout(
            title=dict(
                text=f"Voltage angles — {run.label} / DC<br><sup>DC OPF does not model voltage magnitude or reactive power.</sup>",
                x=0.01,
            ),
            template="plotly_white", height=650, margin=dict(l=95, r=35, t=105, b=65),
            showlegend=False,
        )
        fig.update_yaxes(title_text="degrees", row=1, col=1)
        fig.update_xaxes(title_text="maximum |angle| [deg]", row=1, col=2)
        fig.update_yaxes(automargin=True)
        _set_profile_axis(fig, axis, row=1, col=1)
        return fig

    voltage = data.groupby("timestamp")["vm_pu"].agg(minimum="min", maximum="max", mean="mean")
    data["deviation"] = (data["vm_pu"] - 1.0).abs()
    stressed = data.groupby("bus_id")["deviation"].max().nlargest(18).index
    heat = data[data["bus_id"].isin(stressed)].pivot_table(
        index="bus_id", columns="timestamp", values="vm_pu"
    ).reindex(index=stressed, columns=axis["times"])
    violation_counts = data.assign(
        band=np.select([data["vm_pu"] < 0.95, data["vm_pu"] > 1.05], ["< 0.95", "> 1.05"], default="within band")
    )["band"].value_counts()
    band_order = ["within band", "< 0.95", "> 1.05"]
    violations = violation_counts.reindex(band_order, fill_value=0)
    violations = violations[violations > 0]

    fig = make_subplots(
        rows=2, cols=2,
        specs=[[{}, {"type": "domain"}], [{}, {}]],
        subplot_titles=("Voltage envelope (max: red; mean: grey; min: blue)",
                        "Voltage observations", "Most voltage-stressed buses",
                        "Angle spread (span: purple; max: red; min: blue)"),
        vertical_spacing=0.17, horizontal_spacing=0.16,
    )
    for column, color in (("maximum", "#d73027"), ("mean", "#555555"), ("minimum", "#4575b4")):
        x_values, y_values, hover = _series_with_day_gaps(voltage[column], axis)
        fig.add_trace(go.Scatter(
            x=x_values, y=y_values, customdata=hover, name=f"V {column}", showlegend=False,
            line=dict(color=color, width=2),
            hovertemplate=f"%{{customdata}}<br>V {column}=%{{y:.4f}} p.u.<extra></extra>",
        ), row=1, col=1)
    fig.add_hline(y=1.05, line_dash="dash", line_color="#d73027", row=1, col=1)
    fig.add_hline(y=0.95, line_dash="dash", line_color="#4575b4", row=1, col=1)
    fig.add_trace(go.Pie(
        labels=violations.index, values=violations.values, hole=0.45, showlegend=False,
        textinfo="label+percent", sort=False,
        marker_colors=["#91cf60", "#4575b4", "#d73027"],
        hovertemplate="%{label}<br>%{value:,} bus-hours (%{percent})<extra></extra>",
    ), row=1, col=2)
    fig.add_trace(go.Heatmap(
        x=axis["positions"], y=heat.index, z=heat.values, colorscale="RdBu_r", zmid=1.0, zmin=0.9, zmax=1.1,
        colorbar=dict(title="p.u.", len=0.34, y=0.21, x=0.47, thickness=12),
        customdata=np.tile(np.asarray(axis["hover_labels"], dtype=object), (len(heat.index), 1)),
        hovertemplate="%{y}<br>%{customdata}<br>%{z:.4f} p.u.<extra></extra>",
    ), row=2, col=1)
    for column, color, dash in (
        ("span", "#7b3294", "solid"), ("maximum", "#d73027", "dot"),
        ("minimum", "#4575b4", "dot"),
    ):
        x_values, y_values, hover = _series_with_day_gaps(angle[column], axis)
        fig.add_trace(go.Scatter(
            x=x_values, y=y_values, customdata=hover, name=column, showlegend=False,
            line=dict(color=color, dash=dash, width=2),
            hovertemplate=f"%{{customdata}}<br>{column}=%{{y:.2f}} deg<extra></extra>",
        ), row=2, col=2)
    fig.update_layout(
        title=dict(text=f"Voltage magnitudes and angles — {run.label} / AC", x=0.01),
        template="plotly_white", height=930,
        margin=dict(l=95, r=45, t=85, b=65), showlegend=False,
    )
    fig.update_yaxes(title_text="voltage [p.u.]", row=1, col=1)
    fig.update_yaxes(title_text="degrees", row=2, col=2)
    fig.update_yaxes(automargin=True)
    _set_profile_axis(fig, axis, row=1, col=1)
    _set_profile_axis(fig, axis, row=2, col=1)
    _set_profile_axis(fig, axis, row=2, col=2)
    return fig


def congestion_table(
    run: RedispatchRun, threshold: float = 99.9, date: str | None = None
) -> pd.DataFrame:
    """Detailed, sortable branch-level congestion table."""
    data = _date_filter(run.branch_flows, date).copy()
    data["is_congested"] = data["loading_pct"] >= threshold
    table = data.groupby(["branch_name", "from_bus", "to_bus"], as_index=False).agg(
        limit_mw=("limit_mw", "max"), peak_loading_pct=("loading_pct", "max"),
        mean_loading_pct=("loading_pct", "mean"), congested_hours=("is_congested", "sum"),
        peak_flow_mw=("flow_mw", lambda x: x.loc[x.abs().idxmax()] if len(x) else np.nan),
    )
    return table.sort_values(["congested_hours", "peak_loading_pct"], ascending=False).reset_index(drop=True)


def _matrix_for_map(
    frame: pd.DataFrame,
    row_key: str,
    value: str,
    row_order: Iterable,
    time_order: Iterable[pd.Timestamp],
) -> list[list[float | None]]:
    """Build a time-major matrix containing JSON-safe numbers."""
    table = frame.pivot_table(index=row_key, columns="timestamp", values=value, aggfunc="first")
    table = table.reindex(index=list(row_order), columns=list(time_order)).T
    values = table.to_numpy(dtype=float)
    return [[None if not np.isfinite(x) else round(float(x), 5) for x in row] for row in values]


def build_redispatch_map(
    run: RedispatchRun,
    output_path: str | Path | None = None,
    *,
    map_date: str | None = None,
    default_date: str | None = None,
    default_hour: int | None = None,
    congestion_threshold: float = 99.9,
    show_inline: bool = False,
):
    """Create a self-contained, time-selectable HTML map of redispatch results.

    Lines expose active/reactive flow, loading and thermal limits.  Buses expose
    voltage, angle, anchor/redispatched output, net adjustment, reactive output,
    demand allocation, load shedding, and the largest unit-level adjustments.
    ``map_date`` can restrict a long scenario study to one day (24 selectable
    hours), keeping the browser payload responsive.  With ``map_date=None`` all
    solved timestamps are embedded.  The output is deliberately a standalone
    HTML file, matching the workflow of ``grid_plotting.ipynb`` without embedding
    several megabytes in this notebook.
    """
    buses = run.buses.copy().reset_index(drop=True)
    bus_position = {bus_id: i for i, bus_id in enumerate(buses["bus_id"])}
    bus_i_position = {int(bus_i): i for i, bus_i in enumerate(buses["bus_i"])}
    lines = run.lines[
        run.lines["bus0"].isin(bus_position) & run.lines["bus1"].isin(bus_position)
    ].copy().reset_index(drop=True)
    line_ids = lines["line_id"].astype(str).tolist()
    times = run.timestamps
    if map_date is not None:
        times = pd.DatetimeIndex([t for t in times if str(t.date()) == str(map_date)])
    if times.empty:
        raise ValueError(f"The selected run contains no solved timestamps for map_date={map_date!r}.")

    default_timestamp = times[0]
    if default_date is not None:
        matches = [t for t in times if str(t.date()) == str(default_date)]
        if default_hour is not None:
            matches = [t for t in matches if int(t.hour) == int(default_hour)]
        if matches:
            default_timestamp = matches[0]
    default_index = int(times.get_loc(default_timestamp))

    # Bus-level electrical state.
    voltage = run.bus_voltages[run.bus_voltages["timestamp"].isin(times)].copy()
    voltage["bus_id"] = voltage["bus_id"].astype(str)
    bus_vm = _matrix_for_map(voltage, "bus_id", "vm_pu", buses["bus_id"], times)
    bus_va = _matrix_for_map(voltage, "bus_id", "va_deg", buses["bus_id"], times)

    # Aggregate the unit comparison to each physical bus, retaining load shed separately.
    changes = run.generation_changes[run.generation_changes["timestamp"].isin(times)].copy()
    changes["bus_i"] = pd.to_numeric(changes["bus_i"], errors="coerce")
    physical = changes[~changes["fuel"].astype(str).isin(["LoadShed", "Slack"])]
    bus_generation = physical.groupby(["timestamp", "bus_i"], as_index=False).agg(
        anchor_mw=("anchor_mw", "sum"), redispatch_mw=("redispatch_mw", "sum"),
        delta_mw=("delta_mw", "sum"), reactive_mvar=("dispatch_mvar", "sum"),
    )
    load_shed = changes[changes["fuel"].astype(str) == "LoadShed"].groupby(
        ["timestamp", "bus_i"], as_index=False
    )["redispatch_mw"].sum().rename(columns={"redispatch_mw": "load_shed_mw"})
    bus_order = buses["bus_i"].astype(int).tolist()
    bus_anchor = _matrix_for_map(bus_generation, "bus_i", "anchor_mw", bus_order, times)
    bus_rd = _matrix_for_map(bus_generation, "bus_i", "redispatch_mw", bus_order, times)
    bus_delta = _matrix_for_map(bus_generation, "bus_i", "delta_mw", bus_order, times)
    bus_q = _matrix_for_map(bus_generation, "bus_i", "reactive_mvar", bus_order, times)
    bus_shed = _matrix_for_map(load_shed, "bus_i", "load_shed_mw", bus_order, times)

    # Allocate the solved system demand using the same static shares as run_opf.jl.
    demand = pd.to_numeric(run.loads.set_index("bus_id")["demand"], errors="coerce")
    demand = demand.reindex(buses["bus_id"]).fillna(0.0)
    shares = demand / max(float(demand.sum()), 1e-12)
    system_load = run.summary.set_index("timestamp")["total_load_mw"].reindex(times).fillna(0.0)
    bus_load = [[round(float(total * share), 4) for share in shares] for total in system_load]

    # The largest unit adjustments are rendered inside each bus popup.
    unit_html: dict[str, str] = {}
    display_units = physical[physical["abs_delta_mw"] > 0.01].copy()
    for (timestamp, bus_i), group in display_units.groupby(["timestamp", "bus_i"]):
        if not np.isfinite(bus_i) or int(bus_i) not in bus_i_position:
            continue
        group = group.nlargest(10, "abs_delta_mw")
        rows = []
        for row in group.itertuples():
            rows.append(
                "<tr><td>" + escape(str(row.unit_name)) + "</td><td>" + escape(str(row.fuel))
                + f"</td><td class='n'>{row.anchor_mw:.1f}</td><td class='n'>{row.redispatch_mw:.1f}</td>"
                + f"<td class='n {'up' if row.delta_mw > 0 else 'down'}'>{row.delta_mw:+.1f}</td></tr>"
            )
        t_idx = int(times.get_loc(pd.Timestamp(timestamp)))
        b_idx = bus_i_position[int(bus_i)]
        unit_html[f"{t_idx}:{b_idx}"] = "".join(rows)

    # Line state.  Result branch_name equals the static line_id for physical lines.
    flows = run.branch_flows[run.branch_flows["timestamp"].isin(times)].copy()
    flows["branch_name"] = flows["branch_name"].astype(str)
    line_loading = _matrix_for_map(flows, "branch_name", "loading_pct", line_ids, times)
    line_p = _matrix_for_map(flows, "branch_name", "flow_mw", line_ids, times)
    line_q = _matrix_for_map(flows, "branch_name", "flow_mvar", line_ids, times)
    line_limit = _matrix_for_map(flows, "branch_name", "limit_mw", line_ids, times)

    # How often each line is congested.  Unlike every other line series this one is a
    # time AGGREGATE, so the map's "congested hours" mode paints the same colours at
    # every hour -- it answers "which corridors bind repeatedly", which a single-hour
    # snapshot cannot show.  It is counted over EVERY solved hour of the run, not just
    # the hours embedded in this map: `map_date` usually narrows the payload to one day,
    # and a count out of 24 would hide how often a corridor binds across the study.
    all_flows = run.branch_flows.copy()
    all_flows["branch_name"] = all_flows["branch_name"].astype(str)
    congestion_hours_total = int(all_flows["timestamp"].nunique())
    congested_hours = (
        all_flows[all_flows["loading_pct"] >= congestion_threshold]
        .groupby("branch_name")["timestamp"].nunique()
        .reindex(line_ids).fillna(0).astype(int).tolist()
    )

    payload = {
        "scenario": run.scenario,
        "scenarioLabel": run.label,
        "isFuture": run.scenario != "2024",
        "powerFlow": run.power_flow,
        "anchorStage": run.anchor_stage,
        "threshold": float(congestion_threshold),
        "defaultTime": default_index,
        "timeLabels": [display_timestamp(run, t) for t in times],
        "sourceTimeLabels": [t.strftime("%Y-%m-%d %H:00") for t in times],
        "busId": buses["bus_id"].astype(str).tolist(),
        "busKV": pd.to_numeric(buses["voltage"], errors="coerce").fillna(0).round(1).tolist(),
        "busCountry": buses["country"].fillna("?").astype(str).tolist(),
        "busLL": [[round(float(y), 6), round(float(x), 6)] for y, x in zip(buses["y"], buses["x"])],
        "busVm": bus_vm, "busVa": bus_va, "busAnchor": bus_anchor, "busRD": bus_rd,
        "busDelta": bus_delta, "busQ": bus_q, "busShed": bus_shed, "busLoad": bus_load,
        "busUnitHtml": unit_html,
        "lineId": line_ids,
        "lineA": [bus_position[str(value)] for value in lines["bus0"]],
        "lineB": [bus_position[str(value)] for value in lines["bus1"]],
        "lineKV": pd.to_numeric(lines["voltage"], errors="coerce").fillna(0).round(1).tolist(),
        "lineCircuits": pd.to_numeric(lines["circuits"], errors="coerce").fillna(1).round(1).tolist(),
        "lineLength": pd.to_numeric(lines["length"], errors="coerce").fillna(0).round(2).tolist(),
        "lineDC": lines["dc"].astype(str).str.lower().isin(["t", "true", "1"]).astype(int).tolist(),
        "lineLoading": line_loading, "lineP": line_p, "lineQ": line_q, "lineLimit": line_limit,
        "lineCongHours": congested_hours, "nTimes": congestion_hours_total,
        "congScopeAllHours": bool(congestion_hours_total != len(times)),
    }
    blob = json.dumps(payload, separators=(",", ":"), allow_nan=False)

    map_object = folium.Map(
        location=[40.0, -3.6], zoom_start=6, tiles="cartodbpositron", control_scale=True
    )
    map_object.fit_bounds(
        [[float(buses["y"].min()), float(buses["x"].min())],
         [float(buses["y"].max()), float(buses["x"].max())]],
        padding=(30, 30),
    )
    nuts_file = run.root / "Data" / "nuts3_es.geojson"
    if nuts_file.exists():
        layer = folium.FeatureGroup(name="NUTS-3 borders", show=False)
        folium.GeoJson(
            json.loads(nuts_file.read_text(encoding="utf-8")),
            style_function=lambda _: {"color": "#777", "weight": 0.7, "fill": False},
        ).add_to(layer)
        layer.add_to(map_object)

    css = """
<style>
.rdctl{background:#fff;padding:10px 12px;border-radius:6px;box-shadow:0 1px 6px #777;
  font:12px/1.35 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;width:260px;max-height:88vh;overflow:auto}
.rdctl select,.rdctl input[type=text]{width:100%;box-sizing:border-box;margin:3px 0 6px;padding:4px;border:1px solid #bbb;border-radius:3px}
.rdctl label{display:block;cursor:pointer;margin:2px 0}.rdctl hr{border:0;border-top:1px solid #ddd;margin:7px 0}
.rdctl .hint{font-size:10.5px;color:#666}.rdctl .sw{display:inline-block;width:12px;height:8px;margin-right:3px}
.rdpop{font:12px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-height:390px;overflow:auto;min-width:290px}
.rdpop h4{margin:6px 0 2px;color:#1565c0}.rdpop table{border-collapse:collapse;width:100%}
.rdpop td,.rdpop th{padding:1px 5px 1px 0;border-bottom:1px solid #eee;text-align:left}.rdpop .n{text-align:right;font-variant-numeric:tabular-nums}
.rdpop .up{color:#c62828;font-weight:600}.rdpop .down{color:#1565c0;font-weight:600}
.rdtitle{background:rgba(255,255,255,.92);padding:7px 10px;border-radius:5px;box-shadow:0 1px 4px #888;font:13px sans-serif}
</style>
"""
    map_object.get_root().header.add_child(folium.Element(css))

    script = r"""
window.addEventListener('load', function(){
var MAP=__MAP__, P=__DATA__, ti=P.defaultTime, lineMode='loading', busMode=(P.powerFlow==='AC'?'voltage':'delta');
function fmt(v,d){if(v===null||v===undefined||!isFinite(v))return 'n/a';return Number(v).toLocaleString(undefined,{minimumFractionDigits:d||0,maximumFractionDigits:d||0});}
function row(k,v){return '<tr><td>'+k+'</td><td class="n">'+v+'</td></tr>';}
function loadingColor(v){if(v===null)return '#bdbdbd';if(v>=P.threshold)return '#b2182b';if(v>=90)return '#ef8a62';if(v>=70)return '#fddbc7';if(v>=40)return '#67a9cf';return '#2166ac';}
function diverge(v,scale){if(v===null)return '#bdbdbd';var a=Math.min(1,Math.abs(v)/Math.max(scale,1e-9));if(v>=0)return 'rgb('+Math.round(235-45*a)+','+Math.round(235-195*a)+','+Math.round(235-195*a)+')';return 'rgb('+Math.round(235-195*a)+','+Math.round(235-105*a)+','+Math.round(235-15*a)+')';}
// Congested-hour count: sequential single-hue ramp (ColorBrewer Reds), light->dark
// with a neutral grey for "never congested". Classed by SHARE of the horizon so the
// scale reads the same whether the run embeds 48 hours or 336.
function congBins(){var n=Math.max(P.nTimes,1);return [Math.max(1,Math.round(.10*n)),Math.round(.25*n),Math.round(.50*n),Math.round(.75*n)];}
function congColor(h){if(!h)return '#e0e0e0';var b=congBins();if(h<=b[0])return '#fee5d9';if(h<=b[1])return '#fcae91';if(h<=b[2])return '#fb6a4a';if(h<=b[3])return '#de2d26';return '#a50f15';}
function lineColor(i){var load=P.lineLoading[ti][i], f=P.lineP[ti][i];if(lineMode==='loading')return loadingColor(load);if(lineMode==='congestion')return load!==null&&load>=P.threshold?'#b2182b':'#bdbdbd';if(lineMode==='conghours')return congColor(P.lineCongHours[i]);return diverge(f,1500);}
function lineWidth(i){if(lineMode==='conghours'){var h=P.lineCongHours[i];return h?1.2+4.3*Math.min(1,h/Math.max(P.nTimes,1)):0.7;}var load=P.lineLoading[ti][i];return load===null?0.7:1.0+4.5*Math.min(1,load/100);}
function sourceNote(){return P.isFuture?'<br><span class="hint">operational profile source: '+P.sourceTimeLabels[ti]+'</span>':'';}
function linePopup(i){var load=P.lineLoading[ti][i],p=P.lineP[ti][i],q=P.lineQ[ti][i],lim=P.lineLimit[ti][i];return '<div class="rdpop"><b>'+P.lineId[i]+'</b>'+(P.lineDC[i]?' <span style="color:#7b1fa2">(DC link)</span>':'')+'<br><span style="color:#666">'+P.busId[P.lineA[i]]+' &harr; '+P.busId[P.lineB[i]]+' | '+P.timeLabels[ti]+'</span>'+sourceNote()+'<h4>Redispatch flow</h4><table>'+row('active flow',fmt(p,1)+' MW')+row('reactive flow',P.powerFlow==='AC'?fmt(q,1)+' Mvar':'not represented')+row('<b>loading</b>','<b>'+fmt(load,1)+' %</b>')+row('OPF limit',fmt(lim,1)+' MW')+row('congested',load!==null&&load>=P.threshold?'<span class="up">YES</span>':'no')+row('<b>congested hours</b>','<b>'+P.lineCongHours[i]+' of '+P.nTimes+'</b> ('+fmt(100*P.lineCongHours[i]/Math.max(P.nTimes,1),0)+' %)')+'</table><h4>Asset</h4><table>'+row('voltage',fmt(P.lineKV[i],0)+' kV')+row('circuits',fmt(P.lineCircuits[i],0))+row('length',fmt(P.lineLength[i],1)+' km')+'</table></div>';}
function busScale(mode){var arr=mode==='angle'?P.busVa[ti]:mode==='delta'?P.busDelta[ti]:mode==='output'?P.busRD[ti]:P.busVm[ti].map(function(v){return v===null?null:v-1;});var mx=0;arr.forEach(function(v){if(v!==null)mx=Math.max(mx,Math.abs(v));});return mx||1;}
function busStyle(j){var v,r=2.2,c='#777',scale=busScale(busMode);if(busMode==='voltage'){v=P.busVm[ti][j];c=v===null?'#aaa':diverge(v-1,Math.max(scale,.05));r=v===null?1.7:3+8*Math.min(1,Math.abs(v-1)/.08);}else if(busMode==='angle'){v=P.busVa[ti][j];c=diverge(v,scale);r=2.5+6*Math.min(1,Math.abs(v||0)/scale);}else if(busMode==='delta'){v=P.busDelta[ti][j];c=diverge(v,scale);r=2+11*Math.sqrt(Math.abs(v||0)/scale);}else{v=P.busRD[ti][j];c=v===null?'#aaa':'#238b45';r=2+11*Math.sqrt(Math.max(0,v||0)/scale);}return {radius:r,color:'#333',weight:.5,fillColor:c,fillOpacity:.78};}
function busPopup(j){var vm=P.busVm[ti][j],va=P.busVa[ti][j],d=P.busDelta[ti][j],u=P.busUnitHtml[ti+':'+j]||'';var units=u?'<h4>Largest unit adjustments</h4><table><tr><th>unit</th><th>fuel</th><th class="n">anchor</th><th class="n">RD</th><th class="n">delta</th></tr>'+u+'</table>':'<span class="hint">No unit adjustment above 0.01 MW at this bus.</span>';return '<div class="rdpop"><b>'+P.busId[j]+'</b> | '+fmt(P.busKV[j],0)+' kV | '+P.busCountry[j]+'<br><span style="color:#666">'+P.timeLabels[ti]+'</span>'+sourceNote()+'<h4>Electrical state</h4><table>'+row('voltage magnitude',P.powerFlow==='AC'?fmt(vm,4)+' p.u.':'not represented by DC OPF')+row('voltage angle',fmt(va,3)+' deg')+row('reactive generation',P.powerFlow==='AC'?fmt(P.busQ[ti][j],1)+' Mvar':'not represented')+'</table><h4>Power balance and redispatch</h4><table>'+row(P.anchorStage+' generation',fmt(P.busAnchor[ti][j],1)+' MW')+row('redispatched generation',fmt(P.busRD[ti][j],1)+' MW')+row('<b>net redispatch</b>','<b class="'+(d>=0?'up':'down')+'">'+fmt(d,1)+' MW</b>')+row('allocated demand',fmt(P.busLoad[ti][j],1)+' MW')+row('load shedding',fmt(P.busShed[ti][j],2)+' MW')+'</table>'+units+'</div>';}
var lineGroup=L.layerGroup().addTo(MAP),lineLayers=[];
P.lineA.forEach(function(a,i){var pl=L.polyline([P.busLL[a],P.busLL[P.lineB[i]]],{color:'#999',weight:1,opacity:.88,dashArray:P.lineDC[i]?'5,5':null});pl.bindTooltip(function(){return lineMode==='conghours'?'<b>'+P.lineId[i]+'</b><br>congested '+P.lineCongHours[i]+' of '+P.nTimes+' h<br><span style="color:#666">'+P.timeLabels[ti]+': '+fmt(P.lineLoading[ti][i],1)+' %</span>':'<b>'+P.lineId[i]+'</b><br>'+P.timeLabels[ti]+'<br>'+fmt(P.lineP[ti][i],1)+' MW | '+fmt(P.lineLoading[ti][i],1)+' %';},{sticky:true});pl.on('click',function(e){pl.bindPopup(linePopup(i),{maxWidth:430}).openPopup(e.latlng);});pl.addTo(lineGroup);lineLayers.push(pl);});
var busGroup=L.layerGroup().addTo(MAP),busLayers=[];
P.busLL.forEach(function(ll,j){var cm=L.circleMarker(ll,busStyle(j));cm.bindTooltip(function(){return '<b>'+P.busId[j]+'</b><br>'+P.timeLabels[ti]+'<br>RD '+fmt(P.busDelta[ti][j],1)+' MW | angle '+fmt(P.busVa[ti][j],2)+' deg'+(P.powerFlow==='AC'?'<br>V '+fmt(P.busVm[ti][j],4)+' p.u.':'');},{sticky:true});cm.on('click',function(e){cm.bindPopup(busPopup(j),{maxWidth:470}).openPopup(e.latlng);});cm.addTo(busGroup);busLayers.push(cm);});
function redraw(){MAP.closePopup();lineLayers.forEach(function(l,i){l.setStyle({color:lineColor(i),weight:lineWidth(i),opacity:(lineMode==='congestion'&&P.lineLoading[ti][i]<P.threshold)||(lineMode==='conghours'&&!P.lineCongHours[i]) ? .25 : .88});});busLayers.forEach(function(b,j){b.setStyle(busStyle(j));});document.getElementById('rdStatus').innerHTML='<b>'+P.timeLabels[ti]+'</b><br>'+P.scenarioLabel+' / '+P.powerFlow+' | anchor '+P.anchorStage+(P.isFuture?'<br><span class="hint">profile source: '+P.sourceTimeLabels[ti]+'</span>':'');updateLegend();}
function updateLegend(){var s,w='Line width follows loading.';
if(lineMode==='loading'){s='<span class="sw" style="background:#b2182b"></span>&ge;'+P.threshold+'% &nbsp; <span class="sw" style="background:#2166ac"></span>low loading';}
else if(lineMode==='flow'){s='blue = negative, red = positive flow';}
else if(lineMode==='conghours'){var b=congBins();
 s='<b>hours at &ge;'+P.threshold+'% of rating</b><br><span class="sw" style="background:#e0e0e0"></span>0 &nbsp;<span class="sw" style="background:#fee5d9"></span>&le;'+b[0]+' &nbsp;<span class="sw" style="background:#fcae91"></span>&le;'+b[1]+' &nbsp;<span class="sw" style="background:#fb6a4a"></span>&le;'+b[2]+'<br><span class="sw" style="background:#de2d26"></span>&le;'+b[3]+' &nbsp;<span class="sw" style="background:#a50f15"></span>&le;'+P.nTimes+' h';
 w='Line width follows the congested-hour count. <b>Same at every hour</b> — it counts all '+P.nTimes+' solved hours of the run'+(P.congScopeAllHours?' (including days not embedded in this map)':'')+', so the hour selector does not change it.';}
else{s='red = congested';}
document.getElementById('rdLegend').innerHTML=s+'<br><span class="hint">'+w+' Bus size/colour follows the selected bus metric.</span>';}
var Ctl=L.Control.extend({options:{position:'topright'},onAdd:function(){var d=L.DomUtil.create('div','rdctl');d.innerHTML='<b>Redispatch result</b><div id="rdStatus"></div><hr><b>Scenario date and hour</b><select id="rdTime">'+P.timeLabels.map(function(x,i){return '<option value="'+i+'"'+(i===ti?' selected':'')+'>'+x+'</option>';}).join('')+'</select><b>Lines</b><label><input type="radio" name="lm" value="loading" checked> loading</label><label><input type="radio" name="lm" value="congestion"> congestion only</label><label><input type="radio" name="lm" value="conghours"> congested hours (all horizon)</label><label><input type="radio" name="lm" value="flow"> signed MW flow</label><b>Buses</b>'+(P.powerFlow==='AC'?'<label><input type="radio" name="bm" value="voltage" checked> voltage deviation</label>':'')+'<label><input type="radio" name="bm" value="angle"> voltage angle</label><label><input type="radio" name="bm" value="delta"'+(P.powerFlow==='DC'?' checked':'')+'> net redispatch</label><label><input type="radio" name="bm" value="output"> redispatched output</label><hr><b>Find asset</b><input id="rdSearch" type="text" placeholder="bus or line id"><span class="hint">Enter an exact or partial id and press Enter.</span><hr><div id="rdLegend"></div>';L.DomEvent.disableClickPropagation(d);L.DomEvent.disableScrollPropagation(d);return d;}});MAP.addControl(new Ctl());
document.getElementById('rdTime').addEventListener('change',function(){ti=+this.value;redraw();});
Array.prototype.forEach.call(document.getElementsByName('lm'),function(r){r.addEventListener('change',function(){lineMode=this.value;redraw();});});
Array.prototype.forEach.call(document.getElementsByName('bm'),function(r){r.addEventListener('change',function(){busMode=this.value;redraw();});});
document.getElementById('rdSearch').addEventListener('keydown',function(e){if(e.key!=='Enter')return;var q=this.value.trim().toLowerCase();if(!q)return;var b=P.busId.findIndex(function(x){return x.toLowerCase().indexOf(q)>=0;});if(b>=0){MAP.setView(P.busLL[b],11);L.popup({maxWidth:470}).setLatLng(P.busLL[b]).setContent(busPopup(b)).openOn(MAP);return;}var i=P.lineId.findIndex(function(x){return x.toLowerCase().indexOf(q)>=0;});if(i>=0){var a=P.busLL[P.lineA[i]],z=P.busLL[P.lineB[i]],ll=[(a[0]+z[0])/2,(a[1]+z[1])/2];MAP.fitBounds([a,z],{padding:[60,60]});L.popup({maxWidth:430}).setLatLng(ll).setContent(linePopup(i)).openOn(MAP);}});
var Title=L.Control.extend({options:{position:'topleft'},onAdd:function(){var d=L.DomUtil.create('div','rdtitle');d.innerHTML='<b>Spanish redispatch</b><br>'+P.scenarioLabel+' / '+P.powerFlow;return d;}});MAP.addControl(new Title());redraw();
});
"""
    map_object.get_root().script.add_child(
        folium.Element(script.replace("__MAP__", map_object.get_name()).replace("__DATA__", blob))
    )
    folium.LayerControl(collapsed=True).add_to(map_object)

    if output_path is None:
        output_path = run.root / "results" / "redispatch_maps" / f"redispatch_{run.scenario}_{run.power_flow}.html"
    output_path = Path(output_path)
    if not output_path.is_absolute():
        output_path = run.root / output_path
    output_path.parent.mkdir(parents=True, exist_ok=True)
    map_object.save(str(output_path))
    print(f"Saved detailed redispatch map: {output_path}")
    print(f"Map payload: {len(blob) / 1e6:.2f} MB | {len(lines)} lines | {len(buses)} buses | {len(times)} hours")
    return map_object if show_inline else output_path
