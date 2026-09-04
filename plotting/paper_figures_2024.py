"""
Figures for Section 5.1 of the paper — validation of the market chain against the
observed 2024 Spanish market on two representative days (8 July, 2 December).

Reads only the CSVs written by `run_market_chain.jl` into `results/` and the reference
data in `Data/OMIE/`.  Every figure function returns a matplotlib Figure and, if
`save=True`, writes a PDF into `figures/` (override with SPAIN_FIG_DIR).

Usage from a notebook:

    from plotting.paper_figures_2024 import *
    CH  = load_chain()
    REF = load_reference()
    fig_da_mix(CH, REF, save=True)
"""

from __future__ import annotations

import os
from pathlib import Path

import matplotlib as mpl
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# ── Paths ────────────────────────────────────────────────────────────────────
ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"
OMIE_DIR = ROOT / "Data" / "OMIE"
# Override with the SPAIN_FIG_DIR environment variable.
FIG_DIR = Path(os.environ.get("SPAIN_FIG_DIR", ROOT / "figures"))
FIG_DIR.mkdir(parents=True, exist_ok=True)

DAYS = ["2024-07-08", "2024-12-02"]
DAY_LABEL = {"2024-07-08": "8 July", "2024-12-02": "2 December"}
GATES = ["da", "id2", "id3", "cid", "bal"]
GATE_LABEL = {"da": "DA", "id2": "ID2", "id3": "ID3", "cid": "CID",
              "bal": "BAL", "rd": "RD"}

# ── Common technology categories (model and reference share these) ───────────
CATEGORIES = [
    "Nuclear", "Coal", "Combined cycle", "Gas turbine",
    "Cogeneration & waste", "Hydro", "Pumped storage",
    "Wind", "Solar PV", "Solar thermal", "Imports",
]

# One colour system for every figure. Ordered so the stack reads
# baseload (bottom) → dispatchable → variable renewable (top).
CAT_COLOR = {
    "Nuclear":              "#9b6db3",
    "Coal":                 "#8c5a3c",
    "Combined cycle":       "#5a5a5a",
    "Gas turbine":          "#a8a8a8",
    "Cogeneration & waste": "#b0a72c",
    "Hydro":                "#3f7fbf",
    "Pumped storage":       "#5ec8e0",
    "Wind":                 "#22a37f",
    "Solar PV":             "#f0a03c",
    "Solar thermal":        "#f6cf72",
    "Imports":              "#8f5fa8",
}
STACK_ORDER = [
    "Nuclear", "Coal", "Combined cycle", "Gas turbine",
    "Cogeneration & waste", "Hydro", "Pumped storage",
    "Imports", "Wind", "Solar thermal", "Solar PV",
]

# Model (fuel, technology) → category.  LoadShed and Slack are diagnostic units
# and are deliberately absent; they should carry no energy in a healthy run.
MODEL_CAT = {
    ("Nuclear", "Nuclear"):        "Nuclear",
    ("Coal", "Coal"):              "Coal",
    ("Gas", "Combined_cycle"):     "Combined cycle",
    ("Gas", "Gas_turbine"):        "Gas turbine",
    ("Oil", "Combined_cycle"):     "Gas turbine",
    ("Oil", "Gas_turbine"):        "Gas turbine",
    ("Biomass", "Biomass"):        "Cogeneration & waste",
    # The [chp] fleet. OMIE clears cogeneration, waste and mini-hydro as one
    # market group, so all three map to that category to keep the comparison
    # like-for-like — even though the model carries them as separate fuels so
    # that emissions accounting still sees the gas half as gas.
    ("Gas", "CHP"):                "Cogeneration & waste",
    ("Biomass", "CHP_Waste"):      "Cogeneration & waste",
    ("Hydro", "mini_hydro"):       "Cogeneration & waste",
    ("Hydro", "reservoir"):        "Hydro",
    ("Hydro", "run_of_river"):     "Hydro",
    ("Hydro", "pumped_storage"):   "Pumped storage",
    ("Solar", "PV"):               "Solar PV",
    ("Solar", "Solar Thermal"):    "Solar thermal",
    ("Wind", "Onshore"):           "Wind",
    ("Wind", "Offshore"):          "Wind",
    ("CrossBorder", "Interconnector"): "Imports",
}

