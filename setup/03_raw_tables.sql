/* =============================================================================
   03 - RAW landing tables

   Convention: RAW keeps files as delivered. CSV columns are VARCHAR so a bad
   value never fails a load (typing happens in STAGING with TRY_TO_*), XML/JSON
   lands as VARIANT, and every row records the file it came from.
   Tables inherit TRANSIENT from the schema.
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE SCHEMA GRID_DB.RAW;

-- ---------- IESO (incremental: appended by COPY, consumed by streams) ----------
CREATE TABLE IF NOT EXISTS IESO_DEMAND_RAW (
  delivery_date      VARCHAR,
  delivery_hour      VARCHAR,
  market_demand_mw   VARCHAR,
  ontario_demand_mw  VARCHAR,
  _source_file       VARCHAR,
  _source_row        NUMBER,
  _loaded_at         TIMESTAMP_LTZ
);

CREATE TABLE IF NOT EXISTS IESO_GEN_CAPABILITY_RAW (
  delivery_date VARCHAR, generator VARCHAR, fuel_type VARCHAR, measurement VARCHAR,
  h01 VARCHAR, h02 VARCHAR, h03 VARCHAR, h04 VARCHAR, h05 VARCHAR, h06 VARCHAR,
  h07 VARCHAR, h08 VARCHAR, h09 VARCHAR, h10 VARCHAR, h11 VARCHAR, h12 VARCHAR,
  h13 VARCHAR, h14 VARCHAR, h15 VARCHAR, h16 VARCHAR, h17 VARCHAR, h18 VARCHAR,
  h19 VARCHAR, h20 VARCHAR, h21 VARCHAR, h22 VARCHAR, h23 VARCHAR, h24 VARCHAR,
  _source_file VARCHAR,
  _source_row  NUMBER,
  _loaded_at   TIMESTAMP_LTZ
);

CREATE TABLE IF NOT EXISTS IESO_INTERTIE_RAW (
  line          VARCHAR,          -- "date,hour,imp,exp,flow,imp,exp,flow,..."
  _source_file  VARCHAR,
  _source_row   NUMBER,
  _loaded_at    TIMESTAMP_LTZ
);

CREATE TABLE IF NOT EXISTS IESO_FUEL_HOURLY_RAW (
  doc           VARIANT,          -- DocHeader or DocBody element
  _source_file  VARCHAR,
  _loaded_at    TIMESTAMP_LTZ
);

CREATE TABLE IF NOT EXISTS IESO_DA_PRICE_RAW (
  doc           VARIANT,
  _source_file  VARCHAR,
  _loaded_at    TIMESTAMP_LTZ
);

CREATE TABLE IF NOT EXISTS IESO_TX_OUTAGES_RAW (
  doc           VARIANT,
  _source_file  VARCHAR,
  _loaded_at    TIMESTAMP_LTZ
);

-- ---------- synthetic asset register (full refresh: TRUNCATE + COPY) ----------
CREATE TABLE IF NOT EXISTS SUBSTATIONS (
  substation_id VARCHAR, substation_name VARCHAR, region VARCHAR,
  latitude FLOAT, longitude FLOAT, transformer_mva FLOAT, in_service_year NUMBER
);

CREATE TABLE IF NOT EXISTS FEEDERS (
  feeder_id VARCHAR, substation_id VARCHAR, region VARCHAR, voltage_kv FLOAT,
  construction VARCHAR, length_km FLOAT, customers NUMBER
);

CREATE TABLE IF NOT EXISTS TRANSFORMERS (
  xfmr_id VARCHAR, feeder_id VARCHAR, mount VARCHAR, kva FLOAT, phases NUMBER,
  primary_kv FLOAT, secondary_v NUMBER, manufacturer VARCHAR, install_year NUMBER,
  expected_life_years NUMBER, load_class VARCHAR, customers_served NUMBER,
  connected_peak_kva FLOAT, latitude FLOAT, longitude FLOAT
);

CREATE TABLE IF NOT EXISTS POLES (
  pole_id VARCHAR, feeder_id VARCHAR, xfmr_id VARCHAR, height_ft NUMBER, pole_class NUMBER,
  species VARCHAR, treatment VARCHAR, install_year NUMBER, latitude FLOAT, longitude FLOAT
);

CREATE TABLE IF NOT EXISTS OUTAGE_EVENTS (
  outage_id VARCHAR, feeder_id VARCHAR, xfmr_id VARCHAR, start_ts TIMESTAMP_NTZ,
  end_ts TIMESTAMP_NTZ, cause VARCHAR, is_planned BOOLEAN, customers_interrupted NUMBER
);

CREATE TABLE IF NOT EXISTS CRITICAL_CUSTOMERS (
  customer_id VARCHAR, customer_name VARCHAR, facility_type VARCHAR, xfmr_id VARCHAR,
  feeder_id VARCHAR, region VARCHAR, contact_phone VARCHAR, backup_generation BOOLEAN
);

CREATE TABLE IF NOT EXISTS INSPECTIONS_RAW (
  record        VARIANT,          -- nested findings[] + resistograph / thermal objects
  _source_file  VARCHAR,
  _loaded_at    TIMESTAMP_LTZ
);

SHOW TABLES IN SCHEMA GRID_DB.RAW;
