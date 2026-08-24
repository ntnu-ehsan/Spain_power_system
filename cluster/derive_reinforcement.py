"""Derive intrazonal reinforcement from a selective diagnostic solve.

Usage:
    python cluster/derive_reinforcement.py <results_dir> [out.csv]

Only same-NUTS3 Spanish branches marked ``reinforcement_eligible`` are sized.
Inter-NUTS3 and international branches retain EMPIRE capacity and may bind.
"""
import sys
from pathlib import Path

import pandas as pd


def _as_bool(series):
    if series.dtype == bool:
        return series
    return series.astype(str).str.lower().isin(["true", "1", "yes"])


def main():
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        sys.exit(__doc__)
    rdir = Path(sys.argv[1])
    out = sys.argv[2] if len(sys.argv) == 3 else None

    summary_file = rdir / "summary.csv"
    if not summary_file.is_file():
        sys.exit(f"ABORT: missing {summary_file}; cannot verify every diagnostic hour")
    summary = pd.read_csv(summary_file)
    required_summary = {"date", "hour", "status"}
    missing = required_summary.difference(summary.columns)
    if missing:
        sys.exit(f"ABORT: {summary_file} is missing columns: {', '.join(sorted(missing))}")
    if summary.empty:
        sys.exit(f"ABORT: {summary_file} contains no diagnostic hours")
    hours = len(summary)
    good_status = summary.status.isin(["OPTIMAL", "LOCALLY_SOLVED"])
    if not good_status.all():
        bad = summary.loc[~good_status, ["date", "hour", "status"]]
        print(f"ABORT: {len(bad)}/{hours} diagnostic hours did not solve successfully")
        print(bad.head(20).to_string(index=False))
        sys.exit(1)
    if "load_shed_mw" in summary.columns:
        max_shed = pd.to_numeric(summary.load_shed_mw, errors="coerce").max()
        if pd.notna(max_shed) and max_shed > 0.1:
            sys.exit(f"ABORT: diagnostic sheds up to {max_shed:.1f} MW; "
                     "the inferred unconstrained flow is not valid")

    peaks_file = rdir / "branch_peaks.csv"
    flows_file = rdir / "branch_flows.csv"
    if peaks_file.is_file():
        branches = pd.read_csv(peaks_file)
        source = peaks_file.name
        if branches.branch_name.duplicated().any():
            sys.exit(f"ABORT: duplicate branch_name rows in {peaks_file}")
    elif flows_file.is_file():
        raw = pd.read_csv(flows_file)
        idx = raw.groupby("branch_name").loading_pct.idxmax()
        branches = raw.loc[idx]
        source = flows_file.name
    else:
        sys.exit(f"ABORT: neither {peaks_file} nor {flows_file} exists")

    required = {"branch_name", "loading_pct", "reinforcement_eligible",
                "diagnostic_multiplier", "base_line_rating_factor", "asset_class"}
    missing = required.difference(branches.columns)
    if missing:
        sys.exit(f"ABORT: {source} is missing columns: {', '.join(sorted(missing))}. "
                 "This is not a selective intrazonal diagnostic result.")
    if branches.empty:
        sys.exit(f"ABORT: {source} contains no branch results")

    branches = branches.set_index("branch_name")
    mask = _as_bool(branches.reinforcement_eligible)
    eligible = branches.loc[mask].copy()
    fixed = branches.loc[~mask].copy()
    if eligible.empty:
        sys.exit("ABORT: no same-NUTS3 Spanish reinforcement candidates were found")
    bad_class = eligible[eligible.asset_class != "intra_nuts3"]
    bad_synthetic = eligible[
        eligible.index.to_series().str.startswith(("NEWES_", "NEWXB_"))]
    if len(bad_class) or len(bad_synthetic):
        sys.exit("ABORT: reinforcement eligibility metadata violates the intrazonal-only policy")

    eligible["loading_pct"] = pd.to_numeric(eligible.loading_pct, errors="raise")
    eligible["diagnostic_multiplier"] = pd.to_numeric(
        eligible.diagnostic_multiplier, errors="raise")
    eligible["base_line_rating_factor"] = pd.to_numeric(
        eligible.base_line_rating_factor, errors="raise")
    peak = eligible.loading_pct.sort_values(ascending=False)

    print(f"diagnostic: {rdir} ({source})")
    print(f"  {hours} hours, {len(branches)} branches: {len(eligible)} eligible "
          f"intrazonal, {len(fixed)} fixed EMPIRE/international")
    if len(fixed):
        fixed_loading = pd.to_numeric(fixed.loading_pct, errors="coerce")
        print(f"  fixed-corridor peak loading = {fixed_loading.max():.1f} % "
              f"({(fixed_loading >= 99.9).sum()} at >= 99.9 %; allowed)")

    pinned = peak[peak >= 99.9]
    if len(pinned):
        print(f"\n  ABORT: {len(pinned)} eligible branches remain at their limit. "
              "Re-run with a higher intra-NUTS3 diagnostic multiplier.")
        print(pinned.head(10).to_string())
        sys.exit(1)
    print(f"  eligible network uncongested: peak loading {peak.max():.1f} % -- good")

    # diagnostic limit = nominal * base_lrf * diagnostic_multiplier
    req = (eligible.loading_pct * eligible.base_line_rating_factor *
           eligible.diagnostic_multiplier / 100).sort_values(ascending=False)
    req.name = "req_factor"
    derates = eligible.base_line_rating_factor.unique()
    if len(derates) != 1:
        sys.exit(f"ABORT: eligible branches contain multiple base rating factors: {derates}")
    derate = float(derates[0])
    factor = (req / derate).rename("factor")

    print(f"\n  minimum uncongested diagnostic multiplier = {factor.iloc[0]:.2f} "
          f"(set by {factor.index[0]})")
    for threshold in (0.64, 0.80, 1.0, 1.5, 2.0, 3.0):
        print(f"    branches with req_factor > {threshold:4.2f}: "
              f"{(req > threshold).sum():4d}")

    keep = factor[factor > derate].round(3)
    print(f"\n  writing {len(keep)} intrazonal lines "
          f"(factor > normal usable limit {derate:.2f})")
    print(pd.DataFrame({"req_factor": req.loc[keep.index].round(3),
                        "factor": keep}).head(20).to_string())

    if out:
        keep.rename_axis("line_id").reset_index().to_csv(out, index=False)
        print(f"\n  -> {out}")
    else:
        print("\n  (no output path given; nothing written)")


if __name__ == "__main__":
    main()