# OMIE column → category.  OMIE reports the cleared DA programme, which is what
# the market chain models, so it is the reference for the mix and the price.
OMIE_CAT = {
    "Nuclear":                        "Nuclear",
    "Coal":                           "Coal",
    "Combined Cycle":                 "Combined cycle",
    "Fuel-Gas":                       "Gas turbine",
    "Cogeneration/Waste/Small Hydro": "Cogeneration & waste",
    "Hydropower":                     "Hydro",
    "Storage":                        "Pumped storage",
    "Wind":                           "Wind",
    "Solar Photovoltaic":             "Solar PV",
    "Solar Thermal":                  "Solar thermal",
}
OMIE_IMPORT_COLS = ["International Import",
                    "International Import (without MIBEL)"]

OMIE_FILE = {"2024-07-08": "actual_generation_July_8.csv",
             "2024-12-02": "actual_generation_Dec_2.csv"}
ENTSOE_FILE = {"2024-07-08": "ENTSOE_actual_genertion_8_july_2024_categorized.csv",
               "2024-12-02": "ENTSOE_actual_genertion_2_dec_2024_categorized.csv"}
OMIE_PRICE_ROW = {"2024-07-08": "jul", "2024-12-02": "dec"}


# ── Publication style ────────────────────────────────────────────────────────
def use_paper_style():
    """Consistent, print-legible defaults. Call once before plotting."""
    mpl.rcParams.update({
        "figure.dpi": 110,
        "savefig.dpi": 300,
        "savefig.bbox": "tight",
        "pdf.fonttype": 42,          # embed as TrueType, not Type-3
        "ps.fonttype": 42,
        "font.family": "serif",
        "font.size": 9,
        "axes.titlesize": 10,
        "axes.labelsize": 9,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.grid": True,
        "grid.alpha": 0.25,
        "grid.linewidth": 0.5,
        "legend.frameon": False,
        "legend.fontsize": 8,
        "xtick.labelsize": 8,
        "ytick.labelsize": 8,
        "lines.linewidth": 1.4,
    })


def _save(fig, name, save):
    if save:
        out = FIG_DIR / f"{name}.pdf"
        out.parent.mkdir(parents=True, exist_ok=True)
        fig.savefig(out)
        try:
            shown = out.relative_to(ROOT)
        except ValueError:          # FIG_DIR redirected outside the repo
            shown = out
        print(f"wrote {shown}")
    return fig


# ── Loaders ──────────────────────────────────────────────────────────────────
def _categorise(df):
    """Add a `category` column from (fuel, technology); drop unmapped units."""
    key = list(zip(df["fuel"], df["technology"]))
    df = df.assign(category=[MODEL_CAT.get(k) for k in key])
    df = df[df["category"].notna()].copy()

    # The XB_* units carry the net border exchange on one signed variable:
    # positive when Spain imports, negative in the export hours, where the
    # exported energy sits at the border bus as a load (the ES demand series
    # already contains it — see docs/method_export_relocation.md).  OMIE's
    # reference stack is domestic generation + GROSS imports, with the export
    # buried in demand, so keeping only the positive part is what makes the
    # two stacks add up to the same total.  Netting them instead sinks the
    # model's stacked total by the day's exports (59.7 GWh on 2 Dec).
    xb = df["category"] == "Imports"
    df.loc[xb, "dispatch_mw"] = df.loc[xb, "dispatch_mw"].clip(lower=0.0)
    return df


def _read_csv(p):
    """Read a results CSV, or None when it is missing OR empty.

    A stage that failed leaves a zero-byte file behind rather than no file at
    all (REPowerEU++ has four such files from an AC OPF run that produced
    nothing), so testing `p.exists()` alone raises EmptyDataError on load.
    """
    if not p.exists() or p.stat().st_size == 0:
        return None
    return pd.read_csv(p)


