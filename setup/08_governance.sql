/* =============================================================================
   08 - Data governance: tags, tag-based masking, row access policy, auditing

   SnowPro Core topics: object tagging, masking policies (column-level
   security), tag-based masking, row access policies with a mapping table,
   IS_ROLE_IN_SESSION vs. CURRENT_ROLE, ACCESS_HISTORY.
   (Enterprise edition features: a trial account is Enterprise.)
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE WAREHOUSE WH_BI;
USE SCHEMA GRID_DB.GOVERNANCE;

-- ----------------------------------------------------------------- tags ----
CREATE TAG IF NOT EXISTS PII
  ALLOWED_VALUES 'NAME', 'PHONE'
  COMMENT = 'Personally identifiable / sensitive customer data';

CREATE TAG IF NOT EXISTS CRITICALITY
  ALLOWED_VALUES 'CRITICAL_INFRASTRUCTURE', 'STANDARD'
  COMMENT = 'Operational sensitivity of a dataset';

-- --------------------------------------------- tag-based masking policy ----
-- One policy, attached to the tag: every column tagged PII is masked
-- automatically, including columns tagged in future. The tag value decides
-- HOW to mask (names fully, phone numbers keep the last 4 digits).
CREATE MASKING POLICY IF NOT EXISTS MP_PII_STRING AS (val STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('GRID_ENGINEER') THEN val            -- engineers + admin (hierarchy)
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GRID_DB.GOVERNANCE.PII') = 'PHONE'
      THEN REGEXP_REPLACE(LEFT(val, LENGTH(val) - 4), '[0-9]', '*') || RIGHT(val, 4)   -- ***-***-0123
    ELSE '*** MASKED ***'
  END
  COMMENT = 'Unmasked for GRID_ENGINEER and above';

-- FORCE replaces a policy already on the tag (keeps re-runs idempotent)
ALTER TAG PII SET MASKING POLICY MP_PII_STRING FORCE;

ALTER TABLE GRID_DB.RAW.CRITICAL_CUSTOMERS MODIFY
  COLUMN customer_name SET TAG PII = 'NAME',
  COLUMN contact_phone SET TAG PII = 'PHONE';

ALTER TABLE GRID_DB.RAW.CRITICAL_CUSTOMERS SET TAG CRITICALITY = 'CRITICAL_INFRASTRUCTURE';

-- ---------------------------------------------------- row access policy ----
-- Entitlement table: which role may see which service region.
CREATE TABLE IF NOT EXISTS REGION_ENTITLEMENTS (
  role_name VARCHAR,
  region    VARCHAR
);

MERGE INTO REGION_ENTITLEMENTS t
USING (SELECT column1 AS role_name, column2 AS region FROM VALUES
         ('GRID_ANALYST', 'NORTH'), ('GRID_ANALYST', 'SOUTH'),
         ('GRID_VIEWER',  'NORTH')) s
ON t.role_name = s.role_name AND t.region = s.region
WHEN NOT MATCHED THEN INSERT (role_name, region) VALUES (s.role_name, s.region);

CREATE ROW ACCESS POLICY IF NOT EXISTS RAP_REGION AS (region_val VARCHAR) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION('GRID_ENGINEER')
  OR EXISTS (
    SELECT 1 FROM GRID_DB.GOVERNANCE.REGION_ENTITLEMENTS e
    WHERE e.role_name = CURRENT_ROLE() AND e.region = region_val
  )
  COMMENT = 'Engineers see all regions; others only regions mapped to their role';

-- CREATE OR REPLACE VIEW in 07 drops policy attachments, so re-attach here
ALTER VIEW GRID_DB.MARTS.V_ASSET_RISK DROP ALL ROW ACCESS POLICIES;
ALTER VIEW GRID_DB.MARTS.V_ASSET_RISK ADD ROW ACCESS POLICY RAP_REGION ON (region);

ALTER VIEW GRID_DB.MARTS.V_CRITICAL_CUSTOMERS DROP ALL ROW ACCESS POLICIES;
ALTER VIEW GRID_DB.MARTS.V_CRITICAL_CUSTOMERS ADD ROW ACCESS POLICY RAP_REGION ON (region);

-- ------------------------------------------------------------ try it out ----
-- Same query, three roles, three answers.
-- New users default to DEFAULT_SECONDARY_ROLES = ('ALL'): every granted role
-- (incl. ACCOUNTADMIN) stays active beside the primary role, so policies using
-- IS_ROLE_IN_SESSION and object privileges would see all of them. Turn
-- secondary roles off to test what each role alone can see.
SELECT CURRENT_SECONDARY_ROLES();
USE SECONDARY ROLES NONE;
USE ROLE GRID_ENGINEER;     -- all regions, names visible
SELECT 'GRID_ENGINEER' AS as_role, region, COUNT(*) AS assets FROM GRID_DB.MARTS.V_ASSET_RISK GROUP BY region ORDER BY region;
SELECT customer_name, contact_phone, region FROM GRID_DB.MARTS.V_CRITICAL_CUSTOMERS LIMIT 5;

USE ROLE GRID_ANALYST;      -- NORTH + SOUTH only, names masked
SELECT 'GRID_ANALYST' AS as_role, region, COUNT(*) AS assets FROM GRID_DB.MARTS.V_ASSET_RISK GROUP BY region ORDER BY region;
SELECT customer_name, contact_phone, region FROM GRID_DB.MARTS.V_CRITICAL_CUSTOMERS LIMIT 5;

USE ROLE GRID_VIEWER;       -- NORTH only, names masked
SELECT 'GRID_VIEWER' AS as_role, region, COUNT(*) AS assets FROM GRID_DB.MARTS.V_ASSET_RISK GROUP BY region ORDER BY region;

USE ROLE GRID_ADMIN;
USE SECONDARY ROLES ALL;

-- ------------------------------------------------------------ discovery ----
-- where are tags / policies applied? (ACCOUNT_USAGE has up to ~2 h latency)
SELECT * FROM TABLE(GRID_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('GRID_DB.RAW.CRITICAL_CUSTOMERS', 'table'));
SELECT * FROM TABLE(GRID_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(REF_ENTITY_NAME => 'GRID_DB.MARTS.V_ASSET_RISK', REF_ENTITY_DOMAIN => 'view'));

-- who read the sensitive table, through which objects (Enterprise)
SELECT query_start_time, user_name, obj.value:"objectName"::STRING AS object_read
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
     LATERAL FLATTEN(input => base_objects_accessed) obj
WHERE obj.value:"objectName"::STRING = 'GRID_DB.RAW.CRITICAL_CUSTOMERS'
ORDER BY query_start_time DESC
LIMIT 20;
