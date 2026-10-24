"""Generate a synthetic distribution asset register for a fictional Ontario LDC.

"Lakeshore Hydro Distribution" is fictional. The data is shaped like a mid-sized Ontario
utility: distribution stations -> feeders -> transformers / poles, plus inspection records
(nested JSON, incl. resistograph readings), outage events and critical customers.

Hourly transformer loading is NOT generated here: Snowflake builds it from the real IESO
demand shape (see setup/05_streams_tasks.sql), keeping the upload small.

Usage:
    python ingest/generate_assets.py                     # writes data/raw/assets/
    python ingest/generate_assets.py --seed 7 --as-of 2026-10-01
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import random
import sys
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parents[1] / "data" / "raw" / "assets"

# (id, name, region, lat, lon, transformer MVA, in-service year)
SUBSTATIONS = [
    ("DS-01", "Harbour DS", "NORTH", 42.317, -83.036, 50, 1968),
    ("DS-02", "Riverside DS", "NORTH", 42.329, -82.951, 41.7, 1974),
    ("DS-03", "Maple Grove DS", "SOUTH", 42.262, -83.013, 50, 1981),
    ("DS-04", "Lakeview DS", "SOUTH", 42.231, -82.968, 33.3, 1992),
    ("DS-05", "Essex Road DS", "EAST", 42.284, -82.885, 41.7, 2003),
    ("DS-06", "Tecumseh Line DS", "EAST", 42.301, -82.842, 50, 2011),
]
FEEDERS_PER_STATION = 6
XFMRS_PER_FEEDER = (40, 60)

POLE_MOUNT_KVA = [25, 37.5, 50, 75, 100, 167]
PAD_MOUNT_KVA = [150, 300, 500, 750, 1000]
MANUFACTURERS = ["MFR_A", "MFR_B", "MFR_C", "MFR_D", "MFR_E"]
POLE_SPECIES = ["RED PINE", "WESTERN RED CEDAR", "SOUTHERN YELLOW PINE", "DOUGLAS FIR"]
POLE_TREATMENTS = ["CCA", "PENTA", "CREOSOTE"]
OUTAGE_CAUSES = [("TREE", 0.26), ("EQUIPMENT", 0.24), ("WEATHER", 0.18), ("ANIMAL", 0.14),
                 ("VEHICLE", 0.06), ("UNKNOWN", 0.12)]
CRITICAL_FACILITIES = [
    ("Lakeshore General Hospital", "HOSPITAL"), ("St. Clair Regional Hospital", "HOSPITAL"),
    ("Harbour Water Treatment Plant", "WATER"), ("East End Pumping Station", "WATER"),
    ("Riverside Long-Term Care", "LONG_TERM_CARE"), ("Maple Grove Seniors Residence", "LONG_TERM_CARE"),
    ("Fire Station 3", "EMERGENCY"), ("Fire Station 7", "EMERGENCY"), ("Police Division North", "EMERGENCY"),
    ("Lakeview Data Centre", "DATA_CENTRE"), ("Essex Road Dialysis Clinic", "HOSPITAL"),
    ("Tecumseh Wastewater Plant", "WATER"), ("Central Emergency Ops Centre", "EMERGENCY"),
    ("Harbour 911 Dispatch", "EMERGENCY"), ("South Shore Cold Storage", "INDUSTRIAL"),
]


def weighted_choice(rng: random.Random, pairs):
    r, acc = rng.random(), 0.0
    for value, weight in pairs:
        acc += weight
        if r <= acc:
            return value
    return pairs[-1][0]


def build(seed: int, as_of: dt.date) -> dict[str, list[dict]]:
    rng = random.Random(seed)
    year = as_of.year
    substations, feeders, xfmrs, poles, inspections, outages, critical = [], [], [], [], [], [], []

    for sid, name, region, lat, lon, mva, isy in SUBSTATIONS:
        substations.append(dict(substation_id=sid, substation_name=name, region=region,
                                latitude=lat, longitude=lon, transformer_mva=mva, in_service_year=isy))
        for f in range(1, FEEDERS_PER_STATION + 1):
            feeder_id = f"{sid}-F{f}"
            legacy = isy < 1985 and f <= 2                       # old 4.16 kV circuits
            construction = weighted_choice(rng, [("OH", 0.55), ("UG", 0.2), ("URD", 0.25)])
            feeders.append(dict(feeder_id=feeder_id, substation_id=sid, region=region,
                                voltage_kv=4.16 if legacy else 27.6, construction=construction,
                                length_km=round(rng.uniform(4, 22), 1)))
            feeder_customers = 0
            n_xfmr = rng.randint(*XFMRS_PER_FEEDER)
            for x in range(1, n_xfmr + 1):
                xfmr_id = f"T-{sid[3:]}{f}{x:03d}"
                pad = construction != "OH" and rng.random() < 0.65 or rng.random() < 0.08
                kva = rng.choice(PAD_MOUNT_KVA if pad else POLE_MOUNT_KVA)
                phases = 3 if pad else 1
                load_class = (weighted_choice(rng, [("COMMERCIAL", 0.55), ("INDUSTRIAL", 0.15), ("RESIDENTIAL", 0.30)])
                              if pad else weighted_choice(rng, [("RESIDENTIAL", 0.9), ("COMMERCIAL", 0.1)]))
                install_year = max(isy, min(year - 1, int(rng.triangular(1962, year - 1, 1985 if legacy else 1998))))
                # peak utilisation: lognormal around ~70 %, a tail runs hot (> 100 %)
                utilisation = min(1.6, rng.lognormvariate(math.log(0.70), 0.22))
                customers = rng.randint(4, 14) if not pad else rng.randint(1, 30)
                feeder_customers += customers
                xfmrs.append(dict(
                    xfmr_id=xfmr_id, feeder_id=feeder_id, mount="PAD" if pad else "POLE", kva=kva, phases=phases,
                    primary_kv=4.16 if legacy else 27.6, secondary_v=600 if (pad and load_class == "INDUSTRIAL") else (208 if pad else 240),
                    manufacturer=rng.choice(MANUFACTURERS), install_year=install_year,
                    expected_life_years=45 if pad else 40, load_class=load_class, customers_served=customers,
                    connected_peak_kva=round(kva * utilisation, 1),
                    latitude=round(lat + rng.uniform(-0.03, 0.03), 5), longitude=round(lon + rng.uniform(-0.04, 0.04), 5)))

                if not pad:  # pole-mounted transformer sits on a pole
                    poles.append(_pole(rng, feeder_id, xfmr_id, install_year, year, lat, lon, len(poles)))
            # spans between transformers on overhead feeders
            if construction == "OH":
                for _ in range(int(n_xfmr * rng.uniform(1.4, 2.0))):
                    poles.append(_pole(rng, feeder_id, None, None, year, lat, lon, len(poles)))
            feeders[-1]["customers"] = feeder_customers

    # inspections: one per transformer, 1-2 per pole in the last 3 years
    for x in xfmrs:
        age = year - x["install_year"]
        cond = _condition(rng, age, x["expected_life_years"])
        inspections.append(dict(
            inspection_id=f"INS-{len(inspections) + 1:06d}", asset_id=x["xfmr_id"], asset_type="TRANSFORMER",
            inspected_at=_random_date(rng, as_of, 3 * 365).isoformat(), inspector=f"INSP-{rng.randint(1, 12):02d}",
            condition_score=cond,
            findings=_findings(rng, cond, ["OIL_LEAK", "TANK_RUST", "BUSHING_CRACK", "GROUND_DISCONNECTED", "VEGETATION"]),
            thermal={"hotspot_delta_c": round(max(0.0, rng.gauss(6 + (5 - cond) * 4, 4)), 1)}))
    for p in poles:
        for _ in range(rng.choice([1, 1, 2])):
            age = year - p["install_year"]
            cond = _condition(rng, age, 50)
            strength = max(35.0, min(100.0, rng.gauss(100 - age * 0.5, 8)))
            inspections.append(dict(
                inspection_id=f"INS-{len(inspections) + 1:06d}", asset_id=p["pole_id"], asset_type="POLE",
                inspected_at=_random_date(rng, as_of, 3 * 365).isoformat(), inspector=f"INSP-{rng.randint(1, 12):02d}",
                condition_score=cond,
                findings=_findings(rng, cond, ["WOODPECKER", "SHELL_ROT", "CHECKING", "LEANING", "INSECT", "VEGETATION"]),
                resistograph={"remaining_strength_pct": round(strength, 1),
                              "depth_readings_mm": [round(max(0, rng.gauss(110 - age * 0.6, 12))) for _ in range(4)]}))

    # outage events over the last 12 months
    xfmr_by_feeder: dict[str, list[dict]] = {}
    for x in xfmrs:
        xfmr_by_feeder.setdefault(x["feeder_id"], []).append(x)
    for i in range(1, 451):
        fd = rng.choice(feeders)
        planned = rng.random() < 0.1
        feeder_level = rng.random() < 0.18          # breaker lockout vs. single transformer
        x = None if feeder_level else rng.choice(xfmr_by_feeder[fd["feeder_id"]])
        start = dt.datetime.combine(_random_date(rng, as_of, 365), dt.time(rng.randint(0, 23), rng.randint(0, 59)))
        minutes = max(5, int(rng.lognormvariate(math.log(95), 0.8)))
        outages.append(dict(
            outage_id=f"OUT-{i:05d}", feeder_id=fd["feeder_id"], xfmr_id=x["xfmr_id"] if x else "",
            start_ts=start.isoformat(sep=" "), end_ts=(start + dt.timedelta(minutes=minutes)).isoformat(sep=" "),
            cause="PLANNED" if planned else weighted_choice(rng, OUTAGE_CAUSES), is_planned=planned,
            customers_interrupted=fd["customers"] if feeder_level else x["customers_served"]))

    # critical customers on pad-mounted (commercial / industrial) transformers
    pads = [x for x in xfmrs if x["mount"] == "PAD"]
    for i, (fac, ftype) in enumerate(CRITICAL_FACILITIES, start=1):
        x = rng.choice(pads)
        fd = next(f for f in feeders if f["feeder_id"] == x["feeder_id"])
        critical.append(dict(customer_id=f"CC-{i:03d}", customer_name=fac, facility_type=ftype,
                             xfmr_id=x["xfmr_id"], feeder_id=x["feeder_id"], region=fd["region"],
                             contact_phone=f"519-555-{rng.randint(100, 199):04d}",
                             backup_generation=rng.random() < 0.6))

    return dict(substations=substations, feeders=feeders, transformers=xfmrs, poles=poles,
                inspections=inspections, outage_events=outages, critical_customers=critical)


def _pole(rng, feeder_id, xfmr_id, xfmr_year, year, lat, lon, n):
    install = xfmr_year if xfmr_year else int(rng.triangular(1958, year - 1, 1988))
    height = rng.choice([35, 40, 40, 45, 45, 50, 55])
    return dict(pole_id=f"P-{n + 1:06d}", feeder_id=feeder_id, xfmr_id=xfmr_id or "", height_ft=height,
                pole_class=rng.choice([2, 3, 3, 4, 4, 5]), species=rng.choice(POLE_SPECIES),
                treatment=rng.choice(POLE_TREATMENTS), install_year=install,
                latitude=round(lat + rng.uniform(-0.03, 0.03), 5), longitude=round(lon + rng.uniform(-0.04, 0.04), 5))


def _condition(rng, age, life) -> int:
    """1 = very poor ... 5 = very good, worsening with age."""
    return int(max(1, min(5, round(rng.gauss(5 - 3.2 * age / life, 0.8)))))


def _findings(rng, cond, codes):
    n = max(0, int(rng.gauss(5 - cond, 0.8)))
    return [{"code": c, "severity": rng.choice(["LOW", "MEDIUM", "HIGH"] if cond <= 2 else ["LOW", "MEDIUM"])}
            for c in rng.sample(codes, min(n, len(codes)))]


def _random_date(rng, as_of: dt.date, days_back: int) -> dt.date:
    return as_of - dt.timedelta(days=rng.randint(0, days_back))


def write(tables: dict[str, list[dict]], out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, rows in tables.items():
        if name == "inspections":   # nested -> newline-delimited JSON (loaded as VARIANT)
            with open(out_dir / "inspections.json", "w", encoding="utf-8", newline="\n") as fh:
                for row in rows:
                    fh.write(json.dumps(row, separators=(",", ":")) + "\n")
            continue
        with open(out_dir / f"{name}.csv", "w", encoding="utf-8", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=list(rows[0]), lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--as-of", type=dt.date.fromisoformat, default=dt.date.today())
    ap.add_argument("--out", type=Path, default=OUT_DIR)
    args = ap.parse_args()

    tables = build(args.seed, args.as_of)
    write(tables, args.out)
    for name, rows in tables.items():
        print(f"  {name:<20} {len(rows):>6} rows")
    print(f"written to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