def load_chain(results=RESULTS):
    """Every output of one market-chain run, keyed for the figures below."""
    ch = {}

    ch["gates"] = {}
    for g in GATES:
        df = _read_csv(results / f"{g}_dispatch.csv")
        if df is not None:
            ch["gates"][g] = _categorise(df)

    ch["profiles"] = {}
    for g in GATES:
        df = _read_csv(results / f"{g}_profiles.csv")
        if df is not None:
            ch["profiles"][g] = df

    # Redispatch: gen_dispatch carries the technology split, fuel_mix does not.
    rd = _read_csv(results / "gen_dispatch.csv")
    ch["rd"] = _categorise(rd) if rd is not None else None

    for name in ("summary", "branch_flows", "market_prices", "fuel_mix"):
        ch[name] = _read_csv(results / f"{name}.csv")

    return ch


def gate_mix(ch, gate, date):
    """Hourly MW per category for one gate and day → DataFrame [hour × category]."""
    df = ch["rd"] if gate == "rd" else ch["gates"][gate]
    d = df[df["date"] == date]
    piv = (d.pivot_table(index="hour", columns="category",
                         values="dispatch_mw", aggfunc="sum")
             .reindex(range(24)).fillna(0.0))
    return piv.reindex(columns=[c for c in CATEGORIES if c in piv.columns])


def load_reference():
    """OMIE cleared programme, OMIE prices, OMIE intraday volumes, ENTSO-E actuals."""
    ref = {"omie": {}, "entsoe": {}, "price": {}}

    for date, fname in OMIE_FILE.items():
        raw = pd.read_csv(OMIE_DIR / fname)
        raw = raw.apply(pd.to_numeric, errors="coerce").fillna(0.0)
        out = pd.DataFrame(index=range(24))
        for col, cat in OMIE_CAT.items():
            if col in raw.columns:
                out[cat] = out.get(cat, 0.0) + raw[col].to_numpy()
        imp = sum(raw[c].to_numpy() for c in OMIE_IMPORT_COLS if c in raw.columns)
        out["Imports"] = imp
        ref["omie"][date] = out.reindex(
            columns=[c for c in CATEGORIES if c in out.columns]).fillna(0.0)

    for date, fname in ENTSOE_FILE.items():
        raw = pd.read_csv(OMIE_DIR / fname)
        e = pd.DataFrame(index=range(24))
        num = raw.drop(columns=[c for c in ("Area", "time_start") if c in raw.columns])
        num = num.apply(pd.to_numeric, errors="coerce").fillna(0.0).reset_index(drop=True)
        for c in num.columns:
            e[c] = num[c].to_numpy()[:24]
        # ENTSO-E is the only source that separates pumping from discharge.
        if {"pumped_storage_discharge", "pumped_storage_charge"} <= set(e.columns):
            e["Pumped storage net"] = (e["pumped_storage_discharge"]
                                       - e["pumped_storage_charge"])
        ref["entsoe"][date] = e

    pr = pd.read_csv(OMIE_DIR / "omie_price.csv").set_index("month")
    for date, row in OMIE_PRICE_ROW.items():
        ref["price"][date] = pd.Series(
            pr.loc[row].to_numpy(dtype=float)[:24], index=range(24))

    p = OMIE_DIR / "OMIE_intraday.csv"
    ref["intraday"] = pd.read_csv(p).set_index("tec") if p.exists() else None

    return ref


# ── Error metrics ────────────────────────────────────────────────────────────
def nrmse_by_category(model_df, ref_df):
    """RMSE and NRMSE per category. NRMSE normalises on the reference mean."""
    cats = [c for c in CATEGORIES
            if c in model_df.columns and c in ref_df.columns]
    rows = []
    for c in cats:
        m = model_df[c].to_numpy(dtype=float)
        r = ref_df[c].to_numpy(dtype=float)
        n = min(len(m), len(r))
        rmse = float(np.sqrt(np.mean((m[:n] - r[:n]) ** 2)))
        mean_ref = float(np.mean(r[:n]))
        rows.append({"category": c, "rmse_mw": rmse,
                     "ref_mean_mw": mean_ref,
                     "nrmse": np.nan if mean_ref == 0 else rmse / mean_ref})
    return pd.DataFrame(rows).set_index("category")


