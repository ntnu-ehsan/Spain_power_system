"""Derive line-specific intra- and inter-NUTS3 thermal reinforcements.

Usage:
    python cluster/derive_combined_reinforcement.py <results_dir> <out.csv>

International assets remain protected. The input must be a complete selective
diagnostic run whose eligible domestic classes are no longer pinned.
"""

import sys
from pathlib import Path

import pandas as pd


GOOD_STATUS = {"OPTIMAL", "LOCALLY_SOLVED"}
CANDIDATE_CLASSES = {"intra_nuts3", "inter_nuts3"}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rdir = Path(sys.argv[1])
    out = Path(sys.argv[2])

    summary = pd.read_csv(rdir / "summary.csv")
    if len(summary) != 336 or not set(summary.status).issubset(GOOD_STATUS):
        sys.exit("ABORT: diagnostic must contain 336 successfully solved hours")
    if "load_shed_mw" in summary:
        max_shed = pd.to_numeric(summary.load_shed_mw, errors="coerce").max()
        if pd.notna(max_shed) and max_shed > 0.1:
            sys.exit(f"ABORT: diagnostic sheds up to {max_shed:.1f} MW")

    branches = pd.read_csv(rdir / "branch_peaks.csv")
    required = {"branch_name", "asset_class", "loading_pct",
                "diagnostic_multiplier", "base_line_rating_factor"}
    missing = required.difference(branches.columns)
    if missing:
        sys.exit("ABORT: branch_peaks.csv missing " + ", ".join(sorted(missing)))
    if branches.branch_name.duplicated().any():
        sys.exit("ABORT: duplicate branch names in branch_peaks.csv")

    candidates = branches[branches.asset_class.isin(CANDIDATE_CLASSES)].copy()
    for col in ("loading_pct", "diagnostic_multiplier", "base_line_rating_factor"):
        candidates[col] = pd.to_numeric(candidates[col], errors="raise")
    pinned = candidates[candidates.loading_pct >= 99.9]
    if len(pinned):
        sys.exit("ABORT: candidate branches remain pinned:\n" +
                 pinned[["branch_name", "asset_class", "loading_pct"]]
                 .head(20).to_string(index=False))

    candidates["factor"] = (
        candidates.loading_pct
        * candidates.base_line_rating_factor
        * candidates.diagnostic_multiplier / 100.0
    )
    base = candidates.base_line_rating_factor
    keep = candidates[candidates.factor > base + 1e-9].copy()
    keep = keep.sort_values("factor", ascending=False)
    output = keep[["branch_name", "factor"]].rename(
        columns={"branch_name": "line_id"})
    output.factor = output.factor.round(3)
    out.parent.mkdir(parents=True, exist_ok=True)
    output.to_csv(out, index=False)

    print(f"diagnostic: {rdir}")
    for asset_class in ("intra_nuts3", "inter_nuts3"):
        part = keep[keep.asset_class == asset_class]
        print(f"  {asset_class}: {len(part)} reinforced lines; "
              f"maximum absolute factor {part.factor.max() if len(part) else 0:.3f}")
    print(f"  international: fixed and excluded")
    print(f"  -> {out} ({len(output)} lines)")


if __name__ == "__main__":
    main()
