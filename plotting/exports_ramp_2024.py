"""
Figures for the two 2024 day-ahead modelling changes:

  1. `[crossborder].include_exports` — model the hours in which Spain is a net
     EXPORTER as a fixed withdrawal, instead of dropping them.
  2. `[da].ramp_limits` — bound the hour-to-hour change of every thermal unit by
     its sustained ramp rate from `Data/power_unit_tech_params.csv`.

Reads the market-chain CSVs of four runs that differ only in those two flags,
plus the reference data in `Data/OMIE/`.  Colours, categories and the paper
style come from `paper_figures_2024`, so these figures sit in the same visual
system as the validation ones.

The four runs are produced by re-running `run_market_chain.jl` with the flags flipped;
point `RUNS` at wherever their result directories live:

    EXPORTS_RAMP_RUNS="C:/path/to/exp" python -m plotting.exports_ramp_2024

expects `<dir>/res_base`, `res_exports`, `res_ramp`, `res_both`.

Usage from a notebook:

    from plotting.exports_ramp_2024 import *
    R = load_runs()
    fig_exchange(R, save=True)
"""

from __future__ import annotations

import os
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from plotting.paper_figures_2024 import (
    CAT_COLOR, DAY_LABEL, DAYS, OMIE_DIR, ROOT, STACK_ORDER,
    gate_mix, load_chain, load_reference, use_paper_style,
)

# ── Where the four runs live ─────────────────────────────────────────────────
EXP_DIR = Path(os.environ.get("EXPORTS_RAMP_RUNS", ROOT / "results" / "experiments"))
RUN_DIR = {name: EXP_DIR / f"res_{name}" for name in ("base", "exports", "ramp", "both")}

# Exploratory comparisons, not paper figures — kept out of Paper/images.
OUT_DIR = ROOT / "plotting" / "created_figures"

RUN_LABEL = {
    "base":    "base (exports dropped)",
    "exports": "+exports",
    "ramp":    "+ramp limits",
    "both":    "+exports +ramp",
}
RUN_COLOR = {"base": "#5a5a5a", "exports": "#c2453b",
             "ramp": "#3f7fbf", "both": "#22a37f"}

# Sustained ramp rate as a fraction of nameplate per hour, from
# Data/power_unit_tech_params.csv via the RAMP_MAP in data_preparation.jl.
RAMP_FRAC = {
    ("Nuclear", "Nuclear"): 0.20,
    ("Coal", "Coal"): 0.40,
    ("Gas", "Combined_cycle"): 0.50,
    ("Gas", "Gas_turbine"): 1.00,
    ("Oil", "Combined_cycle"): 0.40,
    ("Oil", "Gas_turbine"): 0.40,
}


def _save(fig, name, save):
    """Write both a PDF (for the paper) and a PNG (for quick viewing)."""
    if save:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        for ext in ("pdf", "png"):
            fig.savefig(OUT_DIR / f"{name}.{ext}")
        print(f"wrote {(OUT_DIR / name).relative_to(ROOT)}.{{pdf,png}}")
    return fig


# ── Loaders ──────────────────────────────────────────────────────────────────
def load_runs(dirs=None):
    """`load_chain` for each of the four runs → {run name: chain dict}."""
    dirs = dirs or RUN_DIR
    out = {}
    for name, d in dirs.items():
        if Path(d).exists():
            out[name] = load_chain(Path(d))
        else:
            print(f"skipping {name}: {d} not found")
    return out


def load_capacities():
    """unit_id → (fuel, technology, nameplate MW)."""
    g = pd.read_csv(ROOT / "Data" / "generations.csv")
    return {r.unit_id: (r.primary_fuel, r.technology, float(r.capacity_mw))
            for r in g.itertuples()}


