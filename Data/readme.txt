Update in 2024_11_11

lines.csv
Line added: LTGES1447	ES01097	ES01032	220	1	4	f	0.06	0.301	12.5	1.29
description: The 220 kV line has been added to represent the actual two-circuit 132 kV line in Bilbao. Neglecting the 132 kV line had caused infeasibilities in the results of the AC OPF.

=========================================================================
Update in 2024_11_11

lines.csv
line added:
LTGES1448	ES01088	ES00654	220	1	20	f	0.06	0.301	12.5	1.29
LTGES1449	ES00637	ES00569	220	1	20	f	0.06	0.301	12.5	1.29
LTGES1450	ES01122	ES00638	220	1	20	f	0.06	0.301	12.5	1.29

description: 220 kV Lines added to madrid, making the grid topology more aligned with ENTSO-E standards and also resolving infeasibilities.

=========================================================================
Update in 2024_11_11

lines.csv
Line characters edited:
LTGES1155a	ES01070	ES00488	220	3	3.3	f	0.06	0.301	12.5	1.29
LTGES1155b	ES01070	ES00488	220	3	3.3	f	0.06	0.301	12.5	1.29
LTGES1155c	ES01070	ES00488	220	3	3.3	f	0.06	0.301	12.5	1.29

description: The line LTGES1155, originally a single-circuit line, was converted into a 3-circuit line, making the grid topology more aligned with ENTSO-E standards and also resolving infeasibilities.

=========================================================================
Update in 2024_11_11

lines.csv

File format changed
description: The values in the "circuit" column were previously set to '1' for all lines, as each circuit was considered a unique line. However, the values now reflect the actual number of circuits associated with each main line.

=========================================================================
Update in 2024_12_02

generarion.csv

There were inconsistencies about the run_of_river units. So I gethered data of run of rivers from OSM and add it to the GEM data.

=========================================================================
Update on 2025_10_8

generation_cost_EVS.csv

The data came from energy vision scenario, taking into account the fuel cost and efficiency.