def weighted_nrmse(err):
    """NRMSE across categories weighted by each one's share of reference output.

    Categories the reference never runs carry no weight, so a technology the
    model spuriously dispatches shows up in its own row rather than being
    averaged away — read the per-category table alongside this number.
    """
    e = err.dropna(subset=["nrmse"])
    w = e["ref_mean_mw"] / e["ref_mean_mw"].sum()
    return float((e["nrmse"] * w).sum())


def total_nrmse(model_df, ref_df):
    """Single NRMSE over the whole (hour × category) matrix."""
    cats = [c for c in CATEGORIES
            if c in model_df.columns and c in ref_df.columns]
    m = model_df[cats].to_numpy(dtype=float).ravel()
    r = ref_df[cats].to_numpy(dtype=float).ravel()
    return float(np.sqrt(np.mean((m - r) ** 2)) / np.mean(r))


# ── Figures ──────────────────────────────────────────────────────────────────
def _stack(ax, piv, title, ylabel=None, xlabel=False, legend=False):
    """Stacked area of a [hour × category] frame, splitting +/- contributions."""
    cols = [c for c in STACK_ORDER if c in piv.columns]
    x = piv.index.to_numpy()
    pos = piv[cols].clip(lower=0.0)
    neg = piv[cols].clip(upper=0.0)
    ax.stackplot(x, [pos[c].to_numpy() for c in cols],
                 colors=[CAT_COLOR[c] for c in cols], labels=cols, alpha=0.95)
    if (neg.to_numpy() < 0).any():
        ax.stackplot(x, [neg[c].to_numpy() for c in cols],
                     colors=[CAT_COLOR[c] for c in cols], alpha=0.95)
    ax.axhline(0, color="0.35", lw=0.6)
    ax.set_title(title)
    ax.set_xlim(0, 23)
    ax.set_xticks(range(0, 24, 3))
    if xlabel:
        ax.set_xlabel("Hour")
    if ylabel:
        ax.set_ylabel(ylabel)
    if legend:
        ax.legend(loc="upper left", ncol=2, fontsize=7)


def fig_da_mix(ch, ref, save=False, name="val_da_mix"):
    """Day-ahead generation mix: model against the OMIE cleared programme.

    All four panels share one y-axis so the model and the reference can be read
    against each other directly rather than on independently scaled rows.
    """
    fig, axes = plt.subplots(2, 2, figsize=(9.0, 5.8), sharex=True, sharey=True)
    for j, date in enumerate(DAYS):
        _stack(axes[0, j], gate_mix(ch, "da", date), f"Model — {DAY_LABEL[date]}",
               ylabel="MW" if j == 0 else None)
        _stack(axes[1, j], ref["omie"][date], f"OMIE — {DAY_LABEL[date]}",
               ylabel="MW" if j == 0 else None, xlabel=True)
    handles, labels = axes[0, 0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=6,
               bbox_to_anchor=(0.5, -0.08))
    fig.tight_layout()
    return _save(fig, name, save)


def fig_nrmse(ch, ref, save=False, name="val_nrmse"):
    """Per-technology RMSE with the NRMSE annotated, both days side by side."""
    fig, axes = plt.subplots(1, 2, figsize=(9.0, 3.4), sharey=False)
    for j, date in enumerate(DAYS):
        err = nrmse_by_category(gate_mix(ch, "da", date), ref["omie"][date])
        err = err.sort_values("rmse_mw", ascending=False)
        ax = axes[j]
        colors = [CAT_COLOR.get(c, "#777") for c in err.index]
        ax.bar(range(len(err)), err["rmse_mw"], color=colors,
               edgecolor="0.25", linewidth=0.5)
        for i, (_, r) in enumerate(err.iterrows()):
            if np.isfinite(r["nrmse"]):
                ax.text(i, r["rmse_mw"], f"{r['nrmse']:.0%}",
                        ha="center", va="bottom", fontsize=7, rotation=90)
        ax.set_xticks(range(len(err)))
        ax.set_xticklabels(err.index, rotation=45, ha="right")
        ax.set_ylabel("RMSE (MW)" if j == 0 else None)
        wn = weighted_nrmse(err)
        ax.set_title(f"{DAY_LABEL[date]} — output-weighted NRMSE {wn:.0%}")
        ax.margins(y=0.22)
    fig.tight_layout()
    return _save(fig, name, save)


