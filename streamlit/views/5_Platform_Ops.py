"""Cost, pipeline health and storage from Snowflake metadata."""
import altair as alt
import streamlit as st

import ui
from common import ACCENT, WAREHOUSES, color_scale, query

ui.page_header(
    "Operations",
    "What the platform costs, and whether its pipelines are healthy.",
    method="""
- **Credits and queries:** `SNOWFLAKE.ACCOUNT_USAGE`, which lags by up to about 3 hours.
- **Tasks, dynamic tables and storage:** `GRID_DB.INFORMATION_SCHEMA`, which is real time.
- **Skipped tasks:** a task is *skipped* when its stream has no new rows, so it uses no compute.
""")

credits = query("""SELECT DATE_TRUNC('DAY', start_time)::DATE AS day, warehouse_name, SUM(credits_used) AS credits
                   FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
                   WHERE start_time >= DATEADD(DAY, -30, CURRENT_TIMESTAMP())
                     AND warehouse_name IN ('WH_INGEST', 'WH_TRANSFORM', 'WH_BI')
                   GROUP BY 1, 2 ORDER BY 1""")
tasks = query("""SELECT name, state, scheduled_time, completed_time,
                        DATEDIFF(SECOND, query_start_time, completed_time) AS seconds, error_message
                 FROM TABLE(GRID_DB.INFORMATION_SCHEMA.TASK_HISTORY(
                     SCHEDULED_TIME_RANGE_START => DATEADD(DAY, -7, CURRENT_TIMESTAMP()), RESULT_LIMIT => 500))
                 WHERE state <> 'SCHEDULED' AND database_name = 'GRID_DB'   -- exclude Snowflake system tasks
                 ORDER BY scheduled_time DESC""")
# INFORMATION_SCHEMA.TABLES is real time (TABLE_STORAGE_METRICS can lag by hours)
storage = query("""SELECT table_schema, table_name, table_type, is_transient, bytes AS active_bytes, row_count
                   FROM GRID_DB.INFORMATION_SCHEMA.TABLES
                   WHERE table_schema <> 'INFORMATION_SCHEMA' AND bytes > 0""")
dts = query("""SELECT name, state, refresh_action, refresh_trigger, data_timestamp,
                      DATEDIFF(SECOND, refresh_start_time, refresh_end_time) AS seconds
               FROM TABLE(GRID_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(RESULT_LIMIT => 200))
               ORDER BY data_timestamp DESC""")

ran = tasks[tasks["STATE"].isin(["SUCCEEDED", "FAILED"])]
success = (ran["STATE"] == "SUCCEEDED").mean() if len(ran) else None
latest_dt = dts.drop_duplicates("NAME")
k = st.columns(4)
daily = credits.groupby("DAY")["CREDITS"].sum()
ui.kpi(k[0], "Credits, 30 days", f"{credits['CREDITS'].sum():.2f}",
       spark=daily.round(3).tolist() if len(daily) > 1 else None,
       help="Warehouse compute only. Serverless features (tasks maintenance, MV, search optimization) are billed separately.")
active = storage["ACTIVE_BYTES"].sum()
ui.kpi(k[1], "Storage", f"{active / 1024 ** 3:.2f} GB" if active >= 1024 ** 3 else f"{active / 1024 ** 2:,.0f} MB",
       note=f"{storage['ROW_COUNT'].sum() / 1e6:,.1f}M rows in {len(storage)} tables")
ui.kpi(k[2], "Task success, 7 days", f"{success:.0%}" if success is not None else "n/a",
       note=f"{len(ran)} runs, {int((tasks['STATE'] == 'SKIPPED').sum())} skipped (no new data)")
ui.kpi(k[3], "Dynamic tables", f"{len(latest_dt)}",
       note=f"{int((latest_dt['STATE'] == 'SUCCEEDED').sum())} refreshed OK on last run")

