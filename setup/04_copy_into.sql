/* =============================================================================
   04 - Bulk loading with COPY INTO
   Executed by ingest/load_to_snowflake.py right after it PUTs files to the
   stages; safe to re-run at any time.

   SnowPro Core topics: COPY INTO with transformations, PATTERN, ON_ERROR,
   METADATA$ columns, load metadata (64-day file de-duplication), FORCE vs.
   TRUNCATE, VALIDATION_MODE, LOAD_HISTORY, directory tables.

   Two load patterns side by side:
     * IESO  -> INCREMENTAL. COPY skips files it has already loaded (same name
                + checksum). A re-published file (IESO updates current-year
                files daily) has a new checksum, so it loads again; the
                STAGING MERGE de-duplicates on the natural key.
     * Assets -> FULL REFRESH. TRUNCATE also clears the load metadata of the table,
                so the same file names load again from scratch.
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE WAREHOUSE WH_INGEST;
USE SCHEMA GRID_DB.RAW;

-- ---------------------------------------------------------------- IESO CSV --
COPY INTO IESO_DEMAND_RAW
  (delivery_date, delivery_hour, market_demand_mw, ontario_demand_mw, _source_file, _source_row, _loaded_at)
FROM (
  SELECT $1, $2, $3, $4, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
  FROM @IESO_STAGE/Demand/
)
FILE_FORMAT = (FORMAT_NAME = 'FF_IESO_CSV')
PATTERN = '.*PUB_Demand_[0-9]{4}[.]csv([.]gz)?'
ON_ERROR = 'ABORT_STATEMENT';

COPY INTO IESO_GEN_CAPABILITY_RAW
FROM (
  SELECT $1, $2, $3, $4,
         $5,  $6,  $7,  $8,  $9,  $10, $11, $12, $13, $14, $15, $16,
         $17, $18, $19, $20, $21, $22, $23, $24, $25, $26, $27, $28,
         METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
  FROM @IESO_STAGE/GenOutputCapabilityMonth/
)
FILE_FORMAT = (FORMAT_NAME = 'FF_IESO_CSV')
PATTERN = '.*PUB_GenOutputCapabilityMonth_[0-9]{6}[.]csv([.]gz)?'
ON_ERROR = 'CONTINUE';              -- tolerate odd rows; reported in LOAD_HISTORY

COPY INTO IESO_INTERTIE_RAW (line, _source_file, _source_row, _loaded_at)
FROM (
  SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$START_SCAN_TIME
  FROM @IESO_STAGE/IntertieScheduleFlowYear/
)
FILE_FORMAT = (FORMAT_NAME = 'FF_IESO_LINE')
PATTERN = '.*PUB_IntertieScheduleFlowYear_[0-9]{4}[.]csv([.]gz)?'
ON_ERROR = 'ABORT_STATEMENT';

-- ---------------------------------------------------------------- IESO XML --
COPY INTO IESO_FUEL_HOURLY_RAW (doc, _source_file, _loaded_at)
FROM (SELECT $1, METADATA$FILENAME, METADATA$START_SCAN_TIME FROM @IESO_STAGE/GenOutputbyFuelHourly/)
FILE_FORMAT = (FORMAT_NAME = 'FF_IESO_XML')
PATTERN = '.*PUB_GenOutputbyFuelHourly_[0-9]{4}[.]xml([.]gz)?'
ON_ERROR = 'ABORT_STATEMENT';

COPY INTO IESO_DA_PRICE_RAW (doc, _source_file, _loaded_at)
FROM (SELECT $1, METADATA$FILENAME, METADATA$START_SCAN_TIME FROM @IESO_STAGE/DAHourlyOntarioZonalPrice/)
FILE_FORMAT = (FORMAT_NAME = 'FF_IESO_XML')
PATTERN = '.*PUB_DAHourlyOntarioZonalPrice_[0-9]{8}[.]xml([.]gz)?'
ON_ERROR = 'SKIP_FILE';             -- one malformed day should not block the rest

COPY INTO IESO_TX_OUTAGES_RAW (doc, _source_file, _loaded_at)
FROM (SELECT $1, METADATA$FILENAME, METADATA$START_SCAN_TIME FROM @IESO_STAGE/TxOutages1to30DaysPlanned/)
FILE_FORMAT = (FORMAT_NAME = 'FF_IESO_XML')
PATTERN = '.*PUB_TxOutages1to30DaysPlanned_[0-9]{8}[.]xml([.]gz)?'
ON_ERROR = 'SKIP_FILE';

-- ------------------------------------------------- synthetic assets (full) --
TRUNCATE TABLE SUBSTATIONS;
COPY INTO SUBSTATIONS FROM @ASSET_STAGE
  FILE_FORMAT = (FORMAT_NAME = 'FF_ASSET_CSV') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  PATTERN = '.*substations[.]csv([.]gz)?';

TRUNCATE TABLE FEEDERS;
COPY INTO FEEDERS FROM @ASSET_STAGE
  FILE_FORMAT = (FORMAT_NAME = 'FF_ASSET_CSV') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  PATTERN = '.*feeders[.]csv([.]gz)?';

TRUNCATE TABLE TRANSFORMERS;
COPY INTO TRANSFORMERS FROM @ASSET_STAGE
  FILE_FORMAT = (FORMAT_NAME = 'FF_ASSET_CSV') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  PATTERN = '.*transformers[.]csv([.]gz)?';

TRUNCATE TABLE POLES;
COPY INTO POLES FROM @ASSET_STAGE
  FILE_FORMAT = (FORMAT_NAME = 'FF_ASSET_CSV') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  PATTERN = '.*poles[.]csv([.]gz)?';

TRUNCATE TABLE OUTAGE_EVENTS;
COPY INTO OUTAGE_EVENTS FROM @ASSET_STAGE
  FILE_FORMAT = (FORMAT_NAME = 'FF_ASSET_CSV') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  PATTERN = '.*outage_events[.]csv([.]gz)?';

TRUNCATE TABLE CRITICAL_CUSTOMERS;
COPY INTO CRITICAL_CUSTOMERS FROM @ASSET_STAGE
  FILE_FORMAT = (FORMAT_NAME = 'FF_ASSET_CSV') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  PATTERN = '.*critical_customers[.]csv([.]gz)?';

TRUNCATE TABLE INSPECTIONS_RAW;
COPY INTO INSPECTIONS_RAW (record, _source_file, _loaded_at)
FROM (SELECT $1, METADATA$FILENAME, METADATA$START_SCAN_TIME FROM @ASSET_STAGE)
  FILE_FORMAT = (FORMAT_NAME = 'FF_NDJSON')
  PATTERN = '.*inspections[.]json([.]gz)?';

/* Dry run without loading anything. VALIDATION_MODE is not allowed together
   with a transformation (SELECT) or MATCH_BY_COLUMN_NAME, so it suits plain
   positional loads, e.g.:

   COPY INTO SOME_TABLE FROM @ASSET_STAGE/some_file.csv.gz
     FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1)
     VALIDATION_MODE = RETURN_ERRORS;
*/

-- ------------------------------------------------------------ observability --
ALTER STAGE IESO_STAGE REFRESH;      -- sync the directory table with PUT uploads
ALTER STAGE ASSET_STAGE REFRESH;

-- what was loaded in the last hour, per file (bulk loads, 14-day window)
SELECT table_name, file_name, status, row_count, row_parsed, error_count, first_error_message, last_load_time
FROM GRID_DB.INFORMATION_SCHEMA.LOAD_HISTORY
WHERE schema_name = 'RAW'
  AND last_load_time >= DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
ORDER BY last_load_time DESC;
