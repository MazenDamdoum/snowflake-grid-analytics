"""Upload local files to Snowflake stages and run the setup / pipeline SQL.

First run (empty account, builds everything in dependency order):
    python ingest/load_to_snowflake.py --all

Daily refresh (after fetch_ieso.py): upload changed files, COPY, run the task
DAG, wait for it, refresh the dynamic tables:
    python ingest/load_to_snowflake.py

Individual steps:
    --setup       setup/00-03   roles, warehouses, database, stages, RAW tables
    --load        PUT changed files + setup/04 COPY INTO
    --run-tasks   EXECUTE TASK T_ROOT and wait for the DAG to finish
    --refresh     ALTER DYNAMIC TABLE ... REFRESH on the marts
    --build       setup/07-09, 11, upload Streamlit files, 12
    --sql FILE    run one SQL file

Connection settings come from config.toml (see config.example.toml).
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import sys
import time
import tomllib
from pathlib import Path

import snowflake.connector
from snowflake.connector.util_text import split_statements

ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup"
DATA = ROOT / "data" / "raw"
MANIFEST = ROOT / "data" / ".upload_manifest.json"

# local folder -> stage location
UPLOADS = [
    (DATA / "ieso", "@GRID_DB.RAW.IESO_STAGE", True),     # subfolder per report
    (DATA / "assets", "@GRID_DB.RAW.ASSET_STAGE", False),
]
STREAMLIT_DIR = ROOT / "streamlit"
STREAMLIT_STAGE = "@GRID_DB.APPS.STREAMLIT_STAGE/app"
MART_DTS = ["FACT_GRID_DAILY", "FACT_GENERATOR_DAILY", "ASSET_RISK", "FEEDER_RELIABILITY_MONTHLY"]


def connect():
    cfg_path = ROOT / "config.toml"
    if not cfg_path.exists():
        sys.exit("config.toml not found - copy config.example.toml and fill it in")
    cfg = tomllib.loads(cfg_path.read_text())["snowflake"]
    if "private_key_file" in cfg:
        cfg["private_key_file"] = str(ROOT / cfg["private_key_file"])
    return snowflake.connector.connect(**cfg, session_parameters={"QUERY_TAG": "grid-intelligence-loader"})


def run_sql_file(conn, path: Path) -> None:
    """Run statements one by one (progress as it goes, comment-only chunks skipped)."""
    print(f"\n== {path.name}")
    cur = conn.cursor()
    text = path.read_text(encoding="utf-8")
    for stmt, _ in split_statements(io.StringIO(text), remove_comments=False):
        sql_only = re.sub(r"/\*.*?\*/|--[^\n]*", "", stmt, flags=re.S).strip()
        if not sql_only:
            continue
        cur.execute(stmt)
        print(f"   ok  {' '.join(sql_only.split())[:90]}")
        if sql_only.upper().startswith("COPY INTO"):
            for row in cur.fetchall():
                if len(row) > 3 and row[1] not in ("LOAD_SKIPPED",):
                    print(f"         {row[1]:<14} rows={row[3]:<8} {str(row[0]).rsplit('/', 1)[-1]}")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def put(cur, local: Path, stage_path: str, compress: bool = True) -> None:
    uri = "file://" + local.resolve().as_posix()
    cur.execute(f"PUT '{uri}' '{stage_path}' AUTO_COMPRESS={str(compress).upper()} OVERWRITE=TRUE")


def upload_data(conn) -> None:
    """PUT only files whose content changed since the last upload."""
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    cur = conn.cursor()
    uploaded = 0
    for local_root, stage, per_folder in UPLOADS:
        if not local_root.exists():
            print(f"   (skip {local_root} - run the fetch / generate scripts first)")
            continue
        for f in sorted(p for p in local_root.rglob("*") if p.is_file()):
            key = f.relative_to(DATA).as_posix()
            digest = sha256(f)
            if manifest.get(key) == digest:
                continue
            target = f"{stage}/{f.parent.name}/" if per_folder else f"{stage}/"
            put(cur, f, target)
            manifest[key] = digest
            uploaded += 1
    MANIFEST.write_text(json.dumps(manifest, indent=1))
    print(f"   uploaded {uploaded} changed file(s)")


def upload_streamlit(conn) -> None:
    cur = conn.cursor()
    cur.execute(f"REMOVE {STREAMLIT_STAGE}/")     # drop stale files (e.g. renamed pages)
    for f in sorted(STREAMLIT_DIR.rglob("*")):
        if f.is_file() and "__pycache__" not in f.parts:
            sub = f.parent.relative_to(STREAMLIT_DIR).as_posix()
            target = STREAMLIT_STAGE + ("/" + sub if sub != "." else "") + "/"
            put(cur, f, target, compress=False)
    print("   streamlit files uploaded")


def run_tasks(conn, timeout_s: int = 1800) -> None:
    cur = conn.cursor()
    started = cur.execute("SELECT CURRENT_TIMESTAMP()").fetchone()[0]
    cur.execute("EXECUTE TASK GRID_DB.STAGING.T_ROOT")
    print("   task DAG started, waiting for the finalizer ...")
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        time.sleep(15)
        done = cur.execute(
            """SELECT state FROM TABLE(GRID_DB.INFORMATION_SCHEMA.TASK_HISTORY(
                   TASK_NAME => 'T_FINALIZE', SCHEDULED_TIME_RANGE_START => %s::TIMESTAMP_LTZ))
               WHERE state IN ('SUCCEEDED', 'FAILED', 'CANCELLED')""", (started,)).fetchall()
        if done:
            break
    else:
        print("   timed out waiting; check TASK_HISTORY in Snowsight")
        return
    for name, state, err in cur.execute(
            """SELECT name, state, error_message FROM TABLE(GRID_DB.INFORMATION_SCHEMA.TASK_HISTORY(
                   SCHEDULED_TIME_RANGE_START => %s::TIMESTAMP_LTZ))
               WHERE database_name = 'GRID_DB' ORDER BY scheduled_time""", (started,)).fetchall():
        print(f"   {name:<24} {state:<10} {err or ''}")


def refresh_marts(conn) -> None:
    cur = conn.cursor()
    cur.execute("USE ROLE GRID_ADMIN")
    for dt in MART_DTS:     # a manual refresh also refreshes upstream dynamic tables
        cur.execute(f"ALTER DYNAMIC TABLE GRID_DB.MARTS.{dt} REFRESH")
        print(f"   refreshed MARTS.{dt}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for flag in ("all", "setup", "load", "run-tasks", "refresh", "build"):
        ap.add_argument(f"--{flag}", action="store_true")
    ap.add_argument("--sql", type=Path, help="run a single SQL file")
    args = ap.parse_args()

    conn = connect()
    try:
        if args.sql:
            run_sql_file(conn, args.sql)
            return 0
        if args.all:
            for name in ("00_account_setup", "01_databases_schemas", "02_file_formats_stages", "03_raw_tables"):
                run_sql_file(conn, SETUP / f"{name}.sql")
            upload_data(conn)
            for name in ("04_copy_into", "05_streams_tasks", "06_udfs_procs"):
                run_sql_file(conn, SETUP / f"{name}.sql")
            run_tasks(conn)
            # dynamic tables initialise on create, so build marts after STAGING has data
            for name in ("07_marts_dynamic_tables", "08_governance", "09_performance", "11_data_sharing"):
                run_sql_file(conn, SETUP / f"{name}.sql")
            upload_streamlit(conn)
            run_sql_file(conn, SETUP / "12_streamlit.sql")
            return 0

        default_refresh = not any((args.setup, args.load, args.run_tasks, args.refresh, args.build))
        if args.setup:
            for name in ("00_account_setup", "01_databases_schemas", "02_file_formats_stages", "03_raw_tables"):
                run_sql_file(conn, SETUP / f"{name}.sql")
        if args.load or default_refresh:
            upload_data(conn)
            run_sql_file(conn, SETUP / "04_copy_into.sql")
        if args.run_tasks or default_refresh:
            run_tasks(conn)
        if args.refresh or default_refresh:
            refresh_marts(conn)
        if args.build:
            for name in ("05_streams_tasks", "06_udfs_procs", "07_marts_dynamic_tables",
                         "08_governance", "09_performance", "11_data_sharing"):
                run_sql_file(conn, SETUP / f"{name}.sql")
            upload_streamlit(conn)
            run_sql_file(conn, SETUP / "12_streamlit.sql")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