def actual_exchange():
    """Observed hourly net exchange, import into Spain positive [MW]."""
    xb = pd.read_csv(ROOT / "Data" / "crossborder.csv")
    day_map = {"8_Jul": "2024-07-08", "2_Dec": "2024-12-02"}
    xb["date"] = xb["Day"].map(day_map)
    xb["hour"] = xb["Time"].str.split(":").str[0].astype(int)
    xb["FR"] = xb["from_FR"] - xb["to_FR"]
    xb["PT"] = xb["from_PT"] - xb["to_PT"]
    return {d: g.set_index("hour")[["FR", "PT"]].reindex(range(24))
            for d, g in xb.dropna(subset=["date"]).groupby("date")}


def da_price(ch, date):
    p = ch["market_prices"]
    p = p[(p["stage"] == "DA") & (p["date"] == date)]
    return p.set_index("hour")["price_eur_mwh"].reindex(range(24))


def ccgt_units(ch, date, gate="da"):
    """Per-unit hourly CCGT dispatch → DataFrame [hour × unit]."""
    d = ch["gates"][gate]
    d = d[(d["date"] == date) & (d["fuel"] == "Gas")
          & (d["technology"] == "Combined_cycle")]
    return (d.pivot_table(index="hour", columns="gen_id", values="dispatch_mw",
                          aggfunc="sum").reindex(range(24)).fillna(0.0))


def ramp_usage(ch, cap, gate="da"):
    """|ΔP| between consecutive hours as a fraction of each unit's ramp limit."""
    d = ch["gates"][gate]
    out = []
    for date in DAYS:
        sub = d[d["date"] == date]
        piv = sub.pivot_table(index="hour", columns="gen_id",
                              values="dispatch_mw", aggfunc="sum")
        piv = piv.reindex(range(24))
        for unit in piv.columns:
            if unit not in cap:
                continue
            fuel, tech, mw = cap[unit]
            frac = RAMP_FRAC.get((fuel, tech))
            if frac is None or mw <= 0:
                continue
            limit = frac * mw
            dp = piv[unit].diff().abs().to_numpy()[1:]
            out.append(pd.DataFrame({"date": date, "category": tech,
                                     "ratio": dp / limit}))
    return pd.concat(out, ignore_index=True).dropna()


# ── Fig 1: the cause — exchange the DA actually saw ──────────────────────────
def fig_exchange(runs, save=False, name="xb_exchange"):
    """Observed net exchange vs what the base run put into the ES balance."""
    act = actual_exchange()
    fig, axes = plt.subplots(1, 2, figsize=(9.2, 3.2), sharey=True)
    for ax, date in zip(axes, DAYS):
        a = act[date]
        net = a["FR"] + a["PT"]
        # what the base run injected: positive net per country only
        seen = a.clip(lower=0).sum(axis=1)
        h = np.arange(24)
        ax.axhline(0, color="0.3", lw=0.8)
        ax.fill_between(h, seen, net, step="mid", color="#c2453b", alpha=0.20,
                        label="omitted export obligation")
        ax.step(h, net, where="mid", color="#111111", lw=1.6,
                label="actual net position")
        ax.step(h, seen, where="mid", color="#c2453b", lw=1.6, ls="--",
                label="seen by base DA (imports only)")
        ax.set_title(f"{DAY_LABEL[date]}   gap = {(seen - net).sum() / 1e3:.1f} GWh")
        ax.set_xlabel("hour")
        ax.set_xlim(0, 23)
    axes[0].set_ylabel("net exchange [MW]\n(+ import to Spain)")
    axes[0].legend(loc="lower left", ncol=1)
    fig.tight_layout()
    return _save(fig, name, save)


