/* =============================================================================
   00 - Account setup: roles, warehouses, resource monitor, account-level grants
   Run once as a user holding ACCOUNTADMIN (a trial user does).

   SnowPro Core topics: system vs. custom roles, role hierarchy, least privilege,
   warehouse sizing / auto-suspend / multi-cluster scaling policy, resource monitors.
   ============================================================================= */

-- ---------------------------------------------------------------------------
-- Roles: custom functional hierarchy rolled up to SYSADMIN (best practice, so
-- SYSADMIN can manage every object the custom roles create).
--
--   SYSADMIN
--     +-- GRID_ADMIN            owns all project objects, runs pipelines
--           +-- GRID_ENGINEER   full read incl. unmasked PII, all regions
--                 +-- GRID_ANALYST   marts only, row-filtered to assigned regions
--                       +-- GRID_VIEWER   secure views + Streamlit only
-- ---------------------------------------------------------------------------
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS GRID_ADMIN    COMMENT = 'Owns the grid intelligence platform objects';
CREATE ROLE IF NOT EXISTS GRID_ENGINEER COMMENT = 'Power systems / asset engineers: all regions, unmasked';
CREATE ROLE IF NOT EXISTS GRID_ANALYST  COMMENT = 'Planning analysts: marts only, row access by region';
CREATE ROLE IF NOT EXISTS GRID_VIEWER   COMMENT = 'Stakeholders: secure views and dashboards only';

USE ROLE SECURITYADMIN;

GRANT ROLE GRID_VIEWER   TO ROLE GRID_ANALYST;
GRANT ROLE GRID_ANALYST  TO ROLE GRID_ENGINEER;
GRANT ROLE GRID_ENGINEER TO ROLE GRID_ADMIN;
GRANT ROLE GRID_ADMIN    TO ROLE SYSADMIN;

-- grant every role directly to the current user so governance can be tested
-- with USE ROLE (see setup/08_governance.sql)
SET my_user = '"' || CURRENT_USER() || '"';   -- quoted: usernames may contain . or @
GRANT ROLE GRID_ADMIN    TO USER IDENTIFIER($my_user);
GRANT ROLE GRID_ENGINEER TO USER IDENTIFIER($my_user);
GRANT ROLE GRID_ANALYST  TO USER IDENTIFIER($my_user);
GRANT ROLE GRID_VIEWER   TO USER IDENTIFIER($my_user);

-- ---------------------------------------------------------------------------
-- Warehouses: one per workload so they can be sized, monitored and suspended
-- independently. 60 s auto-suspend keeps trial credits low.
-- ---------------------------------------------------------------------------
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS WH_INGEST
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'COPY INTO loads from internal stages';

CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM
  WAREHOUSE_SIZE = 'SMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Tasks, MERGEs and dynamic table refreshes';

-- multi-cluster (Enterprise): scales out for concurrent dashboard users rather
-- than up; ECONOMY favours keeping clusters busy over starting new ones
CREATE WAREHOUSE IF NOT EXISTS WH_BI
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  MIN_CLUSTER_COUNT = 1 MAX_CLUSTER_COUNT = 2 SCALING_POLICY = 'ECONOMY'
  COMMENT = 'Streamlit dashboards and ad-hoc analysis';

GRANT ALL ON WAREHOUSE WH_INGEST    TO ROLE GRID_ADMIN;
GRANT ALL ON WAREHOUSE WH_TRANSFORM TO ROLE GRID_ADMIN;
GRANT ALL ON WAREHOUSE WH_BI        TO ROLE GRID_ADMIN;
GRANT USAGE ON WAREHOUSE WH_TRANSFORM TO ROLE GRID_ENGINEER;
GRANT USAGE ON WAREHOUSE WH_BI        TO ROLE GRID_VIEWER;   -- inherited by analyst / engineer

-- ---------------------------------------------------------------------------
-- Account-level privileges (ACCOUNTADMIN)
-- ---------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

-- resource monitor: notify at 75 %, suspend after running queries finish at
-- 100 %, kill running queries at 110 %
CREATE RESOURCE MONITOR IF NOT EXISTS RM_GRID_MONTHLY
  WITH CREDIT_QUOTA = 25 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 75 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND
           ON 110 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE WH_INGEST    SET RESOURCE_MONITOR = RM_GRID_MONTHLY;
ALTER WAREHOUSE WH_TRANSFORM SET RESOURCE_MONITOR = RM_GRID_MONTHLY;
ALTER WAREHOUSE WH_BI        SET RESOURCE_MONITOR = RM_GRID_MONTHLY;

GRANT CREATE DATABASE        ON ACCOUNT TO ROLE GRID_ADMIN;
GRANT EXECUTE TASK           ON ACCOUNT TO ROLE GRID_ADMIN;
GRANT APPLY MASKING POLICY   ON ACCOUNT TO ROLE GRID_ADMIN;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE GRID_ADMIN;
GRANT APPLY TAG              ON ACCOUNT TO ROLE GRID_ADMIN;
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE GRID_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE GRID_ADMIN;

-- ACCOUNT_USAGE views (credits, query history) for the Platform Ops page
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE GRID_ADMIN;

SHOW GRANTS TO ROLE GRID_ADMIN;
