/* =============================================================================
   05 - STAGING layer: streams + task DAG (RAW -> STAGING)

   SnowPro Core topics: append-only streams and SHOW_INITIAL_ROWS, stream
   offsets advancing on DML, task DAGs (root -> children -> finalizer), WHEN
   SYSTEM$STREAM_HAS_DATA (skip runs and save credits when there is nothing new),
   MERGE upserts, semi-structured XML (XMLGET, LATERAL FLATTEN), UNPIVOT,
   QUALIFY.

   DAG (runs daily 08:30 America/Toronto, after IESO publishes):

     T_ROOT
       +-- T_MERGE_DEMAND --> T_BUILD_XFMR_LOADING
       +-- T_MERGE_FUEL
       +-- T_MERGE_GEN
       +-- T_MERGE_INTERTIE
       +-- T_MERGE_DA_PRICE
       +-- T_MERGE_TX_OUTAGES
     T_FINALIZE  (finalizer: always runs, writes an audit row)

   IESO time convention: hour-ending 1..24 in Eastern Standard Time all year
   (no DST). interval_start_ts = delivery_date + (hour - 1) hours, EST.
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE WAREHOUSE WH_TRANSFORM;
USE DATABASE GRID_DB;

-- tasks must be suspended before they can be replaced
ALTER TASK IF EXISTS STAGING.T_ROOT SUSPEND;

-- =============================================================== tables ====
CREATE TABLE IF NOT EXISTS STAGING.DEMAND_HOURLY (
  delivery_date      DATE        NOT NULL,
  delivery_hour      NUMBER(2)   NOT NULL,
  interval_start_ts  TIMESTAMP_NTZ,
  market_demand_mw   NUMBER(8),
  ontario_demand_mw  NUMBER(8),
  _source_file       VARCHAR,
  _updated_at        TIMESTAMP_LTZ,
  CONSTRAINT pk_demand PRIMARY KEY (delivery_date, delivery_hour)  -- informational only
);

CREATE TABLE IF NOT EXISTS STAGING.FUEL_HOURLY (
  delivery_date   DATE NOT NULL,
  delivery_hour   NUMBER(2) NOT NULL,
  fuel            VARCHAR NOT NULL,
  output_mwh      NUMBER(10,2),
  output_quality  NUMBER(3),                 -- IESO telemetry quality flag (0 = good)
  _updated_at     TIMESTAMP_LTZ,
  CONSTRAINT pk_fuel PRIMARY KEY (delivery_date, delivery_hour, fuel)
);

CREATE TABLE IF NOT EXISTS STAGING.GEN_HOURLY (
  delivery_date          DATE NOT NULL,
  delivery_hour          NUMBER(2) NOT NULL,
  generator              VARCHAR NOT NULL,
  fuel_type              VARCHAR,
  output_mw              NUMBER(10,2),
  capability_mw          NUMBER(10,2),       -- dispatchable units
  available_capacity_mw  NUMBER(10,2),       -- variable generation (wind / solar)
  forecast_mw            NUMBER(10,2),
  _updated_at            TIMESTAMP_LTZ,
  CONSTRAINT pk_gen PRIMARY KEY (delivery_date, delivery_hour, generator)
);

CREATE TABLE IF NOT EXISTS STAGING.INTERTIE_HOURLY (
  delivery_date  DATE NOT NULL,
  delivery_hour  NUMBER(2) NOT NULL,
  interface      VARCHAR NOT NULL,
  import_mw      NUMBER(10,2),
  export_mw      NUMBER(10,2),
  flow_mw        NUMBER(10,2),               -- actual flow, + = export from Ontario
  _updated_at    TIMESTAMP_LTZ,
  CONSTRAINT pk_intertie PRIMARY KEY (delivery_date, delivery_hour, interface)
);

CREATE TABLE IF NOT EXISTS STAGING.DA_PRICE_HOURLY (
  delivery_date     DATE NOT NULL,
  delivery_hour     NUMBER(2) NOT NULL,
  zonal_price       NUMBER(10,2),            -- $/MWh, Ontario Zonal Price (day-ahead)
  loss_price        NUMBER(10,2),
  congestion_price  NUMBER(10,2),
  flag              VARCHAR,
  _updated_at       TIMESTAMP_LTZ,
  CONSTRAINT pk_da_price PRIMARY KEY (delivery_date, delivery_hour)
);

CREATE TABLE IF NOT EXISTS STAGING.TX_OUTAGE_EQUIPMENT (
  outage_id         VARCHAR NOT NULL,
  equipment_name    VARCHAR NOT NULL,
  equipment_type    VARCHAR,
  voltage_kv        NUMBER(6,1),
  constraint_type   VARCHAR,
  planned_start     TIMESTAMP_NTZ,
  planned_end       TIMESTAMP_NTZ,
  priority          VARCHAR,
  recurrence        VARCHAR,
  request_status    VARCHAR,
  recall_time       VARCHAR,
  snapshot_date     DATE,                    -- which daily report last listed it
  _updated_at       TIMESTAMP_LTZ,
  CONSTRAINT pk_tx_outage PRIMARY KEY (outage_id, equipment_name)
);

-- ~1,800 transformers x 8,760 h ~= 16M rows; rebuilt by T_BUILD_XFMR_LOADING
CREATE TABLE IF NOT EXISTS STAGING.XFMR_LOADING_HOURLY (
  xfmr_id            VARCHAR,
  feeder_id          VARCHAR,
  interval_start_ts  TIMESTAMP_NTZ,
  delivery_date      DATE,
  delivery_hour      NUMBER(2),
  load_kva           NUMBER(10,2),
  nameplate_kva      NUMBER(10,2),
  loading_pct        NUMBER(6,2)
);

CREATE TABLE IF NOT EXISTS GOVERNANCE.PIPELINE_RUN_LOG (
  run_at              TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  root_task_run_id    VARCHAR,
  demand_rows         NUMBER,
  fuel_rows           NUMBER,
  gen_rows            NUMBER,
  da_price_rows       NUMBER,
  latest_demand_date  DATE,
  latest_price_date   DATE
);

-- ======================================================== asset views ====
-- Asset master data is full-refresh, so plain views are enough here.
CREATE OR REPLACE VIEW STAGING.DIM_SUBSTATION AS SELECT * FROM RAW.SUBSTATIONS;

CREATE OR REPLACE VIEW STAGING.DIM_FEEDER AS
SELECT f.*, s.substation_name
FROM RAW.FEEDERS f JOIN RAW.SUBSTATIONS s USING (substation_id);

CREATE OR REPLACE VIEW STAGING.DIM_TRANSFORMER AS
SELECT t.*, f.region, f.substation_id, f.construction
FROM RAW.TRANSFORMERS t JOIN RAW.FEEDERS f USING (feeder_id);

CREATE OR REPLACE VIEW STAGING.DIM_POLE AS
SELECT p.*, f.region, f.substation_id
FROM RAW.POLES p JOIN RAW.FEEDERS f USING (feeder_id);

CREATE OR REPLACE VIEW STAGING.OUTAGE_EVENTS AS
SELECT o.*, DATEDIFF(MINUTE, o.start_ts, o.end_ts) AS duration_min, f.region
FROM RAW.OUTAGE_EVENTS o JOIN RAW.FEEDERS f USING (feeder_id);

CREATE OR REPLACE VIEW STAGING.CRITICAL_CUSTOMERS AS SELECT * FROM RAW.CRITICAL_CUSTOMERS;

-- JSON -> relational: dot / colon paths + cast, nested arrays via FLATTEN
CREATE OR REPLACE VIEW STAGING.INSPECTIONS AS
SELECT
  record:inspection_id::VARCHAR                              AS inspection_id,
  record:asset_id::VARCHAR                                   AS asset_id,
  record:asset_type::VARCHAR                                 AS asset_type,
  record:inspected_at::DATE                                  AS inspected_at,
  record:inspector::VARCHAR                                  AS inspector,
  record:condition_score::NUMBER                             AS condition_score,
  ARRAY_SIZE(record:findings)                                AS finding_count,
  record:resistograph.remaining_strength_pct::FLOAT          AS remaining_strength_pct,
  record:thermal.hotspot_delta_c::FLOAT                      AS hotspot_delta_c,
  record                                                     AS raw_record
FROM RAW.INSPECTIONS_RAW;

CREATE OR REPLACE VIEW STAGING.INSPECTION_FINDINGS AS
SELECT
  i.record:inspection_id::VARCHAR AS inspection_id,
  i.record:asset_id::VARCHAR      AS asset_id,
  f.value:code::VARCHAR           AS finding_code,
  f.value:severity::VARCHAR       AS severity
FROM RAW.INSPECTIONS_RAW i,
     LATERAL FLATTEN(input => i.record:findings) f;

-- latest inspection per asset
CREATE OR REPLACE VIEW STAGING.LATEST_INSPECTION AS
SELECT *
FROM STAGING.INSPECTIONS
QUALIFY ROW_NUMBER() OVER (PARTITION BY asset_id ORDER BY inspected_at DESC, inspection_id DESC) = 1;

-- ============================================================== streams ====
-- APPEND_ONLY: RAW only ever receives inserts, which is cheaper to track.
-- SHOW_INITIAL_ROWS: the first consumption also returns rows that were loaded
-- before the stream existed (otherwise the initial COPY would be missed).
CREATE STREAM IF NOT EXISTS RAW.S_DEMAND     ON TABLE RAW.IESO_DEMAND_RAW         APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE;
CREATE STREAM IF NOT EXISTS RAW.S_GEN        ON TABLE RAW.IESO_GEN_CAPABILITY_RAW APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE;
CREATE STREAM IF NOT EXISTS RAW.S_INTERTIE   ON TABLE RAW.IESO_INTERTIE_RAW       APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE;
CREATE STREAM IF NOT EXISTS RAW.S_FUEL       ON TABLE RAW.IESO_FUEL_HOURLY_RAW    APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE;
CREATE STREAM IF NOT EXISTS RAW.S_DA_PRICE   ON TABLE RAW.IESO_DA_PRICE_RAW       APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE;
CREATE STREAM IF NOT EXISTS RAW.S_TX_OUTAGES ON TABLE RAW.IESO_TX_OUTAGES_RAW     APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE;

-- ================================================================ tasks ====
CREATE OR REPLACE TASK STAGING.T_ROOT
  WAREHOUSE = WH_TRANSFORM
  SCHEDULE = 'USING CRON 30 8 * * * America/Toronto'
  COMMENT = 'Daily IESO refresh: root of the RAW -> STAGING DAG'
AS
  SELECT 'grid pipeline start';

-- ---------------------------------------------------------------- demand --
CREATE OR REPLACE TASK STAGING.T_MERGE_DEMAND
  WAREHOUSE = WH_TRANSFORM
  AFTER STAGING.T_ROOT
  WHEN SYSTEM$STREAM_HAS_DATA('GRID_DB.RAW.S_DEMAND')
AS
MERGE INTO STAGING.DEMAND_HOURLY t
USING (
  SELECT delivery_date, delivery_hour,
         DATEADD(HOUR, delivery_hour - 1, delivery_date::TIMESTAMP_NTZ) AS interval_start_ts,
         market_demand_mw, ontario_demand_mw, _source_file
  FROM (
    SELECT TRY_TO_DATE(delivery_date)        AS delivery_date,
           TRY_TO_NUMBER(delivery_hour)      AS delivery_hour,
           TRY_TO_NUMBER(market_demand_mw)   AS market_demand_mw,
           TRY_TO_NUMBER(ontario_demand_mw)  AS ontario_demand_mw,
           _source_file, _loaded_at
    FROM RAW.S_DEMAND
  )
  WHERE delivery_date IS NOT NULL AND delivery_hour BETWEEN 1 AND 24
  QUALIFY ROW_NUMBER() OVER (PARTITION BY delivery_date, delivery_hour ORDER BY _loaded_at DESC) = 1
) s
ON t.delivery_date = s.delivery_date AND t.delivery_hour = s.delivery_hour
WHEN MATCHED THEN UPDATE SET
  market_demand_mw = s.market_demand_mw, ontario_demand_mw = s.ontario_demand_mw,
  _source_file = s._source_file, _updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (delivery_date, delivery_hour, interval_start_ts, market_demand_mw, ontario_demand_mw, _source_file, _updated_at)
  VALUES (s.delivery_date, s.delivery_hour, s.interval_start_ts, s.market_demand_mw, s.ontario_demand_mw,
          s._source_file, CURRENT_TIMESTAMP());

-- ------------------------------------------------- fuel mix (nested XML) --
-- DocBody > DailyData* > HourlyData* > FuelTotal* > {Fuel, EnergyValue > Output}
-- In the Snowflake XML VARIANT, "@" is the element name and "$" its content.
CREATE OR REPLACE TASK STAGING.T_MERGE_FUEL
  WAREHOUSE = WH_TRANSFORM
  AFTER STAGING.T_ROOT
  WHEN SYSTEM$STREAM_HAS_DATA('GRID_DB.RAW.S_FUEL')
AS
MERGE INTO STAGING.FUEL_HOURLY t
USING (
  WITH body AS (
    SELECT doc, _loaded_at FROM RAW.S_FUEL WHERE doc:"@"::VARCHAR = 'DocBody'
  ), days AS (
    SELECT b._loaded_at, d.value AS day_node
    FROM body b, LATERAL FLATTEN(input => b.doc:"$") d
    WHERE d.value:"@"::VARCHAR = 'DailyData'
  ), hours AS (
    SELECT d._loaded_at, XMLGET(d.day_node, 'Day'):"$"::DATE AS delivery_date, h.value AS hour_node
    FROM days d, LATERAL FLATTEN(input => d.day_node:"$") h
    WHERE h.value:"@"::VARCHAR = 'HourlyData'
  ), fuels AS (
    SELECT h._loaded_at, h.delivery_date,
           XMLGET(h.hour_node, 'Hour'):"$"::NUMBER AS delivery_hour,
           f.value AS fuel_node
    FROM hours h, LATERAL FLATTEN(input => h.hour_node:"$") f
    WHERE f.value:"@"::VARCHAR = 'FuelTotal'
  )
  SELECT delivery_date, delivery_hour,
         XMLGET(fuel_node, 'Fuel'):"$"::VARCHAR                                  AS fuel,
         TRY_TO_DECIMAL(XMLGET(XMLGET(fuel_node, 'EnergyValue'), 'Output'):"$"::VARCHAR, 10, 2) AS output_mwh,
         TRY_TO_NUMBER(XMLGET(XMLGET(fuel_node, 'EnergyValue'), 'OutputQuality'):"$"::VARCHAR) AS output_quality
  FROM fuels
  QUALIFY ROW_NUMBER() OVER (PARTITION BY delivery_date, delivery_hour, fuel ORDER BY _loaded_at DESC) = 1
) s
ON t.delivery_date = s.delivery_date AND t.delivery_hour = s.delivery_hour AND t.fuel = s.fuel
WHEN MATCHED THEN UPDATE SET
  output_mwh = s.output_mwh, output_quality = s.output_quality, _updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (delivery_date, delivery_hour, fuel, output_mwh, output_quality, _updated_at)
  VALUES (s.delivery_date, s.delivery_hour, s.fuel, s.output_mwh, s.output_quality, CURRENT_TIMESTAMP());

-- ------------------------------------- per-generator (UNPIVOT + pivot back) --
-- Source rows: one per (day, generator, measurement) with 24 hour columns.
-- UNPIVOT -> one row per hour, then conditional aggregation puts each
-- measurement (Output / Capability / Available Capacity / Forecast) in a column.
CREATE OR REPLACE TASK STAGING.T_MERGE_GEN
  WAREHOUSE = WH_TRANSFORM
  AFTER STAGING.T_ROOT
  WHEN SYSTEM$STREAM_HAS_DATA('GRID_DB.RAW.S_GEN')
AS
MERGE INTO STAGING.GEN_HOURLY t
USING (
  WITH latest AS (
    SELECT * FROM RAW.S_GEN
    WHERE TRY_TO_DATE(delivery_date) IS NOT NULL AND generator IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY delivery_date, generator, measurement ORDER BY _loaded_at DESC) = 1
  ), hourly AS (
    SELECT TRY_TO_DATE(delivery_date) AS delivery_date, generator, fuel_type, measurement,
           TO_NUMBER(SUBSTR(hour_col, 2)) AS delivery_hour,
           TRY_TO_DECIMAL(mw, 10, 2) AS mw
    FROM latest
      UNPIVOT (mw FOR hour_col IN (h01, h02, h03, h04, h05, h06, h07, h08, h09, h10, h11, h12,
                                   h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24))
  )
  SELECT delivery_date, delivery_hour, generator,
         ANY_VALUE(fuel_type)                                        AS fuel_type,
         MAX(IFF(measurement = 'Output', mw, NULL))                  AS output_mw,
         MAX(IFF(measurement = 'Capability', mw, NULL))              AS capability_mw,
         MAX(IFF(measurement = 'Available Capacity', mw, NULL))      AS available_capacity_mw,
         MAX(IFF(measurement = 'Forecast', mw, NULL))                AS forecast_mw
  FROM hourly
  GROUP BY delivery_date, delivery_hour, generator
) s
ON t.delivery_date = s.delivery_date AND t.delivery_hour = s.delivery_hour AND t.generator = s.generator
WHEN MATCHED THEN UPDATE SET
  fuel_type = s.fuel_type, output_mw = s.output_mw, capability_mw = s.capability_mw,
  available_capacity_mw = s.available_capacity_mw, forecast_mw = s.forecast_mw, _updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (delivery_date, delivery_hour, generator, fuel_type, output_mw, capability_mw, available_capacity_mw, forecast_mw, _updated_at)
  VALUES (s.delivery_date, s.delivery_hour, s.generator, s.fuel_type, s.output_mw, s.capability_mw,
          s.available_capacity_mw, s.forecast_mw, CURRENT_TIMESTAMP());

-- ------------------------------------------------- interties (SPLIT line) --
-- Columns after date,hour come in (Imp, Exp, Flow) triplets per interface, in
-- the order of the first header row of the report.
CREATE OR REPLACE TASK STAGING.T_MERGE_INTERTIE
  WAREHOUSE = WH_TRANSFORM
  AFTER STAGING.T_ROOT
  WHEN SYSTEM$STREAM_HAS_DATA('GRID_DB.RAW.S_INTERTIE')
AS
MERGE INTO STAGING.INTERTIE_HOURLY t
USING (
  WITH parsed AS (
    SELECT SPLIT(line, ',') AS cols, _loaded_at FROM RAW.S_INTERTIE
  ), rows_ AS (
    SELECT TRY_TO_DATE(cols[0]::VARCHAR) AS delivery_date, TRY_TO_NUMBER(cols[1]::VARCHAR) AS delivery_hour,
           ARRAY_SLICE(cols, 2, ARRAY_SIZE(cols)) AS vals, _loaded_at
    FROM parsed
    WHERE TRY_TO_DATE(cols[0]::VARCHAR) IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY delivery_date, delivery_hour ORDER BY _loaded_at DESC) = 1
  ), interfaces AS (
    SELECT ARRAY_CONSTRUCT('MANITOBA', 'MANITOBA SK', 'MICHIGAN', 'MINNESOTA', 'NEW-YORK',
                           'PQ.AT', 'PQ.B5D.B31L', 'PQ.D4Z', 'PQ.D5A', 'PQ.H4Z', 'PQ.H9A',
                           'PQ.P33C', 'PQ.Q4C', 'PQ.X2Y', 'TOTAL') AS names
  ), cells AS (
    SELECT r.delivery_date, r.delivery_hour,
           FLOOR(v.index / 3) AS iface_idx, MOD(v.index, 3) AS measure_idx,
           TRY_TO_DECIMAL(v.value::VARCHAR, 10, 2) AS mw
    FROM rows_ r, LATERAL FLATTEN(input => r.vals) v
  )
  SELECT c.delivery_date, c.delivery_hour, GET(i.names, c.iface_idx)::VARCHAR AS interface,
         MAX(IFF(measure_idx = 0, mw, NULL)) AS import_mw,
         MAX(IFF(measure_idx = 1, mw, NULL)) AS export_mw,
         MAX(IFF(measure_idx = 2, mw, NULL)) AS flow_mw
  FROM cells c CROSS JOIN interfaces i
  WHERE c.iface_idx < ARRAY_SIZE(i.names)
  GROUP BY 1, 2, 3
) s
ON t.delivery_date = s.delivery_date AND t.delivery_hour = s.delivery_hour AND t.interface = s.interface
WHEN MATCHED THEN UPDATE SET
  import_mw = s.import_mw, export_mw = s.export_mw, flow_mw = s.flow_mw, _updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (delivery_date, delivery_hour, interface, import_mw, export_mw, flow_mw, _updated_at)
  VALUES (s.delivery_date, s.delivery_hour, s.interface, s.import_mw, s.export_mw, s.flow_mw, CURRENT_TIMESTAMP());

-- ------------------------------------------- day-ahead zonal price (XML) --
CREATE OR REPLACE TASK STAGING.T_MERGE_DA_PRICE
  WAREHOUSE = WH_TRANSFORM
  AFTER STAGING.T_ROOT
  WHEN SYSTEM$STREAM_HAS_DATA('GRID_DB.RAW.S_DA_PRICE')
AS
MERGE INTO STAGING.DA_PRICE_HOURLY t
USING (
  WITH body AS (
    SELECT doc, _loaded_at, XMLGET(doc, 'DeliveryDate'):"$"::DATE AS delivery_date
    FROM RAW.S_DA_PRICE WHERE doc:"@"::VARCHAR = 'DocBody'
  )
  SELECT b.delivery_date,
         XMLGET(p.value, 'PricingHour'):"$"::NUMBER                AS delivery_hour,
         TRY_TO_DECIMAL(XMLGET(p.value, 'ZonalPrice'):"$"::VARCHAR, 10, 2)            AS zonal_price,
         TRY_TO_DECIMAL(XMLGET(p.value, 'LossPriceCapped'):"$"::VARCHAR, 10, 2)       AS loss_price,
         TRY_TO_DECIMAL(XMLGET(p.value, 'CongestionPriceCapped'):"$"::VARCHAR, 10, 2) AS congestion_price,
         XMLGET(p.value, 'Flag'):"$"::VARCHAR                      AS flag
  FROM body b, LATERAL FLATTEN(input => b.doc:"$") p
  WHERE p.value:"@"::VARCHAR = 'HourlyPriceComponents'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY b.delivery_date, delivery_hour ORDER BY b._loaded_at DESC) = 1
) s
ON t.delivery_date = s.delivery_date AND t.delivery_hour = s.delivery_hour
WHEN MATCHED THEN UPDATE SET
  zonal_price = s.zonal_price, loss_price = s.loss_price, congestion_price = s.congestion_price,
  flag = s.flag, _updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (delivery_date, delivery_hour, zonal_price, loss_price, congestion_price, flag, _updated_at)
  VALUES (s.delivery_date, s.delivery_hour, s.zonal_price, s.loss_price, s.congestion_price, s.flag, CURRENT_TIMESTAMP());

-- ------------------------------------ planned transmission outages (XML) --
-- DocBody > OutageRequest* > {OutageID, PlannedStart, ..., EquipmentRequested*}
CREATE OR REPLACE TASK STAGING.T_MERGE_TX_OUTAGES
  WAREHOUSE = WH_TRANSFORM
  AFTER STAGING.T_ROOT
  WHEN SYSTEM$STREAM_HAS_DATA('GRID_DB.RAW.S_TX_OUTAGES')
AS
MERGE INTO STAGING.TX_OUTAGE_EQUIPMENT t
USING (
  WITH body AS (
    SELECT doc, _loaded_at,
           TRY_TO_DATE(REGEXP_SUBSTR(_source_file, '_([0-9]{8})[.]xml', 1, 1, 'e', 1), 'YYYYMMDD') AS snapshot_date
    FROM RAW.S_TX_OUTAGES WHERE doc:"@"::VARCHAR = 'DocBody'
  ), requests AS (
    SELECT b.snapshot_date, b._loaded_at, r.value AS req
    FROM body b, LATERAL FLATTEN(input => b.doc:"$") r
    WHERE r.value:"@"::VARCHAR = 'OutageRequest'
  ), equipment AS (
    SELECT q.*, e.value AS eq
    FROM requests q, LATERAL FLATTEN(input => q.req:"$") e
    WHERE e.value:"@"::VARCHAR = 'EquipmentRequested'
  )
  SELECT XMLGET(req, 'OutageID'):"$"::VARCHAR                                   AS outage_id,
         XMLGET(eq, 'EquipmentName'):"$"::VARCHAR                               AS equipment_name,
         XMLGET(eq, 'EquipmentType'):"$"::VARCHAR                               AS equipment_type,
         TRY_TO_DECIMAL(REGEXP_SUBSTR(XMLGET(eq, 'EquipmentVoltage'):"$"::VARCHAR, '[0-9.]+'), 6, 1) AS voltage_kv,
         XMLGET(eq, 'ConstraintType'):"$"::VARCHAR                              AS constraint_type,
         TRY_TO_TIMESTAMP_NTZ(XMLGET(req, 'PlannedStart'):"$"::VARCHAR)          AS planned_start,
         TRY_TO_TIMESTAMP_NTZ(XMLGET(req, 'PlannedEnd'):"$"::VARCHAR)            AS planned_end,
         XMLGET(req, 'Priority'):"$"::VARCHAR                                   AS priority,
         XMLGET(req, 'Recurrence'):"$"::VARCHAR                                 AS recurrence,
         XMLGET(req, 'OutageRequestStatus'):"$"::VARCHAR                        AS request_status,
         XMLGET(req, 'EquipmentRecallTime'):"$"::VARCHAR                        AS recall_time,
         snapshot_date
  FROM equipment
  QUALIFY ROW_NUMBER() OVER (PARTITION BY outage_id, equipment_name ORDER BY snapshot_date DESC, _loaded_at DESC) = 1
) s
ON t.outage_id = s.outage_id AND t.equipment_name = s.equipment_name
WHEN MATCHED THEN UPDATE SET
  equipment_type = s.equipment_type, voltage_kv = s.voltage_kv, constraint_type = s.constraint_type,
  planned_start = s.planned_start, planned_end = s.planned_end, priority = s.priority,
  recurrence = s.recurrence, request_status = s.request_status, recall_time = s.recall_time,
  snapshot_date = s.snapshot_date, _updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (outage_id, equipment_name, equipment_type, voltage_kv, constraint_type, planned_start, planned_end,
   priority, recurrence, request_status, recall_time, snapshot_date, _updated_at)
  VALUES (s.outage_id, s.equipment_name, s.equipment_type, s.voltage_kv, s.constraint_type, s.planned_start,
          s.planned_end, s.priority, s.recurrence, s.request_status, s.recall_time, s.snapshot_date,
          CURRENT_TIMESTAMP());

-- ------------------------------------- synthetic AMI transformer loading --
-- Hourly load per transformer = its connected peak kVA x the REAL Ontario
-- demand shape (per-unit of the window peak) x a load-class time-of-day factor
-- x deterministic noise. HASH() keeps the noise reproducible across rebuilds.
CREATE OR REPLACE TASK STAGING.T_BUILD_XFMR_LOADING
  WAREHOUSE = WH_TRANSFORM
  AFTER STAGING.T_MERGE_DEMAND
AS
INSERT OVERWRITE INTO STAGING.XFMR_LOADING_HOURLY
WITH shape AS (
  SELECT delivery_date, delivery_hour, interval_start_ts,
         ontario_demand_mw / MAX(ontario_demand_mw) OVER () AS demand_pu
  FROM STAGING.DEMAND_HOURLY
  WHERE delivery_date > DATEADD(MONTH, -12, CURRENT_DATE())
), modeled AS (
  SELECT x.xfmr_id, x.feeder_id, s.interval_start_ts, s.delivery_date, s.delivery_hour, x.kva AS nameplate_kva,
         x.connected_peak_kva
           * s.demand_pu
           * CASE x.load_class
               WHEN 'RESIDENTIAL' THEN 1 + 0.12 * COS(2 * PI() * (s.delivery_hour - 19) / 24)  -- evening peak
               WHEN 'COMMERCIAL'  THEN 1 + 0.12 * COS(2 * PI() * (s.delivery_hour - 14) / 24)  -- afternoon peak
               ELSE 1.0                                                                       -- flat industrial
             END
           * (0.88 + 0.24 * MOD(ABS(HASH(x.xfmr_id, s.interval_start_ts)), 1000) / 1000)
           AS load_kva
  FROM STAGING.DIM_TRANSFORMER x
  CROSS JOIN shape s
)
SELECT xfmr_id, feeder_id, interval_start_ts, delivery_date, delivery_hour,
       ROUND(load_kva, 2), nameplate_kva, ROUND(100 * load_kva / NULLIF(nameplate_kva, 0), 2)
FROM modeled
ORDER BY delivery_date, feeder_id;   -- natural clustering for date-range pruning

-- -------------------------------------------------------------- finalizer --
-- Runs after every DAG run, even when children fail or are skipped.
CREATE OR REPLACE TASK STAGING.T_FINALIZE
  WAREHOUSE = WH_TRANSFORM
  FINALIZE = STAGING.T_ROOT
AS
INSERT INTO GOVERNANCE.PIPELINE_RUN_LOG
  (root_task_run_id, demand_rows, fuel_rows, gen_rows, da_price_rows, latest_demand_date, latest_price_date)
SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'),
       (SELECT COUNT(*) FROM STAGING.DEMAND_HOURLY),
       (SELECT COUNT(*) FROM STAGING.FUEL_HOURLY),
       (SELECT COUNT(*) FROM STAGING.GEN_HOURLY),
       (SELECT COUNT(*) FROM STAGING.DA_PRICE_HOURLY),
       (SELECT MAX(delivery_date) FROM STAGING.DEMAND_HOURLY),
       (SELECT MAX(delivery_date) FROM STAGING.DA_PRICE_HOURLY);

-- resume the root and every dependent (children + finalizer) in one call
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('GRID_DB.STAGING.T_ROOT');

-- run it now instead of waiting for the schedule:
--   EXECUTE TASK GRID_DB.STAGING.T_ROOT;
-- then watch it:
--   SELECT name, state, scheduled_time, completed_time, error_message
--   FROM TABLE(GRID_DB.INFORMATION_SCHEMA.TASK_HISTORY(RESULT_LIMIT => 50)) ORDER BY scheduled_time DESC;