def fig_prices(ch, ref, save=False, name="val_prices"):
    """Cleared price by gate against the OMIE day-ahead price."""
    mp = ch["market_prices"]
    fig, axes = plt.subplots(1, 2, figsize=(9.0, 3.2), sharey=False)
    for j, date in enumerate(DAYS):
        ax = axes[j]
        ax.plot(ref["price"][date].index, ref["price"][date].to_numpy(),
                color="0.15", lw=2.0, label="OMIE (day-ahead)", zorder=5)
        if mp is not None:
            for g, style in [("DA", "-"), ("ID2", "--"), ("BAL", ":")]:
                s = mp[(mp["date"] == date) & (mp["stage"] == g)]
                if not s.empty:
                    ax.plot(s["hour"], s["price_eur_mwh"], style,
                            label=f"Model {g}", alpha=0.9)
        ax.set_title(DAY_LABEL[date])
        ax.set_xlabel("Hour")
        ax.set_xlim(0, 23)
        ax.set_xticks(range(0, 24, 3))
        if j == 0:
            ax.set_ylabel("Price (EUR/MWh)")
            ax.legend(loc="best")
    fig.tight_layout()
    return _save(fig, name, save)


def fig_pumped_storage(ch, ref, save=False, name="val_pumped_storage"):
    """Pumped-storage schedule against the ENTSO-E actual (the only source that
    separates pumping from discharge; OMIE reports no storage on these days)."""
    fig, axes = plt.subplots(1, 2, figsize=(9.0, 3.2), sharey=True)
    for j, date in enumerate(DAYS):
        ax = axes[j]
        model = gate_mix(ch, "da", date)
        if "Pumped storage" in model.columns:
            ax.bar(model.index, model["Pumped storage"],
                   color=CAT_COLOR["Pumped storage"], label="Model (DA)",
                   width=0.8, edgecolor="0.3", linewidth=0.4)
        e = ref["entsoe"][date]
        if "Pumped storage net" in e.columns:
            ax.plot(e.index, e["Pumped storage net"], color="0.15", lw=1.8,
                    marker="o", ms=2.5, label="ENTSO-E actual (net)")
        ax.axhline(0, color="0.35", lw=0.7)
        ax.set_title(DAY_LABEL[date])
        ax.set_xlabel("Hour")
        ax.set_xlim(-0.6, 23.6)
        ax.set_xticks(range(0, 24, 3))
        if j == 0:
            ax.set_ylabel("MW  (+ generating, − pumping)")
            ax.legend(loc="best")
    fig.tight_layout()
    return _save(fig, name, save)


def gate_movement(ch, date):
    """Signed MW change per category at each gate, versus its predecessor."""
    seq = [g for g in GATES if g in ch["gates"]]
    out = {}
    for a, b in zip(seq, seq[1:]):
        out[GATE_LABEL[b]] = gate_mix(ch, b, date) - gate_mix(ch, a, date)
    if ch["rd"] is not None and seq:
        out["RD"] = gate_mix(ch, "rd", date) - gate_mix(ch, seq[-1], date)
    return out


