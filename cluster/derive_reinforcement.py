"""Steps 4-5 of docs/method_grid_reinforcement_identification.md.

Turns an over-rated, uncongested diagnostic solve into a ranked, sized list of
lines to expand, in the format [redispatch].extra_line_scale_file expects.

    python cluster/derive_reinforcement.py <results_dir> <lrf_used> [out.csv]

Sizing convention
-----------------
The model builds a branch limit as

    usable = nominal * line_rating_factor * rating_scale          (data_preparation.jl)

and for a listed line run_opf.jl sets rating_scale = factor / line_rating_factor,
so `factor` IS the usable limit as a fraction of today's nominal.

The diagnostic measures

    req_factor = max_hours(loading_pct) * lrf_used / 100 = peak|flow| / nominal

which carries no derate.  Writing factor = req_factor would let the reinforced
line sit exactly on its measured peak with NO margin, while every other line on
the system keeps the 20 % security derate.  To treat them alike:

    factor = req_factor / derate                                  (derate = 0.80)

so the reinforced line gets the same 20 % headroom, and the asset that actually
has to be built is req_factor / derate times today's nameplate.  That division
also absorbs the ~4 % a DC pass under-reports on the binding branches, which
carry a little reactive power the linear model does not see.

Guard
-----
The whole method rests on the diagnostic being UNCONGESTED.  A branch pinned at
100 % returns loading_pct * lrf / 100 == lrf for every such branch -- the rating
used, not the rating needed.  The script refuses to write a list in that case.
"""
import sys
import pandas as pd

DERATE = 0.80          # [network].line_rating_factor in normal operation

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    rdir, lrf = sys.argv[1], float(sys.argv[2])
    out = sys.argv[3] if len(sys.argv) > 3 else None

    b = pd.read_csv(f"{rdir}/branch_flows.csv")
    hours = b.groupby(["date", "hour"]).ngroups
    peak = b.groupby("branch_name").loading_pct.max()

    pinned = peak[peak >= 99.9]
    print(f"diagnostic: {rdir}")
    print(f"  {hours} hours, {len(peak)} branches, line_rating_factor used = {lrf}")
    if len(pinned):
        print(f"\n  ABORT: {len(pinned)} branches are still at their limit "
              f"(loading >= 99.9 %). The solve is congested, so req_factor would "
              f"just read back {lrf} for each of them.\n"
              f"  Re-run the diagnostic with a higher line_rating_factor.")
        print(pinned.sort_values(ascending=False).head(10).to_string())
        sys.exit(1)
    print(f"  uncongested: peak loading {peak.max():.1f} % -- good")

    req = (peak * lrf / 100).sort_values(ascending=False).rename("req_factor")
    factor = (req / DERATE).rename("factor")

    print(f"\n  system-minimum line_rating_factor = {req.iloc[0]:.2f}  "
          f"(set by {req.index[0]})")
    for t in (0.64, 0.80, 1.0, 1.5, 2.0, 3.0):
        print(f"    branches with req_factor > {t:4.2f}: {(req > t).sum():4d}")

    # run_opf.jl drops any entry whose factor <= line_rating_factor (the merged
    # multiplier would be <= 1.0), so listing them is pointless: keep the lines
    # that genuinely need more usable capacity than the derate already gives.
    keep = factor[factor > DERATE].round(3)
    print(f"\n  writing {len(keep)} lines (factor > {DERATE}, i.e. req_factor > {DERATE**2:.2f})")
    print(pd.DataFrame({"req_factor": req.loc[keep.index].round(3),
                        "factor": keep}).head(20).to_string())

    if out:
        keep.rename_axis("line_id").reset_index().to_csv(out, index=False)
        print(f"\n  -> {out}")
    else:
        print("\n  (no output path given; nothing written)")

if __name__ == "__main__":
    main()