# ── Fig 2: DA mix, base vs +exports ──────────────────────────────────────────
def fig_mix_compare(runs, save=False, name="xb_da_mix"):
    """Stacked DA generation, base (top row) vs +exports (bottom row)."""
    cases = ["base", "exports"]
    fig, axes = plt.subplots(2, 2, figsize=(9.2, 5.6), sharex=True, sharey="col")
    for i, case in enumerate(cases):
        for j, date in enumerate(DAYS):
            ax = axes[i, j]
            piv = gate_mix(runs[case], "da", date)
            cols = [c for c in STACK_ORDER if c in piv.columns]
            pos = piv[cols].clip(lower=0)
            neg = piv[cols].clip(upper=0)
            ax.stackplot(range(24), *[pos[c] for c in cols],
                         colors=[CAT_COLOR[c] for c in cols], labels=cols)
            if (neg.to_numpy() < 0).any():
                ax.stackplot(range(24), *[neg[c] for c in cols],
                             colors=[CAT_COLOR[c] for c in cols])
            ax.axhline(0, color="0.3", lw=0.8)
            ax.set_xlim(0, 23)
            if i == 0:
                ax.set_title(DAY_LABEL[date])
            if i == 1:
                ax.set_xlabel("hour")
            if j == 0:
                ax.set_ylabel(f"{RUN_LABEL[case]}\ndispatch [MW]")
    handles, labels = axes[0, 0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=6,
               bbox_to_anchor=(0.5, -0.06))
    fig.tight_layout()
    return _save(fig, name, save)


# ── Fig 3: where the export lands ────────────────────────────────────────────
def fig_delta(runs, save=False, name="xb_delta"):
    """Per-category hourly change (+exports − base), and the CCGT profile."""
    fig, axes = plt.subplots(2, 2, figsize=(9.2, 5.4), sharex=True)
    for j, date in enumerate(DAYS):
        base = gate_mix(runs["base"], "da", date)
        exp = gate_mix(runs["exports"], "da", date)
        cats = [c for c in STACK_ORDER if c in base.columns or c in exp.columns]
        d = (exp.reindex(columns=cats).fillna(0.0)
             - base.reindex(columns=cats).fillna(0.0))
        d = d.loc[:, d.abs().max() > 1.0]

        ax = axes[0, j]
        bottom_pos = np.zeros(24)
        bottom_neg = np.zeros(24)
        for c in d.columns:
            v = d[c].to_numpy()
            b = np.where(v >= 0, bottom_pos, bottom_neg)
            ax.bar(range(24), v, bottom=b, color=CAT_COLOR[c], label=c,
                   width=0.9, linewidth=0)
            bottom_pos = bottom_pos + np.clip(v, 0, None)
            bottom_neg = bottom_neg + np.clip(v, None, 0)
        ax.axhline(0, color="0.3", lw=0.8)
        ax.set_title(DAY_LABEL[date])
        ax.set_xlim(-0.5, 23.5)
        if j == 0:
            ax.set_ylabel("change vs base [MW]")
            ax.legend(loc="upper left", ncol=2)

        ax = axes[1, j]
        for case in ("base", "exports"):
            piv = gate_mix(runs[case], "da", date)
            v = piv["Combined cycle"] if "Combined cycle" in piv else pd.Series(0.0, index=range(24))
            ax.step(range(24), v, where="mid", color=RUN_COLOR[case],
                    lw=1.6, label=RUN_LABEL[case])
        ax.set_xlabel("hour")
        ax.set_xlim(0, 23)
        if j == 0:
            ax.set_ylabel("CCGT dispatch [MW]")
            ax.legend(loc="upper left")
    fig.tight_layout()
    return _save(fig, name, save)


# ── Fig 4: DA price ──────────────────────────────────────────────────────────
def fig_price(runs, ref, save=False, name="xb_price"):
    fig, axes = plt.subplots(1, 2, figsize=(9.2, 3.2))
    for ax, date in zip(axes, DAYS):
        ax.step(range(24), ref["price"][date], where="mid", color="#111111",
                lw=1.8, label="OMIE cleared")
        for case in ("base", "exports"):
            ax.step(range(24), da_price(runs[case], date), where="mid",
                    color=RUN_COLOR[case], lw=1.5, ls="--",
                    label=RUN_LABEL[case])
        ax.set_title(DAY_LABEL[date])
        ax.set_xlabel("hour")
        ax.set_xlim(0, 23)
    axes[0].set_ylabel("day-ahead price [EUR/MWh]")
    axes[0].legend(loc="lower left")
    fig.tight_layout()
    return _save(fig, name, save)


