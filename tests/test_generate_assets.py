"""Generator must be deterministic and referentially consistent."""
import csv
import datetime as dt
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ingest"))
import generate_assets as ga  # noqa: E402

AS_OF = dt.date(2026, 10, 1)


def test_same_seed_same_files(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    ga.write(ga.build(42, AS_OF), a)
    ga.write(ga.build(42, AS_OF), b)
    for f in a.iterdir():
        assert f.read_bytes() == (b / f.name).read_bytes(), f.name


def test_different_seed_differs():
    assert ga.build(1, AS_OF)["transformers"] != ga.build(2, AS_OF)["transformers"]


def test_foreign_keys_and_ranges():
    t = ga.build(42, AS_OF)
    stations = {s["substation_id"] for s in t["substations"]}
    feeders = {f["feeder_id"] for f in t["feeders"]}
    xfmrs = {x["xfmr_id"] for x in t["transformers"]}
    assets = xfmrs | {p["pole_id"] for p in t["poles"]}

    assert all(f["substation_id"] in stations for f in t["feeders"])
    assert all(x["feeder_id"] in feeders for x in t["transformers"])
    assert all(p["feeder_id"] in feeders and (p["xfmr_id"] == "" or p["xfmr_id"] in xfmrs) for p in t["poles"])
    assert all(i["asset_id"] in assets for i in t["inspections"])
    assert all(c["xfmr_id"] in xfmrs for c in t["critical_customers"])
    assert len(xfmrs) == len(t["transformers"]), "duplicate transformer ids"

    assert all(1 <= i["condition_score"] <= 5 for i in t["inspections"])
    assert all(x["install_year"] <= AS_OF.year for x in t["transformers"])
    overloaded = sum(x["connected_peak_kva"] > x["kva"] for x in t["transformers"]) / len(t["transformers"])
    assert 0.02 < overloaded < 0.15, "a realistic minority of transformers should run hot"
    for o in t["outage_events"]:
        assert o["end_ts"] > o["start_ts"]
        assert AS_OF - dt.timedelta(days=366) <= dt.date.fromisoformat(o["start_ts"][:10]) <= AS_OF


def test_files_parse(tmp_path):
    ga.write(ga.build(42, AS_OF), tmp_path)
    with open(tmp_path / "transformers.csv", newline="") as fh:
        rows = list(csv.DictReader(fh))
    assert {"xfmr_id", "kva", "connected_peak_kva", "install_year"} <= set(rows[0])
    with open(tmp_path / "inspections.json") as fh:
        first = json.loads(fh.readline())
    assert first["asset_type"] in ("TRANSFORMER", "POLE") and isinstance(first["findings"], list)
