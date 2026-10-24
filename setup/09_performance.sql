/* =============================================================================
   09 - Performance: micro-partition pruning, clustering, materialized views,
        search optimization, caching, query acceleration

   SnowPro Core topics: micro-partitions and pruning, clustering depth /
   SYSTEM$CLUSTERING_INFORMATION, automatic clustering cost, materialized view
   restrictions, search optimization service, the three cache layers (result,
   warehouse local disk, metadata), Query Profile, QUERY_HISTORY.
   Most statements here are meant to be run one by one in a Snowsight worksheet
   with the Query Profile open.
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE WAREHOUSE WH_BI;
USE DATABASE GRID_DB;

-- ---------------------------------------------------------- clustering ----
-- XFMR_LOADING_HOURLY (~16M rows) is written ORDER BY delivery_date, feeder_id,
-- so it is already well clustered. Declaring the key makes Snowflake keep it
-- that way as data changes (automatic clustering uses serverless credits).
ALTER TABLE STAGING.XFMR_LOADING_HOURLY CLUSTER BY (delivery_date, feeder_id);

-- lower average_depth = better; compare a well-clustered and a random column
SELECT SYSTEM$CLUSTERING_INFORMATION('STAGING.XFMR_LOADING_HOURLY', '(delivery_date, feeder_id)');
SELECT SYSTEM$CLUSTERING_INFORMATION('STAGING.XFMR_LOADING_HOURLY', '(xfmr_id)');

-- The table is rebuilt daily by INSERT OVERWRITE already in key order, so
-- background reclustering would only spend credits. Suspend it on the trial:
ALTER TABLE STAGING.XFMR_LOADING_HOURLY SUSPEND RECLUSTER;

-- pruning demo: Query Profile -> "Partitions scanned" vs "Partitions total"
SELECT feeder_id, MAX(loading_pct) AS peak_pct
FROM STAGING.XFMR_LOADING_HOURLY
WHERE delivery_date BETWEEN DATEADD(DAY, -7, CURRENT_DATE()) AND CURRENT_DATE()
GROUP BY feeder_id;

-- ---------------------------------------------------- materialized view ----
-- Single-table aggregate, kept up to date by Snowflake (serverless). MVs
-- cannot join, use window functions, or use non-deterministic functions;
-- use a dynamic table for anything more complex.
CREATE OR REPLACE MATERIALIZED VIEW MARTS.MV_DA_PRICE_DAILY
  COMMENT = 'Daily day-ahead price statistics'
AS
SELECT delivery_date,
       COUNT(*)          AS hours_priced,
       AVG(zonal_price)  AS avg_price,
       MIN(zonal_price)  AS min_price,
       MAX(zonal_price)  AS max_price,
       SUM(zonal_price)  AS sum_price
FROM STAGING.DA_PRICE_HOURLY
GROUP BY delivery_date;

-- the optimizer can rewrite queries on the base table to use the MV
SELECT delivery_date, MAX(zonal_price) - MIN(zonal_price) AS daily_spread
FROM STAGING.DA_PRICE_HOURLY
GROUP BY delivery_date
ORDER BY daily_spread DESC
LIMIT 10;

-- -------------------------------------------------- search optimization ----
-- Point lookups for one transformer over 16M rows. Estimate the cost first.
SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS('GRID_DB.STAGING.XFMR_LOADING_HOURLY', 'EQUALITY(xfmr_id)');

ALTER TABLE STAGING.XFMR_LOADING_HOURLY ADD SEARCH OPTIMIZATION ON EQUALITY(xfmr_id);

-- after the index builds (SHOW TABLES -> search_optimization_progress = 100):
SELECT interval_start_ts, load_kva, loading_pct
FROM STAGING.XFMR_LOADING_HOURLY
WHERE xfmr_id = 'T-011002'
ORDER BY interval_start_ts;

-- --------------------------------------------------------------- caching ----
-- 1) metadata cache: answered from micro-partition metadata, no warehouse needed
SELECT COUNT(*), MIN(delivery_date), MAX(delivery_date) FROM STAGING.XFMR_LOADING_HOURLY;

-- 2) result cache: run twice, the second run is served in ms (24 h, same role/text)
SELECT region, health_band, COUNT(*) AS assets FROM MARTS.ASSET_RISK GROUP BY ALL ORDER BY ALL;
SELECT region, health_band, COUNT(*) AS assets FROM MARTS.ASSET_RISK GROUP BY ALL ORDER BY ALL;

-- 3) warehouse (local disk) cache: disable the result cache and re-run; the
-- profile shows "Percentage scanned from cache" while the warehouse stays up
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
SELECT region, health_band, COUNT(*) AS assets FROM MARTS.ASSET_RISK GROUP BY ALL ORDER BY ALL;
ALTER SESSION SET USE_CACHED_RESULT = TRUE;

-- ------------------------------------------------- query acceleration ----
-- offload parts of large scans to serverless compute (Enterprise)
ALTER WAREHOUSE WH_BI SET ENABLE_QUERY_ACCELERATION = TRUE QUERY_ACCELERATION_MAX_SCALE_FACTOR = 4;

-- ------------------------------------------------------ what is expensive? --
SELECT query_id, LEFT(query_text, 80) AS query, warehouse_name, total_elapsed_time / 1000 AS seconds,
       bytes_scanned / POWER(1024, 2) AS mb_scanned, partitions_scanned, partitions_total,
       percentage_scanned_from_cache
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY          -- ~45 min latency
WHERE execution_status = 'SUCCESS'
  AND database_name = 'GRID_DB'
  AND start_time >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
ORDER BY total_elapsed_time DESC
LIMIT 15;
