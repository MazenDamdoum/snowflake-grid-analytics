/* =============================================================================
   06 - Engineering UDFs and Snowpark stored procedures (schema APPS)

   SnowPro Core topics: SQL UDFs vs. Python UDFs, stored procedures (owner
   rights), Snowpark DataFrames, table-returning procedures, parameter binding.
   ============================================================================= */
USE ROLE GRID_ADMIN;
USE SCHEMA GRID_DB.APPS;

-- ----------------------------------------------------------- SQL UDFs -----
CREATE OR REPLACE FUNCTION XFMR_FULL_LOAD_AMPS(kva FLOAT, kv FLOAT, phases NUMBER)
RETURNS FLOAT
COMMENT = 'Transformer full-load current (A): 3-ph I = kVA / (sqrt(3) * kV); 1-ph I = kVA / kV'
AS
$$
  IFF(phases = 3, kva / (SQRT(3) * kv), kva / kv)
$$;

CREATE OR REPLACE FUNCTION PCT_LOADING(load_kva FLOAT, nameplate_kva FLOAT)
RETURNS FLOAT
COMMENT = 'Loading as % of nameplate'
AS
$$
  100 * load_kva / NULLIF(nameplate_kva, 0)
$$;

-- Approximate voltage drop (% of nominal) for a radial feeder section:
--   VD = k * I * L * (R cos(phi) + X sin(phi)),  k = sqrt(3) for 3-ph, 2 for 1-ph
-- (the same form used for CEC / CSA C22.1 voltage-drop checks)
CREATE OR REPLACE FUNCTION VOLTAGE_DROP_PCT(
    amps FLOAT, length_m FLOAT, r_ohm_per_km FLOAT, x_ohm_per_km FLOAT,
    power_factor FLOAT, nominal_v FLOAT, phases NUMBER)
RETURNS FLOAT
COMMENT = 'Approximate % voltage drop for a cable / conductor run'
AS
$$
  100 * IFF(phases = 3, SQRT(3), 2) * amps * (length_m / 1000)
      * (r_ohm_per_km * power_factor + x_ohm_per_km * SQRT(1 - POWER(power_factor, 2)))
      / nominal_v
$$;

-- ------------------------------------------------------- Python UDF -------
-- Asset Health Index (0 = end of life, 100 = as new). Weighted condition
-- factors in the spirit of CNAIM / ISO 55000 condition-based risk; missing
-- inputs are dropped and the remaining weights re-normalised.
CREATE OR REPLACE FUNCTION ASSET_HEALTH_INDEX(
    asset_type VARCHAR, age_years FLOAT, expected_life_years FLOAT,
    peak_loading_pct FLOAT, hours_over_100 FLOAT,
    condition_score FLOAT, remaining_strength_pct FLOAT)
RETURNS FLOAT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'health_index'
COMMENT = 'Asset health index 0-100 from age, loading stress, inspection condition and pole strength'
AS
$$
def _clamp(x, lo=0.0, hi=1.0):
    return max(lo, min(hi, x))

def health_index(asset_type, age_years, expected_life_years, peak_loading_pct,
                 hours_over_100, condition_score, remaining_strength_pct):
    factors = []   # (degradation 0..1, weight)

    if age_years is not None and expected_life_years:
        factors.append((_clamp(age_years / expected_life_years / 1.5), 0.30 if asset_type == "TRANSFORMER" else 0.25))

    if condition_score is not None:   # 1 = very poor .. 5 = very good
        factors.append((_clamp((5 - condition_score) / 4), 0.30 if asset_type == "TRANSFORMER" else 0.25))

    if asset_type == "TRANSFORMER":
        if peak_loading_pct is not None:
            # insulation ageing accelerates above nameplate (IEEE C57.91 thermal model)
            stress = 0.6 * _clamp((peak_loading_pct - 80) / 70) + 0.4 * _clamp((hours_over_100 or 0) / 500)
            factors.append((stress, 0.40))
    elif remaining_strength_pct is not None:
        # wood poles are typically replaced below ~60-67 % of original strength
        factors.append((_clamp((100 - remaining_strength_pct) / 40), 0.50))

    if not factors:
        return None
    total_w = sum(w for _, w in factors)
    degradation = sum(d * w for d, w in factors) / total_w
    return round(100 * (1 - degradation), 1)