left, right = st.columns([2, 1])
with left, ui.card("Credits per day", "Stacked by warehouse"):
    if credits.empty:
        st.caption("No metering rows yet. ACCOUNT_USAGE lags by a few hours.")
    else:
        cb = alt.Chart(credits).mark_bar(size=14, stroke="white", strokeWidth=1).encode(
            x=alt.X("DAY:T", title=None, axis=alt.Axis(format="%b %d")),
            y=alt.Y("CREDITS:Q", title=None, stack=True),
            color=alt.Color("WAREHOUSE_NAME:N", scale=color_scale(WAREHOUSES)),
            order=alt.Order("WAREHOUSE_NAME:N"),
            tooltip=[alt.Tooltip("DAY:T", title="Day"), alt.Tooltip("WAREHOUSE_NAME:N", title="Warehouse"),
                     alt.Tooltip("CREDITS:Q", title="Credits", format=".3f")])
        ui.chart(cb, 250)

with right, ui.card("Storage by table", "Largest 8, active MB"):
    top = storage.sort_values("ACTIVE_BYTES", ascending=False).head(8).copy()
    top["MB"] = top["ACTIVE_BYTES"] / 1024 ** 2
    top["TABLE"] = top["TABLE_SCHEMA"] + "." + top["TABLE_NAME"]
    sb = alt.Chart(top).mark_bar(size=12, color=ACCENT).encode(
        y=alt.Y("TABLE:N", sort="-x", title=None, axis=alt.Axis(labelLimit=200)),
        x=alt.X("MB:Q", title=None),
        tooltip=[alt.Tooltip("TABLE:N", title="Table"), alt.Tooltip("MB:Q", title="MB", format=",.1f")])
    ui.chart(sb, 250)

STATUS = {"SUCCEEDED": "Succeeded", "FAILED": "Failed", "SKIPPED": "Skipped", "CANCELLED": "Cancelled"}
left, right = st.columns(2)
with left, ui.card("Task runs", "RAW to STAGING task DAG, last 7 days"):
    view = tasks.assign(STATUS=tasks["STATE"].map(STATUS).fillna(tasks["STATE"]),
                        ERROR_MESSAGE=tasks["ERROR_MESSAGE"].where(tasks["STATE"] == "FAILED", ""))
    cols = ["NAME", "STATUS", "SCHEDULED_TIME", "SECONDS"] + (["ERROR_MESSAGE"] if (tasks["STATE"] == "FAILED").any() else [])
    st.dataframe(view[cols], hide_index=True,
                 use_container_width=True, height=300,
                 column_config={"NAME": "Task", "STATUS": "Status",
                                "SCHEDULED_TIME": st.column_config.DatetimeColumn("Scheduled", format="MMM D, HH:mm"),
                                "SECONDS": st.column_config.NumberColumn("Sec", format="%d"),
                                "ERROR_MESSAGE": "Error"})

with right, ui.card("Dynamic tables", "STAGING to MARTS, latest refresh of each"):
    view = latest_dt.assign(STATUS=latest_dt["STATE"].map(STATUS).fillna(latest_dt["STATE"]))
    st.dataframe(view[["NAME", "STATUS", "REFRESH_ACTION", "DATA_TIMESTAMP", "SECONDS"]], hide_index=True,
                 use_container_width=True, height=300,
                 column_config={"NAME": "Dynamic table", "STATUS": "Status", "REFRESH_ACTION": "Action",
                                "DATA_TIMESTAMP": st.column_config.DatetimeColumn("Data as of", format="MMM D, HH:mm"),
                                "SECONDS": st.column_config.NumberColumn("Sec", format="%d")})

with st.expander("Slowest queries on GRID_DB, last 7 days"):
    slow = query("""SELECT LEFT(query_text, 120) AS query, warehouse_name, ROUND(total_elapsed_time / 1000, 1) AS seconds,
                           partitions_scanned, partitions_total, percentage_scanned_from_cache AS pct_from_cache
                    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
                    WHERE database_name = 'GRID_DB' AND start_time >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
                      AND execution_status = 'SUCCESS'
                    ORDER BY total_elapsed_time DESC LIMIT 15""")
    st.dataframe(slow, hide_index=True, use_container_width=True)
ui.footer()
