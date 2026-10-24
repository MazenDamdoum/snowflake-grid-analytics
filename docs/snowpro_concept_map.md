# SnowPro Core concept map

Where each SnowPro Core exam topic is implemented in this repository. Links point at the line.

## 1. Snowflake AI Data Cloud features and architecture

| Concept | Implementation |
|---|---|
| Separation of storage and compute; virtual warehouses per workload | [00_account_setup.sql:48](../setup/00_account_setup.sql#L48): `WH_INGEST`, `WH_TRANSFORM`, `WH_BI` |
| Multi-cluster warehouse, scaling policy | [00_account_setup.sql:59](../setup/00_account_setup.sql#L59): `MAX_CLUSTER_COUNT = 2`, `SCALING_POLICY = 'ECONOMY'` |
| Auto-suspend / auto-resume, initially suspended | [00_account_setup.sql:48](../setup/00_account_setup.sql#L48) |
| Resource monitors (notify / suspend / suspend immediate) | [00_account_setup.sql:75](../setup/00_account_setup.sql#L75) |
| Query acceleration service | [09_performance.sql:87](../setup/09_performance.sql#L87) |
| Serverless features (tasks, MV and DMF maintenance, search optimization, automatic clustering) | [05](../setup/05_streams_tasks.sql), [09](../setup/09_performance.sql), [90](../setup/90_data_quality.sql) |
| Streamlit in Snowflake | [12_streamlit.sql:12](../setup/12_streamlit.sql#L12), [streamlit/](../streamlit) |

## 2. Account access and security

| Concept | Implementation |
|---|---|
| System roles: USERADMIN creates roles, SECURITYADMIN grants, SYSADMIN owns compute | [00_account_setup.sql:19](../setup/00_account_setup.sql#L19) |
| Custom role hierarchy rolled up to SYSADMIN | [00_account_setup.sql:31](../setup/00_account_setup.sql#L31) |
| Least privilege per role; future grants | [01_databases_schemas.sql:38](../setup/01_databases_schemas.sql#L38) |
| Managed access schema | [01_databases_schemas.sql:25](../setup/01_databases_schemas.sql#L25) |
| Owner rights (stored procedures, Streamlit) | [06_udfs_procs.sql:155](../setup/06_udfs_procs.sql#L155), [12_streamlit.sql](../setup/12_streamlit.sql) |
| Account-level privileges (`EXECUTE TASK`, `APPLY MASKING POLICY`, `IMPORTED PRIVILEGES`) | [00_account_setup.sql:85](../setup/00_account_setup.sql#L85) |

## 3. Data governance

| Concept | Implementation |
|---|---|
| Object tagging with allowed values | [08_governance.sql:14](../setup/08_governance.sql#L14) |
| Masking policy with `IS_ROLE_IN_SESSION` (respects hierarchy) | [08_governance.sql:26](../setup/08_governance.sql#L26) |
| Tag-based masking; `SYSTEM$GET_TAG_ON_CURRENT_COLUMN` varies masking by tag value | [08_governance.sql:36](../setup/08_governance.sql#L36) |
| Row access policy with a mapping (entitlement) table | [08_governance.sql:58](../setup/08_governance.sql#L58) |
| Secondary roles (`DEFAULT_SECONDARY_ROLES = ALL` hides policy effects; `USE SECONDARY ROLES NONE` to test) | [08_governance.sql](../setup/08_governance.sql) |
| Secure views (definition hidden, no optimizer leaks) | [07_marts_dynamic_tables.sql:196](../setup/07_marts_dynamic_tables.sql#L196) |
| ACCESS_HISTORY lineage | [08_governance.sql:95](../setup/08_governance.sql#L95) |
| Data Metric Functions | [90_data_quality.sql:79](../setup/90_data_quality.sql#L79) |

## 4. Data loading and unloading

| Concept | Implementation |
|---|---|
| Named file formats: CSV skip header, `FIELD_DELIMITER = NONE`, XML `STRIP_OUTER_ELEMENT`, JSON, `PARSE_HEADER` | [02_file_formats_stages.sql](../setup/02_file_formats_stages.sql) |
| Internal named stages with directory tables; `ALTER STAGE ... REFRESH` | [02_file_formats_stages.sql:54](../setup/02_file_formats_stages.sql#L54) |
| PUT with `AUTO_COMPRESS`, uploading only changed files | [load_to_snowflake.py](../ingest/load_to_snowflake.py) |
| COPY with transformation and `METADATA$FILENAME` / `FILE_ROW_NUMBER` / `START_SCAN_TIME` | [04_copy_into.sql:26](../setup/04_copy_into.sql#L26) |
| `PATTERN`; `ON_ERROR` = ABORT_STATEMENT / CONTINUE / SKIP_FILE | [04_copy_into.sql:43](../setup/04_copy_into.sql#L43) |
| `MATCH_BY_COLUMN_NAME` | [04_copy_into.sql:81](../setup/04_copy_into.sql#L81) |
| Load metadata (64 days) vs. TRUNCATE resetting it, vs. `FORCE` | [04_copy_into.sql:74](../setup/04_copy_into.sql#L74) |
| `VALIDATION_MODE` (and when it is not allowed) | [04_copy_into.sql:116](../setup/04_copy_into.sql#L116) |
| LOAD_HISTORY | [04_copy_into.sql:125](../setup/04_copy_into.sql#L125) |

## 5. Data transformations

| Concept | Implementation |
|---|---|
| Semi-structured XML: `"@"`, `"$"`, `XMLGET`, nested `LATERAL FLATTEN` | [05_streams_tasks.sql:244](../setup/05_streams_tasks.sql#L244) |
| JSON paths, `ARRAY_SIZE`, `FLATTEN` of nested arrays | [05_streams_tasks.sql:172](../setup/05_streams_tasks.sql#L172) |
| `SPLIT` / `ARRAY_SLICE` / `FLATTEN` index for a schema-drifting CSV | [05_streams_tasks.sql:322](../setup/05_streams_tasks.sql#L322) |
| `UNPIVOT`, conditional aggregation pivot | [05_streams_tasks.sql:290](../setup/05_streams_tasks.sql#L290) |
| Append-only streams, `SHOW_INITIAL_ROWS` | [05_streams_tasks.sql:184](../setup/05_streams_tasks.sql#L184) |
| Task DAG, CRON with time zone, `WHEN SYSTEM$STREAM_HAS_DATA` | [05_streams_tasks.sql:192](../setup/05_streams_tasks.sql#L192) |
| Finalizer task, `SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')` | [05_streams_tasks.sql:469](../setup/05_streams_tasks.sql#L469) |
| `SYSTEM$TASK_DEPENDENTS_ENABLE` | [05_streams_tasks.sql:482](../setup/05_streams_tasks.sql#L482) |
| MERGE upsert with QUALIFY de-duplication | [05_streams_tasks.sql](../setup/05_streams_tasks.sql) |
| `INSERT OVERWRITE` rebuild; deterministic noise with `HASH` | [05_streams_tasks.sql:440](../setup/05_streams_tasks.sql#L440) |
| Dynamic tables: `TARGET_LAG`, `DOWNSTREAM`, `REFRESH_MODE = FULL` | [07_marts_dynamic_tables.sql:16](../setup/07_marts_dynamic_tables.sql#L16), [:113](../setup/07_marts_dynamic_tables.sql#L113) |
| SQL UDFs | [06_udfs_procs.sql:11](../setup/06_udfs_procs.sql#L11) |
| Python UDF | [06_udfs_procs.sql:46](../setup/06_udfs_procs.sql#L46) |
| Snowpark Python stored procedures returning tables, with parameter binding | [06_udfs_procs.sql:90](../setup/06_udfs_procs.sql#L90), [:155](../setup/06_udfs_procs.sql#L155) |
| Lateral column aliases, `MAX_BY`, `GROUP BY ALL` | [07_marts_dynamic_tables.sql](../setup/07_marts_dynamic_tables.sql) |

## 6. Performance concepts

| Concept | Implementation |
|---|---|
| Micro-partitions and pruning (Query Profile) | [09_performance.sql:31](../setup/09_performance.sql#L31) |
| Clustering keys, `SYSTEM$CLUSTERING_INFORMATION`, `SUSPEND RECLUSTER` | [09_performance.sql:20](../setup/09_performance.sql#L20) |
| Materialized view and its restrictions | [09_performance.sql:40](../setup/09_performance.sql#L40) |
| Search optimization service and its cost estimate | [09_performance.sql:63](../setup/09_performance.sql#L63) |
| Result cache, warehouse cache, metadata cache | [09_performance.sql:72](../setup/09_performance.sql#L72) |
| QUERY_HISTORY analysis | [09_performance.sql](../setup/09_performance.sql), [Platform Ops page](../streamlit/views/5_Platform_Ops.py) |

## 7. Data protection and data sharing

| Concept | Implementation |
|---|---|
| Transient vs. permanent; Fail-safe | [01_databases_schemas.sql:15](../setup/01_databases_schemas.sql#L15) |
| Time Travel `BEFORE (STATEMENT => ...)` restore | [10_protection_cloning.sql:31](../setup/10_protection_cloning.sql#L31) |
| UNDROP | [10_protection_cloning.sql:45](../setup/10_protection_cloning.sql#L45) |
| `ALTER TABLE ... SWAP WITH` | [10_protection_cloning.sql:57](../setup/10_protection_cloning.sql#L57) |
| Zero-copy clone of a database | [10_protection_cloning.sql:67](../setup/10_protection_cloning.sql#L67) |
| Secure data sharing (provider side) | [11_data_sharing.sql:12](../setup/11_data_sharing.sql#L12) |
| Reader (managed) accounts | [11_data_sharing.sql:34](../setup/11_data_sharing.sql#L34) |
