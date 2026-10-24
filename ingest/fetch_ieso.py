"""Download public IESO market reports into data/raw/ieso/<report>/.

IESO publishes long-history roll-ups (yearly / monthly files) but keeps daily files for
only ~90 days. This script pulls both kinds for a rolling window. Re-running it only
downloads what is new or still changing (current year / month / day), so the warehouse
accumulates history past IESO's own retention window.

Usage:
    python ingest/fetch_ieso.py                 # last 12 months
    python ingest/fetch_ieso.py --months 1      # quick smoke test
"""
from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE_URL = "https://reports-public.ieso.ca/public"
RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw" / "ieso"
USER_AGENT = "ontario-grid-intelligence/1.0 (portfolio project; public IESO reports)"

# report directory -> (granularity, file extension)
REPORTS = {
    "Demand": ("year", "csv"),                      # hourly Ontario + market demand
    "GenOutputbyFuelHourly": ("year", "xml"),       # hourly output by fuel type
    "IntertieScheduleFlowYear": ("year", "csv"),    # hourly imports / exports by intertie
    "GenOutputCapabilityMonth": ("month", "csv"),   # hourly output + capability per generator
    "DAHourlyOntarioZonalPrice": ("day", "xml"),    # day-ahead Ontario zonal price (post Market Renewal)
    "TxOutages1to30DaysPlanned": ("latest", "xml"), # planned transmission outages snapshot
}


def http_get(url: str, retries: int = 3) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read()
        except urllib.error.URLError as exc:
            if attempt == retries:
                raise
            print(f"  retry {attempt} for {url}: {exc}", file=sys.stderr)
            time.sleep(2 * attempt)
    raise RuntimeError("unreachable")


def list_report_files(report: str) -> list[str]:
    """File names in an IESO report directory, excluding superseded _vN revisions."""
    html = http_get(f"{BASE_URL}/{report}/").decode("utf-8", errors="replace")
    names = set(re.findall(r'href="(PUB_[^"]+)"', html))
    return sorted(n for n in names if not re.search(r"_v\d+\.", n))


def wanted_files(report: str, granularity: str, ext: str, start: dt.date, today: dt.date,
                 latest_days: int) -> list[str]:
    available = list_report_files(report)
    prefix = f"PUB_{report}_"
    if granularity == "year":
        keys = {str(y) for y in range(start.year, today.year + 1)}
    elif granularity == "month":
        keys, cur = set(), start.replace(day=1)
        while cur <= today:
            keys.add(cur.strftime("%Y%m"))
            cur = (cur.replace(day=28) + dt.timedelta(days=4)).replace(day=1)
    elif granularity == "day":
        keys = None  # anything dated inside the window
    else:  # latest
        dated = [n for n in available if re.fullmatch(rf"{prefix}\d{{8}}\.{ext}", n)]
        return dated[-latest_days:]

    picked = []
    for name in available:
        m = re.fullmatch(rf"{prefix}(\d+)\.{ext}", name)
        if not m:
            continue
        key = m.group(1)
        if keys is not None and key in keys:
            picked.append(name)
        # day-ahead files for tomorrow are published today
        elif keys is None and len(key) == 8 and start <= dt.datetime.strptime(key, "%Y%m%d").date() <= today + dt.timedelta(days=1):
            picked.append(name)
    return picked


def is_still_changing(name: str, today: dt.date) -> bool:
    """Current-period files are re-published by IESO as the period fills in."""
    key = re.search(r"_(\d+)\.\w+$", name).group(1)
    return key in {str(today.year), today.strftime("%Y%m"), today.strftime("%Y%m%d")}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--months", type=int, default=12, help="rolling window length (default 12)")
    ap.add_argument("--outage-days", type=int, default=7, help="daily Tx outage snapshots to keep (default 7)")
    ap.add_argument("--reports", nargs="*", default=list(REPORTS), help="subset of report names")
    args = ap.parse_args()

    today = dt.date.today()
    month_index = today.year * 12 + (today.month - 1) - (args.months - 1)
    start = dt.date(month_index // 12, month_index % 12 + 1, 1)
    print(f"IESO window: {start} .. {today}")

    for report in args.reports:
        granularity, ext = REPORTS[report]
        out_dir = RAW_DIR / report
        out_dir.mkdir(parents=True, exist_ok=True)
        names = wanted_files(report, granularity, ext, start, today, args.outage_days)
        fetched = skipped = 0
        for name in names:
            dest = out_dir / name
            if dest.exists() and not is_still_changing(name, today):
                skipped += 1
                continue
            dest.write_bytes(http_get(f"{BASE_URL}/{report}/{name}"))
            fetched += 1
            time.sleep(0.2)  # be polite to the public endpoint
        print(f"  {report:<28} {fetched:>4} downloaded, {skipped:>4} already current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
