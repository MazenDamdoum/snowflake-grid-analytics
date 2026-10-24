# Architecture and design decisions

## Pipeline

```
fetch_ieso.py -------+
                     +--> load_to_snowflake.py (PUT changed files) --> internal stages
generate_assets.py --+

internal stages --COPY INTO--> RAW (transient) --> streams --> task DAG (MERGE) --> STAGING
STAGING --> MARTS dynamic tables --> secure views --> Streamlit / share
```

## Decisions

**RAW is a transient schema with VARCHAR / VARIANT columns.**
RAW is a landing copy of files that remain on the stage, so Fail-safe storage would only add cost.
Typing everything as VARCHAR means a malformed value never fails a load. `TRY_TO_*` handles typing in
STAGING, and data quality checks catch whatever that drops.

**Two load patterns on purpose.**
- **IESO data loads incrementally.** COPY load metadata skips files it has already loaded. A
  re-published file (the current-year files are re-issued daily) has a new checksum, so it loads again,
  and the STAGING `MERGE` de-duplicates on the natural key with `QUALIFY ROW_NUMBER()` ordered by
  `_loaded_at`.
- **Asset master data is a full refresh.** `TRUNCATE` also clears load metadata, so the same file names
  load again.

**Streams and tasks for RAW to STAGING, dynamic tables for MARTS.**
- The RAW to STAGING step needs procedural control: XML flattening, `UNPIVOT`, a 16M-row rebuild, an
  audit finalizer, and skipping runs when nothing arrived (`WHEN SYSTEM$STREAM_HAS_DATA`). Tasks fit
  that.
- The marts are pure declarative SQL, so dynamic tables manage their refresh order and lag.
  `FACT_GRID_HOURLY` uses `TARGET_LAG = DOWNSTREAM`, so it refreshes only when `FACT_GRID_DAILY` needs
  it.

**Why no Snowpipe?**
Data arrives once a day in batches from a laptop, so there is no continuous stream to justify
Snowpipe's per-file overhead. In production, the same COPY statements would sit behind
`CREATE PIPE ... AUTO_INGEST = TRUE` on an external S3 / Azure stage, fed by event notifications.

**The IESO retention window.**
IESO keeps daily files (day-ahead prices, outage snapshots) for only about 90 days. The yearly and
monthly roll-ups cover demand, fuel mix, generators and interties. Because STAGING is upserted rather
than rebuilt, the warehouse keeps price history that IESO itself no longer publishes.

**Synthetic loading derived from real demand.**
Generating 16M loading rows on a laptop and uploading them would be wasteful. The generator ships
1,800 transformer records instead, and Snowflake computes the hourly loading set server-side from the
real Ontario demand shape. `HASH()`-based noise keeps it reproducible between rebuilds.

**Governance on secure views.**
The row access policy is attached to `V_ASSET_RISK` and `V_CRITICAL_CUSTOMERS`, the objects viewers
actually query. Masking is attached to the source columns via a tag, so every downstream view inherits
it. The Streamlit app runs with owner rights, so viewers need `USAGE` on the app only.

**Cost controls.**
- 60 s auto-suspend and per-workload warehouses.
- A resource monitor at 25 credits a month.
- Tasks that are skipped when there is no new data.
- Reclustering suspended on a table that is rewritten daily in key order.
- Teardown in one script.