def fig_gate_movement(ch, save=False, name="gate_movement"):
    """Dispatch change introduced by each gate, per technology, both days."""
    mv_days = {d: gate_movement(ch, d) for d in DAYS}
    stages = list(mv_days[DAYS[0]].keys())
    fig, axes = plt.subplots(2, len(stages), figsize=(2.1 * len(stages), 5.2),
                             sharex=True, sharey="row")
    axes = np.atleast_2d(axes)
    for i, date in enumerate(DAYS):
        for j, st in enumerate(stages):
            ax = axes[i, j]
            piv = mv_days[date][st]
            cols = [c for c in STACK_ORDER if c in piv.columns]
            bottom_p = np.zeros(24)
            bottom_n = np.zeros(24)
            for c in cols:
                v = piv[c].reindex(range(24)).fillna(0.0).to_numpy()
                p, n = np.clip(v, 0, None), np.clip(v, None, 0)
                ax.bar(range(24), p, bottom=bottom_p, color=CAT_COLOR[c],
                       width=0.9, label=c)
                ax.bar(range(24), n, bottom=bottom_n, color=CAT_COLOR[c],
                       width=0.9)
                bottom_p += p
                bottom_n += n
            ax.axhline(0, color="0.35", lw=0.6)
            if i == 0:
                ax.set_title(st)
            if j == 0:
                ax.set_ylabel(f"{DAY_LABEL[date]}\nΔ MW")
            if i == 1:
                ax.set_xlabel("Hour")
            ax.set_xticks(range(0, 24, 6))
    handles, labels = axes[0, 0].get_legend_handles_labels()
    uniq = dict(zip(labels, handles))
    fig.legend(uniq.values(), uniq.keys(), loc="lower center", ncol=6,
               bbox_to_anchor=(0.5, -0.05))
    fig.tight_layout()
    return _save(fig, name, save)


def fig_network_loading(ch, save=False, name="network_loading"):
    """Branch loading after redispatch: duration curve and hours above threshold."""
    br = ch["branch_flows"]
    fig, axes = plt.subplots(1, 2, figsize=(9.0, 3.4),
                             gridspec_kw={"width_ratios": [1.0, 1.15]})

    ax = axes[0]
    for date, color in zip(DAYS, ["#f0a03c", "#3f7fbf"]):
        v = np.sort(br[br["date"] == date]["loading_pct"].to_numpy())[::-1]
        ax.plot(100 * np.arange(len(v)) / len(v), v, color=color,
                label=DAY_LABEL[date])
    # Labels must sit INSIDE the axes: rcParams sets savefig.bbox = "tight", so
    # any artist placed beyond xlim silently stretches the saved figure and
    # leaves a wide white margin in the PDF.
    for thr in (70, 90, 100):
        ax.axhline(thr, color="0.6", lw=0.6, ls="--")
        ax.text(0.985, thr + 1.5, f"{thr}%", fontsize=7, ha="right",
                color="0.4", transform=ax.get_yaxis_transform())
    ax.set_xlabel("Share of branch-hours exceeding (%)")
    ax.set_ylabel("Loading (% of rating)")
    ax.set_xlim(0, 20)
    ax.set_title("Loading duration (post-redispatch)")
    ax.legend(loc="best")

    # Right panel: the branches that are actually tight.  A bar chart of counts
    # above 50/70/90/100 % decays so steeply (185 → 67 → 21 → 0) that its right
    # half is blank; naming the busiest corridors uses the same space and says
    # which ones bind.
    ax = axes[1]
    hrs = {d: (br[(br["date"] == d) & (br["loading_pct"] > 70)]
               .groupby("branch_name").size()) for d in DAYS}
    top = (pd.concat(hrs, axis=1).fillna(0.0)
             .assign(_t=lambda t: t.sum(axis=1))
             .sort_values("_t", ascending=False).drop(columns="_t").head(12))
    y = np.arange(len(top))[::-1]
    w = 0.38
    for k, (date, color) in enumerate(zip(DAYS, ["#f0a03c", "#3f7fbf"])):
        ax.barh(y + (0.5 - k) * w, top[date].to_numpy(), height=w,
                color=color, edgecolor="0.25", linewidth=0.5,
                label=DAY_LABEL[date])
    ax.set_yticks(y)
    ax.set_yticklabels(top.index, fontsize=6.5)
    ax.set_xlabel("Hours above 70 % of rating")
    ax.set_title("Most heavily loaded branches")
    ax.legend(loc="lower right", fontsize=7)
    ax.margins(x=0.12)

    fig.tight_layout()
    return _save(fig, name, save)