# ── Fig 5: ramp limits ───────────────────────────────────────────────────────
def fig_ramp(runs, save=False, name="xb_ramp"):
    """What the ramp constraint changes: unit staging, and ramp compliance."""
    cap = load_capacities()
    fig, axes = plt.subplots(1, 3, figsize=(11.0, 3.3))

    # (a)+(b) CCGT units online per hour, with exports on, ramp off vs on
    for ax, date in zip(axes[:2], DAYS):
        for case, ls in (("exports", "--"), ("both", "-")):
            u = ccgt_units(runs[case], date)
            online = (u > 1e-3).sum(axis=1)
            lbl = "ramp off" if case == "exports" else "ramp on"
            ax.step(range(24), online, where="mid", lw=1.6, ls=ls,
                    color=RUN_COLOR[case], label=lbl)
        ax.set_title(f"CCGT units online — {DAY_LABEL[date]}")
        ax.set_xlabel("hour")
        ax.set_xlim(0, 23)
        ax.set_ylim(bottom=0)
    axes[0].set_ylabel("units dispatched (of 92)")
    axes[0].legend(loc="upper left")

    # (c) distribution of hourly |ΔP| against each unit's own ramp limit
    ax = axes[2]
    bins = np.linspace(0, 2.2, 45)
    for case, color in (("exports", RUN_COLOR["exports"]), ("both", RUN_COLOR["both"])):
        r = ramp_usage(runs[case], cap)
        r = r[r["ratio"] > 1e-6]
        lbl = "ramp off" if case == "exports" else "ramp on"
        n_viol = int((r["ratio"] > 1 + 1e-4).sum())
        ax.hist(r["ratio"], bins=bins, color=color, alpha=0.55,
                label=f"{lbl}  ({n_viol} violating unit-hours)")
    ax.axvline(1.0, color="#111111", lw=1.2, ls=":")
    ax.text(1.02, ax.get_ylim()[1] * 0.92, "ramp limit", fontsize=8)
    ax.set_xlabel(r"hourly $|\Delta P|$ / unit ramp limit")
    ax.set_ylabel("unit-hours")
    ax.set_yscale("log")
    ax.legend(loc="upper right")
    fig.tight_layout()
    return _save(fig, name, save)


# ── Fig 6: daily energy against the references ───────────────────────────────
def fig_daily_energy(runs, ref, save=False, name="xb_daily_energy"):
    cats = ["Nuclear", "Coal", "Combined cycle", "Cogeneration & waste",
            "Hydro", "Wind", "Solar PV"]
    fig, axes = plt.subplots(1, 2, figsize=(9.6, 3.6), sharey=True)
    for ax, date in zip(axes, DAYS):
        series = {
            "OMIE cleared": ref["omie"][date].reindex(columns=cats).sum() / 1e3,
            RUN_LABEL["base"]: gate_mix(runs["base"], "da", date).reindex(columns=cats).sum() / 1e3,
            RUN_LABEL["exports"]: gate_mix(runs["exports"], "da", date).reindex(columns=cats).sum() / 1e3,
        }
        x = np.arange(len(cats))
        w = 0.27
        for k, (lbl, v) in enumerate(series.items()):
            color = {"OMIE cleared": "#111111"}.get(
                lbl, RUN_COLOR["base"] if "base" in lbl else RUN_COLOR["exports"])
            ax.bar(x + (k - 1) * w, v.reindex(cats).fillna(0.0), width=w,
                   color=color, label=lbl, linewidth=0)
        ax.set_xticks(x)
        ax.set_xticklabels(cats, rotation=30, ha="right")
        ax.set_title(DAY_LABEL[date])
    axes[0].set_ylabel("day-ahead energy [GWh]")
    axes[0].legend(loc="upper right")
    fig.tight_layout()
    return _save(fig, name, save)


def make_all(save=True):
    use_paper_style()
    runs = load_runs()
    ref = load_reference()
    fig_exchange(runs, save=save)
    fig_mix_compare(runs, save=save)
    fig_delta(runs, save=save)
    fig_price(runs, ref, save=save)
    fig_ramp(runs, save=save)
    fig_daily_energy(runs, ref, save=save)
    return runs, ref


if __name__ == "__main__":
    make_all(save=True)
