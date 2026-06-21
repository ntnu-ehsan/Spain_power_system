# Spain Power System — AC OPF / Market Chain

Multi-hour AC OPF of the Spanish peninsular transmission grid, driven by an
in-house market chain (day-ahead → intraday gates → continuous intraday →
network redispatch). Configuration lives in `config.toml`; the network is
assembled in `data_preparation.jl` and solved in `run_opf.jl`.

## Shunt reactors (EHV line-charging compensation)

### Why
Every AC line is modelled as a full π-model with shunt charging susceptance
(`b_fr`/`b_to`, derived from each line's `c_per_length` in `data_preparation.jl`).
Across the ~48 000 km of 400/220 kV circuits this charging **generates roughly
21 GVAr** of reactive power at nominal voltage (≈ 17 GVAr from the 400 kV lines
alone). With nothing to absorb it, the OPF pushes that reactive power onto the
generators and bus voltages ride against the upper band — physically the job of
**shunt reactors**, which the real grid operates for exactly this purpose.

PowerModels reads shunts only from the network `shunt` component dict (bus-level
`gs`/`bs` fields are ignored), so the reactors are attached there as proper
shunt elements with **negative susceptance** (`bs < 0`), i.e. inductive /
reactive-absorbing.

### Installed fleet (data source)
The installed peninsular shunt-reactor capacity is taken from **Red Eléctrica de
España, Boletín Mensual de diciembre 2024**
(<https://www.ree.es/es/datos/publicaciones/boletines-mensuales/boletin-mensual-diciembre-2024>):

| Voltage group            | Installed | Units |
| ------------------------ | --------: | ----: |
| Peninsular 400 kV        | 11 750 MVAr | 80 |
| Peninsular ≤220 kV       |  3 722 MVAr | 55 |
| **Peninsular total**     | **15 472 MVAr** | **135** |

The Balearic and Canary systems are non-synchronous and **excluded** — only the
peninsular fleet is modelled, matching the network. (These totals are ~70 % of
the 400 kV charging and ~85 % of the ≤220 kV charging, consistent with the
standard EHV "≈80 % compensation" planning rule.)

### Disaggregation mechanism
The aggregate fleet is distributed to individual buses **in proportion to the AC
line charging connected at each bus** (`add_reactor_shunts!`):

1. Each bus is classified into a voltage group: `base_kv ≥ 380 kV` → **400 kV**,
   otherwise → **≤220 kV**.
2. The charging connected at a bus is the sum of the half-charging of its
   incident AC lines (`b_fr` at the from-bus, `b_to` at the to-bus). Transformers
   and HVDC links contribute nothing.
3. Within each group `g`, a bus receives
   `reactor = fleet[g] × (bus charging / total group charging)`, so the group
   totals reproduce the table above and reactors land where the charging is
   actually generated.

The per-bus **installed** result (the full 100 % fleet) is cached in
**`Data/reactors.csv`** with columns:

| column | meaning |
| --- | --- |
| `bus_id` | bus identifier |
| `base_kv` | bus nominal voltage |
| `voltage_group` | `400kV` or `<=220kV` |
| `connected_charging_mvar` | line charging connected at the bus (MVAr @ 1.0 pu) |
| `reactor_installed_mvar` | allocated installed reactor capacity (MVAr) |

On later runs the file is **read back as the model input** instead of being
recomputed — so the disaggregation is fixed and reproducible. **Delete
`Data/reactors.csv` to regenerate it** (e.g. after changing the line data or the
fleet totals in `data_preparation.jl`).

### Configuration
Controlled in `config.toml`:

```toml
[reactors]
enabled        = true     # attach the reactor shunts to the AC network
in_service_pct = 100.0    # percent of the installed fleet that is energised
```

`in_service_pct` is the single knob requested for studies: it scales every
bus's reactor before it is added to the network (`bs = -installed × pct/100 /
baseMVA`). `100` energises the full fleet, `0` disables it (equivalent to
`enabled = false`), and intermediate / >100 values let you sweep how much
compensation is in service — emulating switched reactors without turning the AC
OPF into a mixed-integer problem.

## Generator reactive capability (per fuel)

Reactive limits are technology-specific, enforced in every redispatch stage
(the anchored hour-by-hour solves and the Bellman-coupled multi-hour solve):

- **Synchronous units (Nuclear, Gas, Coal, Oil, Biomass, Hydro)** — apparent-power
  capability circle
  ```
  P_g² + Q_g² ≤ S_rated²,   S_rated = installed MVA / rated_power_factor
  ```
  `S_rated` is sized on **installed** nameplate MVA (a synchronous machine's MVA
  rating is fixed regardless of output, so it can supply reactive even at low MW).
  Convex (second-order cone) → Ipopt solves it as an NLP. This replaces the old
  `±Pmax` box that let a unit reach PF 0.707 at full output.

- **Inverter-based Wind / Solar** — a grid-code reactive cap tied to **actual**
  output:
  ```
  |Q_g| ≤ tan(acos(renewable_power_factor)) · P_g
  ```
  (linear). Sizing on actual P, not nameplate, prevents a heavily-derated farm
  (e.g. 38 MW out of 100 MW installed) from parking at a very low PF — which an
  installed-MVA circle would otherwise permit.

```toml
[generators]
apparent_power_limit   = true   # enforce the limits; false RELAXES to the ±Pmax box
rated_power_factor     = 0.90   # synchronous: S_rated = installed MVA / this
renewable_power_factor = 0.95   # wind/solar: |Q| ≤ tan(acos(this))·P
```

Set `apparent_power_limit = false` to drop all of these (revert to the `±Pmax`
box) if the full model becomes too hard to solve.

## Load reactive demand

Each load is given a reactive demand `qd = pd · tan(acos(power_factor))`, where
`power_factor` is the **net** power factor the transmission grid sees at the load
bus. Distribution-level PF correction (capacitor banks, large-consumer pf
requirements) is assumed already applied below the model boundary, so this is the
residual reactive the transmission network must carry.

```toml
[load]
power_factor = 1.0     # 1.0 ⇒ active-only load; 0.98 ⇒ small lagging draw; lower ⇒ more reactive
```

This interacts directly with the reactors: at `power_factor = 1.0` the loads draw
no reactive, leaving the full line charging for the **reactors** to absorb; at a
lower PF the load reactive (~11.5 GVAr at 0.95) soaks up much of the charging
itself, so less reactor capacity is needed. Tune `[load]` and `[reactors]`
together. (Reactive shunts must live in the network `shunt` dict — PowerModels
ignores bus-level `gs`/`bs`.)
