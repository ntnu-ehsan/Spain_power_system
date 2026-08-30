# Grid-reinforcement sensitivity findings for the paper

Last updated: 2026-08-29

## NECPEssentials 2035

The final diagnostic uses two sampled weeks (336 hours), DC redispatch,
hour-specific coordinated directional NTCs, an NTC reliability margin of 0.70,
and `country_total` cross-border redistribution. Day-ahead country totals are
preserved exactly in redispatch. International line ratings remain fixed at
their original values. ID2, ID3, CID, and balancing are bypassed, so the tested
chain is DA -> redispatch. All cases solved all 336 hours with zero load
shedding, and the fixed-country-total validation passed in every hour.

The inter-NUTS3 sweep used an intentionally non-binding 10x intra-NUTS3
multiplier. Inter-NUTS3 multipliers of 1.0, 1.5, 2.0, 3.0, 4.0, and 4.5 left
13, 7, 3, 1, 1, and 1 inter-NUTS3 branches above 95% loading, respectively.
The maximum inter-NUTS3 loading was still 99.1% at 4.5x. At 5.0x, evaluated in
the subsequent intra-NUTS3 sweep, maximum inter-NUTS3 loading fell to 89.2%.
Therefore 5.0x was retained as the robust diagnostic allowance for the second
sweep.

With inter-NUTS3 capacity fixed at 5.0x, intra-NUTS3 multipliers of 1.0, 1.5,
2.0, 2.5, 2.75, 3.0, and 4.0 left 65, 16, 5, 5, 5, 0, and 0 intra-NUTS3
branches above 95% loading. Maximum intra-NUTS3 loading fell from 100% at
2.75x to 94.1% at 3.0x and 70.6% at 4.0x. Increasing the multiplier beyond
3.0x therefore did not remove any additional domestic near-binding branch.
The three branches still above 95% at 3.0x and 4.0x were international:
`LTGES0177`, `LTGES1027`, and `NEWXB_ES220_FR`.

The paper-relevant interpretation is that EMPIRE's zonal transfer expansion is
not, by itself, sufficient to guarantee nodal deliverability. In this sampled
diagnostic, substantial additional freedom was required for both inter-NUTS3
and intra-NUTS3 Spanish branches before the zonal DA schedules became robustly
deliverable. This should be reported as evidence from a DC, sampled-horizon
sensitivity rather than as a final transmission investment prescription. The
candidate reinforcement set should still be confirmed by the planned AC
validation.

The compact numerical record is in
`docs/paper_grid_reinforcement_sensitivity.csv`. Raw outputs are under:

- `results/NECPEssentials_sens_hourlyntc0p7_intra10_inter*_da_rd/`
- `results/NECPEssentials_sens_hourlyntc0p7_intra*_inter5p0_da_rd/`

For each case, `hourly_ntc.csv` contains the 336 hourly NTC bounds,
`summary.csv` contains redispatch feasibility, `branch_peaks.csv` contains one
peak observation per branch, and `xb_flows.csv` / `xb_redispatch.csv` audit the
preserved country-level exchanges.

## Trinity 2035

The Trinity inter-NUTS3 sweep used the same two weather weeks and modelling
settings as NECPEssentials. With the intra-NUTS3 diagnostic multiplier fixed at
10x, inter-NUTS3 multipliers of 1.0, 1.5, 2.0, 3.0, 4.0, and 4.5 left 7, 4, 2,
0, 0, and 0 inter-NUTS3 branches above 95% loading. Maximum inter-NUTS3
loading was 100% through 2.0x, then fell to 81.0% at 3.0x, 60.7% at 4.0x, and
54.6% at 4.5x. Therefore 3.0x is the smallest tested robust allowance and is
used for the Trinity intra-NUTS3 sweep.

All six cases solved 336/336 redispatch hours. The selected 3.0x case had zero
load shedding. The unselected 4.5x case recorded a single 0.3 MWh load-shed
residual at 2024-08-24 hour 23 with `LOCALLY_SOLVED` status; it does not affect
the multiplier choice but is retained in the numerical record.

Raw inter-sweep outputs are under
`results/Trinity_sens_hourlyntc0p7_intra10p0_inter*_da_rd/`.

With inter-NUTS3 capacity fixed at 3.0x, intra-NUTS3 multipliers of 1.0, 1.5,
2.0, 2.5, 2.75, 3.0, and 4.0 left 33, 8, 2, 0, 0, 0, and 0 intra-NUTS3
branches above 95% loading. Maximum intra-NUTS3 loading fell from 100% at
2.0x to 81.9% at 2.5x. Thus 2.5x is the smallest tested robust multiplier for
Trinity. Maximum inter-NUTS3 loading remained below the criterion (81.0%) and
the two remaining branches above 95% were the fixed international assets
`LTGES0177` and `LTGES1027`, both on the France--ES212 boundary.

All seven intra-sweep cases solved 336/336 hours and passed the exact
country-total exchange validation. Rounded load-shed totals were between 0.0
and 1.0 MWh over 336 hours; the selected 2.5x case contained one rounded 0.1 MW
observation. This is below the diagnostic rejection threshold and is negligible
relative to 25--34 GW system load, but it is retained rather than silently
rounded away.

The line-specific sizing calculation on the selected 2.5x case gives a
first-order minimum uncongested intra-NUTS3 multiplier of 2.05, set by
`LTGES0645`. It identifies 31 intra-NUTS3 candidates above the normal usable
0.80 rating factor: 13 exceed nominal rating, three exceed 1.5x nominal, and
none exceed 2.0x nominal. The ranked list is stored in
`results/Trinity_sens_hourlyntc0p7_intra2p5_inter3p0_da_rd/reinforcement.csv`.

For comparison, the corresponding NECPEssentials sizing at intra=3.0 and
inter=5.0 identifies 66 intra-NUTS3 candidates above 0.80, including 39 above
nominal, seven above 1.5x, and five above 2.0x. Its first-order minimum
multiplier is 2.82, set jointly by `LTGES1367`, `LTGES1433`, and `LTGES1368`;
the ranked list is stored in
`results/NECPEssentials_sens_hourlyntc0p7_intra3p0_inter5p0_da_rd/reinforcement.csv`.

Raw Trinity intra-sweep outputs are under
`results/Trinity_sens_hourlyntc0p7_intra*_inter3p0_da_rd/`.