$$;

-- --------------------------------------------- BESS arbitrage simulator ----
-- One charge / discharge cycle per day on day-ahead Ontario Zonal Prices:
-- for every split hour, charge in the cheapest hours before it and discharge in
-- the most expensive hours after it; keep the best split, idle if unprofitable.
CREATE OR REPLACE PROCEDURE SP_BESS_ARBITRAGE(
    power_mw FLOAT, energy_mwh FLOAT, round_trip_eff FLOAT, start_date DATE, end_date DATE)
RETURNS TABLE (
    delivery_date DATE, charge_cost FLOAT, discharge_revenue FLOAT, net_revenue FLOAT,
    cycles FLOAT, avg_charge_price FLOAT, avg_discharge_price FLOAT,
    first_charge_hour NUMBER, last_discharge_hour NUMBER)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
COMMENT = 'Daily energy-arbitrage revenue for a battery of given MW / MWh / round-trip efficiency'
AS
$$
import math
from snowflake.snowpark.types import StructType, StructField, DateType, FloatType, LongType

SCHEMA = StructType([
    StructField("DELIVERY_DATE", DateType()), StructField("CHARGE_COST", FloatType()),
    StructField("DISCHARGE_REVENUE", FloatType()), StructField("NET_REVENUE", FloatType()),
    StructField("CYCLES", FloatType()), StructField("AVG_CHARGE_PRICE", FloatType()),
    StructField("AVG_DISCHARGE_PRICE", FloatType()), StructField("FIRST_CHARGE_HOUR", LongType()),
    StructField("LAST_DISCHARGE_HOUR", LongType()),
])

def run(session, power_mw, energy_mwh, round_trip_eff, start_date, end_date):
    rows = session.sql(
        """SELECT delivery_date, delivery_hour, zonal_price
           FROM GRID_DB.STAGING.DA_PRICE_HOURLY
           WHERE delivery_date BETWEEN ? AND ? AND zonal_price IS NOT NULL""",
        params=[start_date, end_date]).collect()

    by_day = {}
    for r in rows:
        by_day.setdefault(r["DELIVERY_DATE"], {})[int(r["DELIVERY_HOUR"])] = float(r["ZONAL_PRICE"])

    n = max(1, math.ceil(energy_mwh / power_mw))      # hours to fully charge
    mwh_per_hour = energy_mwh / n
    out = []
    for day in sorted(by_day):
        prices = by_day[day]
        if len(prices) < 24 or 2 * n > 24:
            continue
        p = [prices[h] for h in range(1, 25)]
        best = None
        for split in range(n, 24 - n + 1):
            charge = sorted(range(split), key=lambda h: p[h])[:n]
            discharge = sorted(range(split, 24), key=lambda h: -p[h])[:n]
            cost = sum(p[h] for h in charge) * mwh_per_hour
            revenue = sum(p[h] for h in discharge) * mwh_per_hour * round_trip_eff
            if best is None or revenue - cost > best[0]:
                best = (revenue - cost, cost, revenue, charge, discharge)
        net, cost, revenue, charge, discharge = best
        if net <= 0:
            out.append((day, 0.0, 0.0, 0.0, 0.0, None, None, None, None))
        else:
            out.append((day, round(cost, 2), round(revenue, 2), round(net, 2), 1.0,
                        round(sum(p[h] for h in charge) / n, 2), round(sum(p[h] for h in discharge) / n, 2),
                        min(charge) + 1, max(discharge) + 1))
    return session.create_dataframe(out, schema=SCHEMA)
$$;

