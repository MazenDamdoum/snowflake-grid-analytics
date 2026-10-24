/* =============================================================================
   01 - Database, schemas (medallion layout) and object grants

   SnowPro Core topics: permanent vs. transient objects, Time Travel retention,
   managed access schemas, future grants.
   ============================================================================= */
USE ROLE GRID_ADMIN;

CREATE DATABASE IF NOT EXISTS GRID_DB
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Ontario Grid & Asset Intelligence platform';

-- RAW is TRANSIENT: everything in it can be re-loaded from the stage files,
-- so there is no point paying for 7 days of Fail-safe storage.
CREATE TRANSIENT SCHEMA IF NOT EXISTS GRID_DB.RAW
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Landing zone: files as delivered, all VARCHAR / VARIANT, plus load metadata';

CREATE SCHEMA IF NOT EXISTS GRID_DB.STAGING
  DATA_RETENTION_TIME_IN_DAYS = 7
  COMMENT = 'Typed, de-duplicated, conformed tables (MERGE targets of the task DAG)';

-- MANAGED ACCESS: only the schema owner / MANAGE GRANTS can grant on objects,
-- even if another role creates them -> central control over who sees marts
CREATE SCHEMA IF NOT EXISTS GRID_DB.MARTS WITH MANAGED ACCESS
  DATA_RETENTION_TIME_IN_DAYS = 7
  COMMENT = 'Business-facing dynamic tables and secure views';

CREATE SCHEMA IF NOT EXISTS GRID_DB.GOVERNANCE
  COMMENT = 'Tags, masking / row access policies, entitlement tables, audit log';

CREATE SCHEMA IF NOT EXISTS GRID_DB.APPS
  COMMENT = 'UDFs, Snowpark stored procedures and the Streamlit app';

-- ---------------------------------------------------------------------------
-- Grants. Future grants make new objects visible without re-running grants.
-- ---------------------------------------------------------------------------
GRANT USAGE ON DATABASE GRID_DB TO ROLE GRID_VIEWER;   -- inherited upward

-- engineers: read everything
GRANT USAGE ON SCHEMA GRID_DB.RAW     TO ROLE GRID_ENGINEER;
GRANT USAGE ON SCHEMA GRID_DB.STAGING TO ROLE GRID_ENGINEER;
GRANT SELECT ON ALL TABLES    IN SCHEMA GRID_DB.RAW     TO ROLE GRID_ENGINEER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA GRID_DB.RAW     TO ROLE GRID_ENGINEER;
GRANT SELECT ON ALL TABLES    IN SCHEMA GRID_DB.STAGING TO ROLE GRID_ENGINEER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA GRID_DB.STAGING TO ROLE GRID_ENGINEER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA GRID_DB.STAGING TO ROLE GRID_ENGINEER;

-- analysts: marts tables (dynamic + materialized)
GRANT USAGE ON SCHEMA GRID_DB.MARTS TO ROLE GRID_VIEWER;
GRANT SELECT ON FUTURE DYNAMIC TABLES      IN SCHEMA GRID_DB.MARTS TO ROLE GRID_ANALYST;
GRANT SELECT ON FUTURE TABLES              IN SCHEMA GRID_DB.MARTS TO ROLE GRID_ANALYST;
GRANT SELECT ON FUTURE MATERIALIZED VIEWS  IN SCHEMA GRID_DB.MARTS TO ROLE GRID_ANALYST;

-- viewers: secure views only (every view in MARTS is created SECURE)
GRANT SELECT ON FUTURE VIEWS IN SCHEMA GRID_DB.MARTS TO ROLE GRID_VIEWER;

-- apps: functions / procedures for analysts (Streamlit is granted in 12)
GRANT USAGE ON SCHEMA GRID_DB.APPS TO ROLE GRID_VIEWER;
GRANT USAGE ON FUTURE FUNCTIONS  IN SCHEMA GRID_DB.APPS TO ROLE GRID_ANALYST;
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA GRID_DB.APPS TO ROLE GRID_ANALYST;

SHOW SCHEMAS IN DATABASE GRID_DB;
