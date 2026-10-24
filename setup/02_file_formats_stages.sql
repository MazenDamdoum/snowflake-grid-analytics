/* =============================================================================
   02 - File formats and internal stages

   SnowPro Core topics: named file formats (CSV / XML / JSON options), internal
   named stages vs. user / table stages, directory tables.
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE SCHEMA GRID_DB.RAW;

-- IESO CSVs start with 3 "\\Report title" banner lines + 1 header line
CREATE OR REPLACE FILE FORMAT FF_IESO_CSV
  TYPE = CSV
  SKIP_HEADER = 4
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('')
  TRIM_SPACE = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE   -- generator rows carry a trailing comma
  COMMENT = 'IESO hourly CSV reports (Demand, GenOutputCapabilityMonth)';

-- The intertie report has a two-row header (interface names, then Imp/Exp/Flow),
-- and its column set changes when interties are added. Load each line whole and
-- split it in SQL so a new column never breaks the load.
CREATE OR REPLACE FILE FORMAT FF_IESO_LINE
  TYPE = CSV
  FIELD_DELIMITER = NONE
  SKIP_HEADER = 5
  COMMENT = 'One VARCHAR per line; parsed with SPLIT() downstream';

-- IESO XML: <Document><DocHeader/><DocBody/></Document>. Stripping the outer
-- element yields one row per 2nd-level element (DocHeader, DocBody).
CREATE OR REPLACE FILE FORMAT FF_IESO_XML
  TYPE = XML
  STRIP_OUTER_ELEMENT = TRUE
  COMMENT = 'IESO XML reports -> one VARIANT row per DocHeader / DocBody';

-- synthetic asset CSVs have a proper header -> load by column name
CREATE OR REPLACE FILE FORMAT FF_ASSET_CSV
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  EMPTY_FIELD_AS_NULL = TRUE
  COMMENT = 'Header-bearing CSV for MATCH_BY_COLUMN_NAME loads';

-- newline-delimited JSON inspection records
CREATE OR REPLACE FILE FORMAT FF_NDJSON
  TYPE = JSON
  STRIP_OUTER_ARRAY = FALSE
  COMMENT = 'One JSON document per line';

-- Internal named stages (IF NOT EXISTS: OR REPLACE would delete staged files).
-- Directory tables let us query the file inventory with SQL.
CREATE STAGE IF NOT EXISTS IESO_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Public IESO reports, one folder per report';

CREATE STAGE IF NOT EXISTS ASSET_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Synthetic distribution asset register files';

CREATE STAGE IF NOT EXISTS GRID_DB.APPS.STREAMLIT_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Streamlit in Snowflake source files';

SHOW FILE FORMATS IN SCHEMA GRID_DB.RAW;
SHOW STAGES IN DATABASE GRID_DB;
