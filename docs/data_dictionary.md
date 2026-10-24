# Data dictionary

IESO times are **hour-ending (HE) 1-24 in Eastern Standard Time** all year, with no DST.
`interval_start_ts = delivery_date + (HE - 1) h`.

## Sources

| IESO report | Grain | Format | Lands in |
|---|---|---|---|
| `Demand` | hour | yearly CSV | `RAW.IESO_DEMAND_RAW` -> `STAGING.DEMAND_HOURLY` |
| `GenOutputbyFuelHourly` | hour x fuel | yearly XML | `RAW.IESO_FUEL_HOURLY_RAW` -> `STAGING.FUEL_HOURLY` |
| `GenOutputCapabilityMonth` | day x generator x measurement, 24 hour columns | monthly CSV | `RAW.IESO_GEN_CAPABILITY_RAW` -> `STAGING.GEN_HOURLY` |
| `IntertieScheduleFlowYear` | hour, (Imp, Exp, Flow) x intertie | yearly CSV | `RAW.IESO_INTERTIE_RAW` -> `STAGING.INTERTIE_HOURLY` |
| `DAHourlyOntarioZonalPrice` | hour | daily XML (~90-day retention) | `RAW.IESO_DA_PRICE_RAW` -> `STAGING.DA_PRICE_HOURLY` |
| `TxOutages1to30DaysPlanned` | outage request x equipment | daily XML snapshot | `RAW.IESO_TX_OUTAGES_RAW` -> `STAGING.TX_OUTAGE_EQUIPMENT` |

## STAGING

| Table | Key | Notable columns |
|---|---|---|
| `DEMAND_HOURLY` | date, hour | `ontario_demand_mw` (Ontario load), `market_demand_mw` (Ontario load + exports) |
| `FUEL_HOURLY` | date, hour, fuel | `output_mwh`; `output_quality` (IESO telemetry flag, 0 = good) |
| `GEN_HOURLY` | date, hour, generator | `output_mw`, `capability_mw` (dispatchable), `available_capacity_mw` and `forecast_mw` (wind / solar) |
| `INTERTIE_HOURLY` | date, hour, interface | `import_mw` / `export_mw` (scheduled), `flow_mw` (actual, + = export); `TOTAL` row |
| `DA_PRICE_HOURLY` | date, hour | `zonal_price` ($/MWh), `loss_price`, `congestion_price` |
| `TX_OUTAGE_EQUIPMENT` | outage_id, equipment_name | equipment type, `voltage_kv`, planned window, priority, status |
| `XFMR_LOADING_HOURLY` | xfmr, hour | `load_kva`, `nameplate_kva`, `loading_pct` (synthetic, built from the real demand shape) |
| `DIM_SUBSTATION`, `DIM_FEEDER`, `DIM_TRANSFORMER`, `DIM_POLE` | asset id | views over the RAW asset register, with region attached |
| `INSPECTIONS`, `INSPECTION_FINDINGS`, `LATEST_INSPECTION` | inspection / finding | JSON flattened: condition 1-5, resistograph strength %, thermal delta-T |
| `OUTAGE_EVENTS` | outage_id | `duration_min`, `customers_interrupted`, `cause`, `is_planned` |

## MARTS

| Object | Grain | Purpose |
|---|---|---|
| `FACT_GRID_HOURLY` (DT) | hour | Demand, fuel mix, IESO telemetry flags, non-emitting %, est. g CO2e/kWh, net interchange, DA price |
| `FACT_GRID_DAILY` (DT) | day | Peak, peak hour, energy by fuel, price min / avg / max, negative-price hours |
| `FACT_GENERATOR_DAILY` (DT) | day x generator | Output, available energy, capacity factor, forecast error |
| `XFMR_LOADING_SUMMARY` (DT) | transformer | Peak and average loading %, hours > 100% and > 120%, load factor |
| `ASSET_RISK` (DT, FULL) | asset | Health index, PoF, CoF, risk, risk reduction, replacement cost, health band |
| `FEEDER_RELIABILITY_MONTHLY` (DT) | feeder x month | SAIFI, SAIDI, CAIDI |
| `MV_DA_PRICE_DAILY` (MV) | day | Price statistics, hours priced |
| `CAPITAL_PLAN_RUNS` (table) | run x asset | Audit of every `SP_CAPITAL_PLAN` call |
| `V_*` (secure views) | | What viewers, Streamlit and the share read; RAP on `V_ASSET_RISK` and `V_CRITICAL_CUSTOMERS` |

## Synthetic asset register (`ingest/generate_assets.py`, seed 42)

| File | Rows (approx.) | Columns |
|---|---|---|
| `substations.csv` | 6 | id, name, region (NORTH / SOUTH / EAST), MVA, in-service year |
| `feeders.csv` | 36 | id, voltage (27.6 kV or legacy 4.16 kV), construction (OH / UG / URD), length, customers |
| `transformers.csv` | ~1,800 | kVA, phases, mount (POLE / PAD), install year, expected life, load class, customers, `connected_peak_kva` |
| `poles.csv` | ~3,100 | height, class, species, treatment, install year, carried transformer |
| `inspections.json` | ~5,900 | NDJSON: condition score, `findings[]`, `resistograph{}` or `thermal{}` |
| `outage_events.csv` | 450 | feeder / transformer, start, end, cause, planned flag, customers interrupted |
| `critical_customers.csv` | 15 | facility name (masked), type, phone (masked), backup generation |