-- ------------------------------------------ budget-constrained capital plan --
-- Greedy selection by risk reduced per dollar, with a must-do rule: assets in
-- very poor health that serve a critical customer go first. Each run is
-- written to MARTS.CAPITAL_PLAN_RUNS for audit (created in 07).
CREATE OR REPLACE PROCEDURE SP_CAPITAL_PLAN(budget_cad FLOAT)
RETURNS TABLE (
    plan_rank NUMBER, asset_id VARCHAR, asset_type VARCHAR, region VARCHAR, feeder_id VARCHAR,
    health_index FLOAT, risk_score FLOAT, replacement_cost_cad FLOAT, risk_reduction FLOAT,
    cumulative_cost_cad FLOAT, selection_reason VARCHAR)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
COMMENT = 'Rank replacement candidates within a capital budget'
AS
$$
import uuid
from snowflake.snowpark.types import StructType, StructField, StringType, FloatType, LongType

SCHEMA = StructType([
    StructField("PLAN_RANK", LongType()), StructField("ASSET_ID", StringType()),
    StructField("ASSET_TYPE", StringType()), StructField("REGION", StringType()),
    StructField("FEEDER_ID", StringType()), StructField("HEALTH_INDEX", FloatType()),
    StructField("RISK_SCORE", FloatType()), StructField("REPLACEMENT_COST_CAD", FloatType()),
    StructField("RISK_REDUCTION", FloatType()), StructField("CUMULATIVE_COST_CAD", FloatType()),
    StructField("SELECTION_REASON", StringType()),
])

def run(session, budget_cad):
    assets = session.table("GRID_DB.MARTS.V_ASSET_RISK").select(
        "ASSET_ID", "ASSET_TYPE", "REGION", "FEEDER_ID", "HEALTH_INDEX", "RISK_SCORE",
        "REPLACEMENT_COST_CAD", "RISK_REDUCTION", "CRITICAL_CUSTOMERS").collect()

    assets = [a for a in assets if a["HEALTH_INDEX"] is not None and (a["REPLACEMENT_COST_CAD"] or 0) > 0]
    must_do = [a for a in assets if (a["CRITICAL_CUSTOMERS"] or 0) > 0 and a["HEALTH_INDEX"] < 30]
    must_ids = {a["ASSET_ID"] for a in must_do}
    ranked = sorted((a for a in assets if a["ASSET_ID"] not in must_ids and (a["RISK_REDUCTION"] or 0) > 0),
                    key=lambda a: a["RISK_REDUCTION"] / a["REPLACEMENT_COST_CAD"], reverse=True)
    must_do.sort(key=lambda a: a["RISK_SCORE"], reverse=True)

    plan, spent = [], 0.0
    for reason, group in (("CRITICAL_CUSTOMER_POOR_HEALTH", must_do), ("RISK_PER_DOLLAR", ranked)):
        for a in group:
            cost = a["REPLACEMENT_COST_CAD"]
            if spent + cost > budget_cad:
                continue                       # skip, a cheaper asset may still fit
            spent += cost
            plan.append((len(plan) + 1, a["ASSET_ID"], a["ASSET_TYPE"], a["REGION"], a["FEEDER_ID"],
                         a["HEALTH_INDEX"], a["RISK_SCORE"], cost, a["RISK_REDUCTION"], round(spent, 2), reason))

    df = session.create_dataframe(plan, schema=SCHEMA)
    run_id = str(uuid.uuid4())
    df.select_expr(f"'{run_id}' AS RUN_ID", f"{float(budget_cad)} AS BUDGET_CAD", "CURRENT_TIMESTAMP() AS RUN_AT", "*") \
      .write.mode("append").save_as_table("GRID_DB.MARTS.CAPITAL_PLAN_RUNS", column_order="name")
    return df
$$;

SHOW USER FUNCTIONS IN SCHEMA GRID_DB.APPS;
SHOW USER PROCEDURES IN SCHEMA GRID_DB.APPS;