# ── Redispatch map ───────────────────────────────────────────────────────────
def _nuts3_polygons():
    """Exterior rings of Data/nuts3_es.geojson as (lon, lat) arrays.

    Parsed by hand rather than through geopandas/shapely, which are not part of
    the environment; only the outlines are needed as a background.
    """
    import json
    f = ROOT / "Data" / "nuts3_es.geojson"
    if not f.exists():
        return []
    gj = json.loads(f.read_text(encoding="utf-8", errors="replace"))
    rings = []
    for feat in gj.get("features", []):
        geom = feat.get("geometry") or {}
        polys = ([geom.get("coordinates", [])] if geom.get("type") == "Polygon"
                 else geom.get("coordinates", []))
        for poly in polys:
            if poly and poly[0]:
                rings.append(np.asarray(poly[0], dtype=float))
    return rings


def _bus_coords():
    """bus_i (1-based row index, as PowerModels numbers them) → (lon, lat)."""
    bus = pd.read_csv(ROOT / "Data" / "Bus_Data.csv", encoding="utf-8-sig")
    return (bus["x"].to_numpy(dtype=float), bus["y"].to_numpy(dtype=float))


def redispatch_by_bus(ch, date):
    """Net MWh/day each bus gains (+) or gives up (−) in the AC redispatch.

    The copper-plate stages export the unit NAME in their `gen_id` column while
    the AC stage exports the integer PowerModels index there and the name in
    `unit_name` — so the two must be joined on the name, not on `gen_id`.
    """
    bal = pd.read_csv(RESULTS / "bal_dispatch.csv").rename(columns={"gen_id": "unit"})
    rd = pd.read_csv(RESULTS / "gen_dispatch.csv").rename(columns={"unit_name": "unit"})
    bal, rd = bal[bal["date"] == date], rd[rd["date"] == date]
    b = bal.groupby(["hour", "unit"])["dispatch_mw"].sum()
    r = rd.groupby(["hour", "unit"])["dispatch_mw"].sum()
    delta = pd.concat([b.rename("b"), r.rename("r")], axis=1).fillna(0.0)
    delta = (delta["r"] - delta["b"]).rename("delta").reset_index()
    bus_of = rd[["unit", "bus_i"]].drop_duplicates().set_index("unit")["bus_i"]
    delta["bus_i"] = delta["unit"].map(bus_of)
    return delta.dropna(subset=["bus_i"]).groupby("bus_i")["delta"].sum()


