/* =============================================================================
   10 - Continuous data protection: Time Travel, UNDROP, zero-copy cloning, SWAP

   SnowPro Core topics: DATA_RETENTION_TIME_IN_DAYS (0-1 Standard / transient,
   up to 90 Enterprise), AT / BEFORE (TIMESTAMP, OFFSET, STATEMENT), UNDROP,
   Fail-safe (7 days, permanent tables only, Snowflake-support recovery only),
   zero-copy clones (metadata-only until data diverges), ALTER TABLE ... SWAP.
   Run step by step in a worksheet.
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE WAREHOUSE WH_BI;
USE DATABASE GRID_DB;

-- retention is set per object; STAGING inherits 7 days from the schema
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN TABLE STAGING.DA_PRICE_HOURLY;

-- ------------------------------------------- 1. recover from a bad UPDATE ----
-- simulate a bad hand-edit: zero out the prices of the latest day
UPDATE STAGING.DA_PRICE_HOURLY
SET zonal_price = 0
WHERE delivery_date = (SELECT MAX(delivery_date) FROM STAGING.DA_PRICE_HOURLY);
SET bad_update = LAST_QUERY_ID();

SELECT delivery_date, delivery_hour, zonal_price
FROM STAGING.DA_PRICE_HOURLY
WHERE delivery_date = (SELECT MAX(delivery_date) FROM STAGING.DA_PRICE_HOURLY)
ORDER BY delivery_hour LIMIT 5;                                   -- all zeros

-- the same rows as they were just before that statement
SELECT delivery_date, delivery_hour, zonal_price
FROM STAGING.DA_PRICE_HOURLY BEFORE (STATEMENT => $bad_update)
WHERE delivery_date = (SELECT MAX(delivery_date) FROM STAGING.DA_PRICE_HOURLY)
ORDER BY delivery_hour LIMIT 5;

-- restore in place (no DDL, so dependent dynamic tables are untouched)
MERGE INTO STAGING.DA_PRICE_HOURLY t
USING (SELECT * FROM STAGING.DA_PRICE_HOURLY BEFORE (STATEMENT => $bad_update)) s
  ON t.delivery_date = s.delivery_date AND t.delivery_hour = s.delivery_hour
WHEN MATCHED AND t.zonal_price IS DISTINCT FROM s.zonal_price THEN UPDATE SET zonal_price = s.zonal_price;

-- ------------------------------------------------------- 2. UNDROP -------
CREATE OR REPLACE TABLE STAGING.SCRATCH_PRICES CLONE STAGING.DA_PRICE_HOURLY;
DROP TABLE STAGING.SCRATCH_PRICES;
SHOW TABLES HISTORY LIKE 'SCRATCH_PRICES' IN SCHEMA STAGING;        -- dropped_on is set
UNDROP TABLE STAGING.SCRATCH_PRICES;
SELECT COUNT(*) FROM STAGING.SCRATCH_PRICES;

-- ------------------------------------------------- 3. point-in-time clone --
-- clone the table as of 10 minutes ago (fails if the table is younger than that)
-- CREATE OR REPLACE TABLE STAGING.DA_PRICE_10MIN_AGO CLONE STAGING.DA_PRICE_HOURLY AT (OFFSET => -600);

-- ------------------------------------------------------- 4. SWAP ----------
-- atomic exchange of two tables: build the new version beside the live one,
-- then promote it in a single metadata operation
CREATE OR REPLACE TABLE STAGING.SCRATCH_PRICES_V2 CLONE STAGING.SCRATCH_PRICES;
UPDATE STAGING.SCRATCH_PRICES_V2 SET flag = 'REBUILT';
ALTER TABLE STAGING.SCRATCH_PRICES SWAP WITH STAGING.SCRATCH_PRICES_V2;
SELECT flag, COUNT(*) FROM STAGING.SCRATCH_PRICES GROUP BY flag;      -- now 'REBUILT'
DROP TABLE STAGING.SCRATCH_PRICES;
DROP TABLE STAGING.SCRATCH_PRICES_V2;

-- ----------------------------------------- 5. zero-copy DEV environment --
-- Whole database cloned in seconds; no storage is used until DEV diverges.
-- Notes: cloned tasks start SUSPENDED; internal named stages are cloned
-- empty (files are not copied); privileges on the source are not cloned
-- except on child objects.
CREATE OR REPLACE DATABASE GRID_DB_DEV CLONE GRID_DB
  COMMENT = 'Zero-copy clone of GRID_DB for development';

SELECT 'PROD' AS env, COUNT(*) AS assets FROM GRID_DB.MARTS.ASSET_RISK
UNION ALL
SELECT 'DEV', COUNT(*) FROM GRID_DB_DEV.MARTS.ASSET_RISK;

-- storage owned by the clone (grows only as DEV changes)
SELECT table_catalog, table_schema, table_name, active_bytes, retained_for_clone_bytes
FROM GRID_DB_DEV.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE table_schema = 'STAGING'
ORDER BY active_bytes DESC
LIMIT 10;

-- clean up when done
DROP DATABASE IF EXISTS GRID_DB_DEV;
