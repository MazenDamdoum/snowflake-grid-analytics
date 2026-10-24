/* =============================================================================
   07 - MARTS: dynamic tables + secure views

   SnowPro Core topics: dynamic tables (TARGET_LAG, DOWNSTREAM chaining,
   REFRESH_MODE), secure views (hide definition, block optimizer leaks),
   lateral column aliases, MAX_BY.
   Every view in MARTS is SECURE: GRID_VIEWER only ever sees secure views.
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE WAREHOUSE WH_TRANSFORM;
USE DATABASE GRID_DB;

-- =================================================== grid (real IESO data) ==
-- DOWNSTREAM: refresh only when a dependent dynamic table needs it
CREATE OR REPLACE DYNAMIC TABLE MARTS.FACT_GRID_HOURLY
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = WH_TRANSFORM
  COMMENT = 'Hourly Ontario demand, supply mix, interchange and day-ahead price'
AS
WITH fuel AS (
  SELECT delivery_date, delivery_hour,
         SUM(IFF(fuel = 'NUCLEAR', output_mwh, 0)) AS nuclear_mwh,
         SUM(IFF(fuel = 'HYDRO',   output_mwh, 0)) AS hydro_mwh,
         SUM(IFF(fuel = 'GAS',     output_mwh, 0)) AS gas_mwh,
         SUM(IFF(fuel = 'WIND',    output_mwh, 0)) AS wind_mwh,
         SUM(IFF(fuel = 'SOLAR',   output_mwh, 0)) AS solar_mwh,
         SUM(IFF(fuel = 'BIOFUEL', output_mwh, 0)) AS biofuel_mwh,
         SUM(output_mwh)                           AS total_gen_mwh,
         COUNT_IF(output_quality < 0)              AS telemetry_flags   -- IESO marks suspect telemetry < 0
  FROM STAGING.FUEL_HOURLY
  GROUP BY delivery_date, delivery_hour
), interchange AS (
  SELECT delivery_date, delivery_hour, flow_mw AS net_export_mw, import_mw, export_mw
  FROM STAGING.INTERTIE_HOURLY
  WHERE interface = 'TOTAL'
)
SELECT d.delivery_date, d.delivery_hour, d.interval_start_ts,
       DAYOFWEEKISO(d.delivery_date) AS iso_weekday,
       DATE_TRUNC('MONTH', d.delivery_date) AS month_start,
       d.ontario_demand_mw, d.market_demand_mw,
       f.nuclear_mwh, f.hydro_mwh, f.gas_mwh, f.wind_mwh, f.solar_mwh, f.biofuel_mwh, f.total_gen_mwh,
       f.telemetry_flags,
       ROUND(100 * (f.nuclear_mwh + f.hydro_mwh + f.wind_mwh + f.solar_mwh) / NULLIF(f.total_gen_mwh, 0), 2)
         AS non_emitting_pct,
       -- estimate: gas CCGT/peaker fleet ~0.40 tCO2e/MWh; t/MWh x 1000 = g/kWh
       ROUND(1000 * 0.40 * f.gas_mwh / NULLIF(f.total_gen_mwh, 0), 1) AS est_carbon_g_per_kwh,
       i.net_export_mw, i.import_mw, i.export_mw,
       p.zonal_price, p.loss_price, p.congestion_price
FROM STAGING.DEMAND_HOURLY d
LEFT JOIN fuel f              ON f.delivery_date = d.delivery_date AND f.delivery_hour = d.delivery_hour
LEFT JOIN interchange i       ON i.delivery_date = d.delivery_date AND i.delivery_hour = d.delivery_hour
LEFT JOIN STAGING.DA_PRICE_HOURLY p ON p.delivery_date = d.delivery_date AND p.delivery_hour = d.delivery_hour;

CREATE OR REPLACE DYNAMIC TABLE MARTS.FACT_GRID_DAILY
  TARGET_LAG = '12 hours'
  WAREHOUSE = WH_TRANSFORM
  COMMENT = 'Daily roll-up of FACT_GRID_HOURLY (drives its refresh)'
AS
SELECT delivery_date, month_start,
       MAX(ontario_demand_mw)                       AS peak_demand_mw,
       MAX_BY(delivery_hour, ontario_demand_mw)     AS peak_hour,
       ROUND(AVG(ontario_demand_mw), 0)             AS avg_demand_mw,
       SUM(ontario_demand_mw)                       AS demand_mwh,
       SUM(nuclear_mwh) AS nuclear_mwh, SUM(hydro_mwh) AS hydro_mwh, SUM(gas_mwh) AS gas_mwh,
       SUM(wind_mwh) AS wind_mwh, SUM(solar_mwh) AS solar_mwh, SUM(biofuel_mwh) AS biofuel_mwh,
       SUM(total_gen_mwh)                           AS total_gen_mwh,
       ROUND(AVG(non_emitting_pct), 2)              AS non_emitting_pct,
       ROUND(AVG(est_carbon_g_per_kwh), 1)          AS est_carbon_g_per_kwh,
       SUM(net_export_mw)                           AS net_export_mwh,
       ROUND(AVG(zonal_price), 2)                   AS avg_da_price,
       MIN(zonal_price)                             AS min_da_price,
       MAX(zonal_price)                             AS max_da_price,
       COUNT_IF(zonal_price < 0)                    AS negative_price_hours
FROM MARTS.FACT_GRID_HOURLY
GROUP BY delivery_date, month_start;

CREATE OR REPLACE DYNAMIC TABLE MARTS.FACT_GENERATOR_DAILY
  TARGET_LAG = '12 hours'
  WAREHOUSE = WH_TRANSFORM
  COMMENT = 'Per-generator daily energy, capacity factor and forecast error'
AS
SELECT delivery_date, generator, ANY_VALUE(fuel_type) AS fuel_type,
       SUM(output_mw)                                                        AS output_mwh,
       SUM(COALESCE(capability_mw, available_capacity_mw))                   AS available_mwh,
       ROUND(SUM(output_mw) / NULLIF(SUM(COALESCE(capability_mw, available_capacity_mw)), 0), 4) AS capacity_factor,
       MAX(COALESCE(capability_mw, available_capacity_mw))                   AS max_capability_mw,
       SUM(ABS(output_mw - forecast_mw))                                     AS abs_forecast_error_mwh
FROM STAGING.GEN_HOURLY
GROUP BY delivery_date, generator;

-- ============================================ distribution assets (synthetic) ==
CREATE OR REPLACE DYNAMIC TABLE MARTS.XFMR_LOADING_SUMMARY
  TARGET_LAG = '1 day'
  WAREHOUSE = WH_TRANSFORM
  COMMENT = 'Per-transformer loading statistics over the rolling 12 months'
AS
SELECT xfmr_id, feeder_id,
       ANY_VALUE(nameplate_kva)                   AS nameplate_kva,
       MAX(load_kva)                              AS peak_load_kva,
       MAX(loading_pct)                           AS peak_loading_pct,
       MAX_BY(interval_start_ts, loading_pct)     AS peak_at,
       ROUND(AVG(loading_pct), 2)                 AS avg_loading_pct,
       ROUND(AVG(load_kva) / NULLIF(MAX(load_kva), 0), 3) AS load_factor,
       COUNT_IF(loading_pct > 100)                AS hours_over_100,
       COUNT_IF(loading_pct > 120)                AS hours_over_120
FROM STAGING.XFMR_LOADING_HOURLY
GROUP BY xfmr_id, feeder_id;

-- Health index -> probability of failure, customers + critical loads ->
-- consequence, risk = PoF x CoF. FULL refresh: uses a Python UDF and
-- CURRENT_DATE() for asset age.
CREATE OR REPLACE DYNAMIC TABLE MARTS.ASSET_RISK
  TARGET_LAG = '1 day'
  WAREHOUSE = WH_TRANSFORM
  REFRESH_MODE = FULL
  COMMENT = 'Condition-based risk register for transformers and poles (ISO 55000 style)'
AS
WITH crit AS (
  SELECT xfmr_id, COUNT(*) AS critical_customers FROM STAGING.CRITICAL_CUSTOMERS GROUP BY xfmr_id
), xfmr AS (
  SELECT t.xfmr_id AS asset_id, 'TRANSFORMER' AS asset_type, t.region, t.feeder_id, t.substation_id,
         t.mount || ' ' || t.kva || ' kVA ' || t.phases || '-ph ' || t.load_class AS description,
         t.install_year, YEAR(CURRENT_DATE()) - t.install_year AS age_years, t.expected_life_years,
         l.peak_loading_pct, l.hours_over_100, i.condition_score, NULL::FLOAT AS remaining_strength_pct,
         t.customers_served, COALESCE(c.critical_customers, 0) AS critical_customers,
         -- indicative installed cost (CAD): pad-mount vs. pole-mount, scaled by kVA
         IFF(t.mount = 'PAD', 30000 + 85 * t.kva, 9000 + 90 * t.kva) AS replacement_cost_cad,
         t.latitude, t.longitude
  FROM STAGING.DIM_TRANSFORMER t
  LEFT JOIN MARTS.XFMR_LOADING_SUMMARY l ON l.xfmr_id = t.xfmr_id
  LEFT JOIN STAGING.LATEST_INSPECTION i  ON i.asset_id = t.xfmr_id
  LEFT JOIN crit c                       ON c.xfmr_id = t.xfmr_id
), pole AS (
  SELECT p.pole_id, 'POLE', p.region, p.feeder_id, p.substation_id,
         p.height_ft || ' ft class ' || p.pole_class || ' ' || p.species,
         p.install_year, YEAR(CURRENT_DATE()) - p.install_year, 50,
         NULL::FLOAT, NULL::FLOAT, i.condition_score, i.remaining_strength_pct,
         COALESCE(t.customers_served, 20),            -- span poles: assume ~20 downstream customers
         COALESCE(c.critical_customers, 0),
         7500 + 120 * p.height_ft + IFF(p.xfmr_id IS NOT NULL, 6000, 0),   -- + transformer transfer
         p.latitude, p.longitude
  FROM STAGING.DIM_POLE p
  LEFT JOIN STAGING.LATEST_INSPECTION i  ON i.asset_id = p.pole_id
  LEFT JOIN RAW.TRANSFORMERS t           ON t.xfmr_id = p.xfmr_id
  LEFT JOIN crit c                       ON c.xfmr_id = p.xfmr_id
), scored AS (
  SELECT a.*,
         APPS.ASSET_HEALTH_INDEX(asset_type, age_years, expected_life_years, peak_loading_pct,
                                 hours_over_100, condition_score, remaining_strength_pct) AS health_index
  FROM (SELECT * FROM xfmr UNION ALL SELECT * FROM pole) a
)
SELECT scored.*,
       ROUND(1 / (1 + EXP((health_index - 35) / 8)), 4)                 AS pof,       -- HI 35 -> 50 %
       ROUND(LN(1 + customers_served) * (1 + 2 * critical_customers), 3) AS cof,
       ROUND(pof * cof, 4)                                              AS risk_score,
       ROUND((pof - 0.02) * cof, 4)                                     AS risk_reduction,  -- new asset PoF ~2 %
       CASE WHEN health_index < 30 THEN '1 - VERY POOR'
            WHEN health_index < 50 THEN '2 - POOR'
            WHEN health_index < 70 THEN '3 - FAIR'
            WHEN health_index < 85 THEN '4 - GOOD'
            ELSE '5 - VERY GOOD' END                                    AS health_band
FROM scored;

-- IEEE 1366 indices per feeder and month (sustained, unplanned interruptions)
CREATE OR REPLACE DYNAMIC TABLE MARTS.FEEDER_RELIABILITY_MONTHLY
  TARGET_LAG = '1 day'
  WAREHOUSE = WH_TRANSFORM
  COMMENT = 'SAIFI / SAIDI / CAIDI by feeder and month'
AS
SELECT f.feeder_id, f.region, f.substation_name, f.construction, f.voltage_kv, f.customers,
       DATE_TRUNC('MONTH', o.start_ts)::DATE                         AS month_start,
       COUNT(*)                                                      AS interruptions,
       SUM(o.customers_interrupted)                                  AS customer_interruptions,
       SUM(o.customers_interrupted * o.duration_min)                 AS customer_minutes,
       ROUND(SUM(o.customers_interrupted) / f.customers, 4)          AS saifi,
       ROUND(SUM(o.customers_interrupted * o.duration_min) / f.customers, 2) AS saidi_min,
       ROUND(SUM(o.customers_interrupted * o.duration_min) / NULLIF(SUM(o.customers_interrupted), 0), 1) AS caidi_min
FROM STAGING.OUTAGE_EVENTS o
JOIN STAGING.DIM_FEEDER f ON f.feeder_id = o.feeder_id
WHERE NOT o.is_planned AND o.duration_min >= 1
GROUP BY ALL;

-- audit table written by APPS.SP_CAPITAL_PLAN
CREATE TABLE IF NOT EXISTS MARTS.CAPITAL_PLAN_RUNS (
  run_id VARCHAR, budget_cad FLOAT, run_at TIMESTAMP_LTZ,
  plan_rank NUMBER, asset_id VARCHAR, asset_type VARCHAR, region VARCHAR, feeder_id VARCHAR,
  health_index FLOAT, risk_score FLOAT, replacement_cost_cad FLOAT, risk_reduction FLOAT,
  cumulative_cost_cad FLOAT, selection_reason VARCHAR
);

-- ================================================================ secure views ==
CREATE OR REPLACE SECURE VIEW MARTS.V_GRID_HOURLY  AS SELECT * FROM MARTS.FACT_GRID_HOURLY;
CREATE OR REPLACE SECURE VIEW MARTS.V_GRID_DAILY   AS SELECT * FROM MARTS.FACT_GRID_DAILY;
CREATE OR REPLACE SECURE VIEW MARTS.V_GENERATOR_DAILY AS SELECT * FROM MARTS.FACT_GENERATOR_DAILY;
CREATE OR REPLACE SECURE VIEW MARTS.V_FEEDER_RELIABILITY AS SELECT * FROM MARTS.FEEDER_RELIABILITY_MONTHLY;

-- row access policy (region) is attached in 08_governance.sql
CREATE OR REPLACE SECURE VIEW MARTS.V_ASSET_RISK AS SELECT * FROM MARTS.ASSET_RISK;

CREATE OR REPLACE SECURE VIEW MARTS.V_TX_OUTAGES AS
SELECT *,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ BETWEEN planned_start AND planned_end AS is_active,
       DATEDIFF(HOUR, planned_start, planned_end)                              AS planned_hours
FROM STAGING.TX_OUTAGE_EQUIPMENT;

-- masking on name / phone comes from tags on the RAW columns (08_governance.sql)
CREATE OR REPLACE SECURE VIEW MARTS.V_CRITICAL_CUSTOMERS AS
SELECT c.customer_id, c.customer_name, c.facility_type, c.contact_phone, c.backup_generation,
       c.region, c.feeder_id, c.xfmr_id, r.health_index, r.health_band, r.risk_score
FROM STAGING.CRITICAL_CUSTOMERS c
LEFT JOIN MARTS.ASSET_RISK r ON r.asset_id = c.xfmr_id;

-- the future grants from 01 already cover new views / dynamic tables
SHOW GRANTS ON VIEW MARTS.V_ASSET_RISK;
SHOW DYNAMIC TABLES IN SCHEMA GRID_DB.MARTS;