def fig_redispatch_map(ch, save=False, name="redispatch_map"):
    """Where the AC redispatch acts: branch loading and net change per bus."""
    lon, lat = _bus_coords()
    rings = _nuts3_polygons()
    br = ch["branch_flows"]

    fig, axes = plt.subplots(1, 2, figsize=(9.0, 4.2))
    fig.subplots_adjust(left=0.01, right=0.90, top=0.90, bottom=0.02, wspace=0.02)
    cmap = mpl.colors.LinearSegmentedColormap.from_list(
        "load", ["#c9d4dd", "#7fa8c8", "#e8a13c", "#c02f1d"])
    norm = mpl.colors.Normalize(0, 100)

    for ax, date in zip(axes, DAYS):
        for ring in rings:
            ax.plot(ring[:, 0], ring[:, 1], color="0.86", lw=0.35, zorder=0)

        b = br[br["date"] == date]
        peak = b.groupby(["branch_name", "from_bus", "to_bus"])["loading_pct"].max()
        segs, cols, lws = [], [], []
        for (_, f, t), pct in peak.items():
            i, j = int(f) - 1, int(t) - 1
            if not (0 <= i < len(lon) and 0 <= j < len(lon)):
                continue
            if abs(lon[i] - lon[j]) < 1e-9 and abs(lat[i] - lat[j]) < 1e-9:
                continue                      # transformer: no geographic extent
            segs.append([(lon[i], lat[i]), (lon[j], lat[j])])
            cols.append(cmap(norm(pct)))
            lws.append(0.35 if pct < 50 else 0.9 if pct < 70 else 1.6)
        ax.add_collection(mpl.collections.LineCollection(
            segs, colors=cols, linewidths=lws, zorder=1))

        d = redispatch_by_bus(ch, date) / 1e3          # GWh/day
        idx = np.array([int(i) - 1 for i in d.index])
        keep = (idx >= 0) & (idx < len(lon))
        idx, val = idx[keep], d.to_numpy()[keep]
        big = np.abs(val) > 0.05
        ax.scatter(lon[idx[big]], lat[idx[big]],
                   s=18 + 260 * np.abs(val[big]) / max(np.abs(val).max(), 1e-9),
                   c=["#c02f1d" if v > 0 else "#2f6fb0" for v in val[big]],
                   alpha=0.7, edgecolors="0.2", linewidths=0.3, zorder=2)

        # Headline volume is the UNIT-level |Δ| quoted in the text; summing the
        # bus-level net would net off units that move against each other at the
        # same bus and understate the redispatch effort.
        vol = _redispatch_volume(date)
        ax.set_title(f"{DAY_LABEL[date]} — {vol:.1f} GWh redispatched", fontsize=9.5)
        ax.set_xlim(-9.5, 4.5); ax.set_ylim(35.8, 44.0)
        ax.set_aspect(1.28)
        ax.set_xticks([]); ax.set_yticks([])
        for s in ax.spines.values():
            s.set_visible(False)

    handles = [plt.Line2D([], [], marker="o", ls="", ms=7, mfc=c, mec="0.2", label=l)
               for c, l in (("#c02f1d", "bus increases output"),
                            ("#2f6fb0", "bus reduces output"))]
    axes[0].legend(handles=handles, loc="lower left", fontsize=7, frameon=False)
    cax = fig.add_axes([0.915, 0.15, 0.016, 0.66])
    cb = fig.colorbar(mpl.cm.ScalarMappable(norm=norm, cmap=cmap), cax=cax)
    cb.set_label("Peak branch loading (% of rating)", fontsize=8)
    cb.ax.tick_params(labelsize=7)
    return _save(fig, name, save)


def _redispatch_volume(date):
    """Unit-level sum of |Δ| between the balancing schedule and the AC OPF [GWh]."""
    bal = pd.read_csv(RESULTS / "bal_dispatch.csv").rename(columns={"gen_id": "unit"})
    rd = pd.read_csv(RESULTS / "gen_dispatch.csv").rename(columns={"unit_name": "unit"})
    b = bal[bal["date"] == date].groupby(["hour", "unit"])["dispatch_mw"].sum()
    r = rd[rd["date"] == date].groupby(["hour", "unit"])["dispatch_mw"].sum()
    j = pd.concat([b.rename("b"), r.rename("r")], axis=1).fillna(0.0)
    return float((j["r"] - j["b"]).abs().sum() / 1e3)


def summary_table(ch, ref):
    """Headline validation numbers for the text of Section 5.1."""
    rows = []
    for date in DAYS:
        model = gate_mix(ch, "da", date)
        omie = ref["omie"][date]
        err = nrmse_by_category(model, omie)
        mp = ch["market_prices"]
        pm = (mp[(mp["date"] == date) & (mp["stage"] == "DA")]["price_eur_mwh"]
              if mp is not None else pd.Series(dtype=float))
        po = ref["price"][date]
        rows.append({
            "day": DAY_LABEL[date],
            "model_energy_GWh": model.to_numpy().sum() / 1e3,
            "omie_energy_GWh": omie.to_numpy().sum() / 1e3,
            "weighted_NRMSE": weighted_nrmse(err),
            "total_NRMSE": total_nrmse(model, omie),
            "model_price_mean": pm.mean() if len(pm) else np.nan,
            "omie_price_mean": po.mean(),
        })
    return pd.DataFrame(rows).set_index("day").round(2)
