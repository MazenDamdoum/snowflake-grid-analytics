/* =============================================================================
   12 - Streamlit in Snowflake
   The app files are uploaded to @GRID_DB.APPS.STREAMLIT_STAGE/app/ by
   `python ingest/load_to_snowflake.py --build` before this script runs.

   SnowPro Core topics: Streamlit apps as schema objects, owner rights
   execution, QUERY_WAREHOUSE, granting USAGE on an app.
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE SCHEMA GRID_DB.APPS;

CREATE OR REPLACE STREAMLIT GRID_INTELLIGENCE
  ROOT_LOCATION = '@GRID_DB.APPS.STREAMLIT_STAGE/app'
  MAIN_FILE = '/streamlit_app.py'
  QUERY_WAREHOUSE = WH_BI
  TITLE = 'Ontario Grid & Asset Intelligence'
  COMMENT = 'Grid, market / BESS, asset health, capital plan and platform ops dashboards';

-- The app runs with the privileges of its owner (GRID_ADMIN), so viewers need only
-- USAGE on the app, not on the underlying tables.
GRANT USAGE ON STREAMLIT GRID_INTELLIGENCE TO ROLE GRID_VIEWER;

SHOW STREAMLITS IN SCHEMA GRID_DB.APPS;
-- Open it: Snowsight > Projects > Streamlit > GRID_INTELLIGENCE
