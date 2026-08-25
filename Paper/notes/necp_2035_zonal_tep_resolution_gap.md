# Candidate paper finding: zonal TEP versus nodal feasibility

Evidence package: `Paper/evidence/necp_2035_selective_reinforcement_2w/`.

50% inter-NUTS3 sensitivity:
`Paper/evidence/necp_2035_interzonal_50pct_2w/`.

100% inter-NUTS3 sensitivity:
`Paper/evidence/necp_2035_interzonal_100pct_2w/`.

## Paper-ready wording

To distinguish missing within-zone capacity from the corridor investments
selected by EMPIRE, we retained the EMPIRE-derived limits of all inter-NUTS3
and international branches and applied a factor-ten diagnostic relaxation only
to branches within each Spanish NUTS3 region. In a DC redispatch over two
non-contiguous sampled weeks (336 hours), only 112 hours were feasible. None of
the 1,997 relaxed intrazonal branches reached its diagnostic limit in the
solved hours, whereas 16 inter-NUTS3 and two international branches reached
their fixed limits. This result shows that aggregate corridor investment
decisions do not necessarily translate into a feasible nodal network once the
capacities are mapped to physical branches and Kirchhoff power flows are
enforced. Zonal transmission expansion should therefore be followed by nodal
validation, with nodal congestion information fed back into the investment
stage where necessary.

## Do not overstate

- The intrazonal maximum was 24.8% **of a 10x diagnostic limit**, not 24.8% of
  the original rating.
- Branch peaks cover only the 112 solved hours; the 224 failed hours have no
  valid flow solution.
- The experiment establishes a failure of this coupled implementation for this
  sample, not a universal proof that every zonal TEP model is inaccurate.
- Before publication, test the effects of the 0.8 derate, corridor-to-branch
  mapping, copper-plate market clearing, redispatch flexibility, alternative
  temporal samples, and AC validation.

## Strongest currently supportable claim

> In the NECP 2035 case, EMPIRE's aggregate transmission expansion was not
> sufficient to guarantee nodal DC feasibility after disaggregation to the
> physical Spanish grid. This demonstrates the need for a nodal validation and
> feedback step in a zonal transmission-expansion workflow.

## Follow-up sensitivity: 50% inter-NUTS3 allowance

Giving every Spanish inter-NUTS3 branch 50% additional capacity improved
solver success only from 112 to 115 of 336 hours. Because the three newly
solved hours all required 1.15--1.56 GW of load shedding, successful hours
without material shedding increased only from 105 to 106. Five enlarged
inter-NUTS3 corridors and two fixed international links still reached 100%.
Thus, a uniform 50% corridor uplift is not sufficient; the next analysis should
identify targeted corridor requirements and separate them from international
transfer limits and redispatch-flexibility assumptions.

Doubling every Spanish inter-NUTS3 limit produced the same 115 successful hours
as the 50% case and increased no-shedding success by only one hour (106 to 107).
Four inter-NUTS3 corridors still reached their doubled limits, and the same two
fixed international links remained saturated. This plateau strengthens the
case for targeted corridor analysis and for separating international-transfer
and operational-flexibility constraints from domestic expansion needs.
