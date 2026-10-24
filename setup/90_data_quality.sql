/* =============================================================================
   90 - Data quality checks
   Part 1: one query, one row per check, failures = 0 means PASS.
   Part 2: Snowflake Data Metric Functions (DMFs) scheduled on key tables.
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE WAREHOUSE WH_BI;
USE DATABASE GRID_DB;

-- --------------------------------------------------------- part 1 ---------
WITH checks AS (
  SELECT 'demand: duplicate (date, hour)' AS check_name, COUNT(*) AS failures
  FROM (SELECT 1 FROM STAGING.DEMAND_HOURLY GROUP BY delivery_date, delivery_hour HAVING COUNT(*) > 1)

  UNION ALL
  SELECT 'demand: missing hours in last 30 complete days',
         30 * 24 - COUNT(*)
  FROM STAGING.DEMAND_HOURLY
  WHERE delivery_date BETWEEN DATEADD(DAY, -30, CURRENT_DATE()) AND DATEADD(DAY, -1, CURRENT_DATE())

  UNION ALL
  SELECT 'demand: implausible Ontario demand (< 8 GW or > 30 GW)',
         COUNT_IF(ontario_demand_mw NOT BETWEEN 8000 AND 30000)
  FROM STAGING.DEMAND_HOURLY

  UNION ALL
  SELECT 'demand: stale (> 2 days since latest hour)',
         IFF(DATEDIFF(DAY, MAX(delivery_date), CURRENT_DATE()) > 2, 1, 0)
  FROM STAGING.DEMAND_HOURLY

  UNION ALL
  SELECT 'fuel: negative output', COUNT_IF(output_mwh < 0) FROM STAGING.FUEL_HOURLY

  UNION ALL
  -- hours where IESO itself flags telemetry on most fuels (e.g. 2025-04-08 HE16)
  -- are excluded: the gap there is a metering artefact, not a pipeline error
  SELECT 'fuel: supply vs demand gap > 25 % (clean-telemetry hours)',
         COUNT_IF(ABS(total_gen_mwh - ontario_demand_mw - COALESCE(net_export_mw, 0)) > 0.25 * ontario_demand_mw)
  FROM MARTS.FACT_GRID_HOURLY
  WHERE total_gen_mwh IS NOT NULL AND telemetry_flags <= 2

  UNION ALL
  SELECT 'price: stale day-ahead price (> 3 days)',
         IFF(DATEDIFF(DAY, MAX(delivery_date), CURRENT_DATE()) > 3, 1, 0)
  FROM STAGING.DA_PRICE_HOURLY

  UNION ALL
  SELECT 'price: days with != 24 priced hours',
         COUNT_IF(hours_priced <> 24)
  FROM MARTS.MV_DA_PRICE_DAILY

  UNION ALL
  SELECT 'assets: transformers without a feeder',
         COUNT(*) FROM RAW.TRANSFORMERS t LEFT JOIN RAW.FEEDERS f USING (feeder_id) WHERE f.feeder_id IS NULL

  UNION ALL
  SELECT 'assets: health index null or out of 0-100',
         COUNT_IF(health_index IS NULL OR health_index NOT BETWEEN 0 AND 100)
  FROM MARTS.ASSET_RISK

  UNION ALL
  SELECT 'loading: rows != transformers x demand hours',
         ABS((SELECT COUNT(*) FROM STAGING.XFMR_LOADING_HOURLY)
             - (SELECT COUNT(*) FROM RAW.TRANSFORMERS)
               * (SELECT COUNT(*) FROM STAGING.DEMAND_HOURLY WHERE delivery_date > DATEADD(MONTH, -12, CURRENT_DATE())))

  UNION ALL
  SELECT 'pipeline: tasks whose latest run failed', COUNT_IF(state = 'FAILED')
  FROM (
    SELECT name, state
    FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(SCHEDULED_TIME_RANGE_START => DATEADD(DAY, -3, CURRENT_TIMESTAMP())))
    WHERE state IN ('SUCCEEDED', 'FAILED')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY name ORDER BY scheduled_time DESC) = 1
  )
)
SELECT check_name, failures, IFF(failures = 0, 'PASS', 'FAIL') AS status
FROM checks
ORDER BY status, check_name;

-- --------------------------------------------------------- part 2 ---------
-- System DMFs run serverless on a schedule; results land in
-- SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS. Run this part once: adding
-- the same DMF to a column twice is an error.
ALTER TABLE STAGING.DA_PRICE_HOURLY SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE STAGING.DA_PRICE_HOURLY ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (zonal_price);
ALTER TABLE STAGING.DA_PRICE_HOURLY ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (_updated_at);

ALTER TABLE STAGING.DEMAND_HOURLY SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
ALTER TABLE STAGING.DEMAND_HOURLY ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (ontario_demand_mw);

-- SELECT measurement_time, table_name, metric_name, value
-- FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
-- WHERE table_database = 'GRID_DB' ORDER BY measurement_time DESC;
