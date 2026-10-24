/* =============================================================================
   11 - Secure Data Sharing

   Scenario: share curated grid and reliability marts with an external
   consultant or the regulator, live and without copying data.

   SnowPro Core topics: provider / consumer, shares contain only grants (no
   data moves), only SECURE views can be shared, consumers pay for their own
   compute, reader accounts for consumers without Snowflake, cross-region
   sharing needs replication / listings.
   ============================================================================= */
USE ROLE ACCOUNTADMIN;          -- CREATE SHARE is an account-level privilege

CREATE SHARE IF NOT EXISTS GRID_MARTS_SHARE
  COMMENT = 'Ontario grid + feeder reliability marts (read-only)';

GRANT USAGE ON DATABASE GRID_DB                       TO SHARE GRID_MARTS_SHARE;
GRANT USAGE ON SCHEMA GRID_DB.MARTS                   TO SHARE GRID_MARTS_SHARE;
GRANT SELECT ON VIEW GRID_DB.MARTS.V_GRID_DAILY       TO SHARE GRID_MARTS_SHARE;
GRANT SELECT ON VIEW GRID_DB.MARTS.V_GRID_HOURLY      TO SHARE GRID_MARTS_SHARE;
GRANT SELECT ON VIEW GRID_DB.MARTS.V_FEEDER_RELIABILITY TO SHARE GRID_MARTS_SHARE;
-- V_ASSET_RISK / V_CRITICAL_CUSTOMERS are deliberately NOT shared: they carry
-- a role-based row access policy and critical-infrastructure data.

SHOW GRANTS TO SHARE GRID_MARTS_SHARE;

-- add a consumer that already has a Snowflake account (same region):
--   ALTER SHARE GRID_MARTS_SHARE ADD ACCOUNTS = <consumer_org>.<consumer_account>;
-- the consumer then runs:
--   CREATE DATABASE GRID_FROM_PROVIDER FROM SHARE <provider_org>.<provider_account>.GRID_MARTS_SHARE;

-- consumer without Snowflake: a reader account (provider pays its compute).
-- Left commented to avoid creating extra accounts on a trial.
--   CREATE MANAGED ACCOUNT GRID_READER
--     ADMIN_NAME = 'reader_admin', ADMIN_PASSWORD = '<strong password>', TYPE = READER;
--   SHOW MANAGED ACCOUNTS;
