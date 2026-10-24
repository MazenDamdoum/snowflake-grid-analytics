"""Condition-based risk register for distribution transformers and poles."""
import altair as alt
import pandas as pd
import streamlit as st

import ui
from common import ACCENT, ASSET_TYPES, MUTED, color_scale, query

ui.page_header(
    "Asset health",
    "Condition, loading and risk for Lakeshore Hydro's transformers and poles.",
    method="""
- **Health index (0-100):** a Python UDF that weights four inputs:
  - age against expected life;
  - loading stress: peak % of nameplate and hours above 100%;
  - the latest inspection score;
  - for poles, resistograph remaining strength.
- **Risk:** PoF x CoF.
  - PoF is a logistic function of the health index (HI 35 gives 50%).
  - CoF is ln(1 + customers) x (1 + 2 x critical customers).
- **Reliability:** SAIDI and SAIFI per IEEE 1366, for unplanned sustained interruptions.
- **Data:** the utility is fictional and its data synthetic. Transformer loading follows the real
  Ontario demand shape.
""")

with st.container(horizontal=True, vertical_alignment="center"):
    regions = st.pills("Region", ["NORTH", "SOUTH", "EAST"], selection_mode="multi",
                       default=["NORTH", "SOUTH", "EAST"], format_func=str.title, label_visibility="collapsed")
    types = st.pills("Type", ASSET_TYPES, selection_mode="multi", default=ASSET_TYPES,
                     format_func=lambda t: t.title() + "s", label_visibility="collapsed")
if not regions or not types:
    st.info("Select at least one region and one asset type.")
    st.stop()

risk = query("SELECT * FROM GRID_DB.MARTS.V_ASSET_RISK")
risk = risk[risk["REGION"].isin(regions) & risk["ASSET_TYPE"].isin(types)].copy()
xf = risk[risk["ASSET_TYPE"] == "TRANSFORMER"]
very_poor = int((risk["HEALTH_INDEX"] < 30).sum())
overloaded = xf[xf["PEAK_LOADING_PCT"] > 100]

k = st.columns(4)
ui.kpi(k[0], "Assets", f"{len(risk):,}", note=f"{len(xf):,} transformers, {len(risk) - len(xf):,} poles")
ui.kpi(k[1], "Average health index", f"{risk['HEALTH_INDEX'].mean():.0f} / 100")
ui.kpi(k[2], "Very poor (HI < 30)", f"{very_poor:,}", note=f"{very_poor / max(len(risk), 1):.1%} of assets")
ui.kpi(k[3], "Overloaded transformers", f"{len(overloaded):,}",
       note=f"{len(overloaded) / max(len(xf), 1):.0%} exceed nameplate at peak" if len(xf) else None)

# --- risk matrix + health bands ---------------------------------------------------------
cof_hi = float(risk["COF"].quantile(0.75)) if len(risk) else 0
hot = risk[(risk["POF"] > 0.5) & (risk["COF"] >= cof_hi)]
left, right = st.columns([2, 1])
with left, ui.card("Risk matrix", f"{len(hot):,} assets in the high-risk zone (PoF above 50 %, top-quartile "
                                  f"consequence), {ui.fmt_money(hot['REPLACEMENT_COST_CAD'].sum())} to replace."):
    zone = alt.Chart(pd.DataFrame({"x": [cof_hi], "x2": [float(risk["COF"].max()) * 1.02], "y": [0.5], "y2": [1.0]})
                     ).mark_rect(color="#d03b3b", opacity=0.06).encode(x="x:Q", x2="x2:Q", y="y:Q", y2="y2:Q")
    zone_label = alt.Chart(pd.DataFrame({"x": [float(risk["COF"].max())], "y": [0.98], "t": ["High risk"]})
                           ).mark_text(align="right", baseline="top", color="#b42f2f", fontSize=11).encode(
        x="x:Q", y="y:Q", text="t:N")
    dots = alt.Chart(risk).mark_circle(size=34, opacity=0.65, stroke="white", strokeWidth=0.6).encode(
        x=alt.X("COF:Q", title="Consequence of failure (log scale)", scale=alt.Scale(type="log", nice=False)),
        y=alt.Y("POF:Q", title="Probability of failure", axis=alt.Axis(format="%")),
        color=alt.Color("ASSET_TYPE:N", scale=color_scale(ASSET_TYPES),
                        legend=alt.Legend(labelExpr="datum.label == 'POLE' ? 'Poles' : 'Transformers'")),
        tooltip=[alt.Tooltip("ASSET_ID:N", title="Asset"), alt.Tooltip("DESCRIPTION:N", title="Description"),
                 alt.Tooltip("FEEDER_ID:N", title="Feeder"), alt.Tooltip("HEALTH_INDEX:Q", title="Health", format=".0f"),
                 alt.Tooltip("POF:Q", title="PoF", format=".0%"), alt.Tooltip("CUSTOMERS_SERVED:Q", title="Customers"),
                 alt.Tooltip("CRITICAL_CUSTOMERS:Q", title="Critical"),
                 alt.Tooltip("REPLACEMENT_COST_CAD:Q", title="Replacement", format="$,.0f")])
    ui.chart(zone + dots + zone_label, 330)

with right, ui.card("Health bands", "Count of assets per band"):
    bands = risk.groupby(["HEALTH_BAND", "ASSET_TYPE"]).size().reset_index(name="N")
    bands["LABEL"] = bands["HEALTH_BAND"].str[4:].str.title()
    hb = alt.Chart(bands).mark_bar(size=18, stroke="white", strokeWidth=1).encode(
        y=alt.Y("LABEL:N", title=None, sort=alt.EncodingSortField("HEALTH_BAND")),
        x=alt.X("N:Q", title=None, stack=True),
        color=alt.Color("ASSET_TYPE:N", scale=color_scale(ASSET_TYPES), legend=None),
        order=alt.Order("ASSET_TYPE:N"),
        tooltip=[alt.Tooltip("LABEL:N", title="Band"), alt.Tooltip("ASSET_TYPE:N", title="Type"),
                 alt.Tooltip("N:Q", title="Assets", format=",")])
    ui.chart(hb, 330)

# --- overloads + reliability -----------------------------------------------------------
rel = query("""SELECT feeder_id, region, construction, MAX(customers) AS customers,
                      SUM(customer_interruptions) AS ci, SUM(customer_minutes) AS cmi
               FROM GRID_DB.MARTS.V_FEEDER_RELIABILITY
               WHERE month_start >= DATEADD(MONTH, -12, CURRENT_DATE()) GROUP BY 1, 2, 3""")
rel = rel[rel["REGION"].isin(regions)].copy()
rel["SAIDI"] = rel["CMI"] / rel["CUSTOMERS"]
saidi = rel["CMI"].sum() / max(rel["CUSTOMERS"].sum(), 1)
saifi = rel["CI"].sum() / max(rel["CUSTOMERS"].sum(), 1)

left, right = st.columns(2)
with left, ui.card("Overloaded transformers",
                   f"Worst at {overloaded['PEAK_LOADING_PCT'].max():.0f} % of nameplate." if len(overloaded) else None):
    table = overloaded.sort_values("PEAK_LOADING_PCT", ascending=False).head(12).copy()
    # "POLE 37.5 kVA 1-ph COMMERCIAL" -> "37.5 kVA pole"
    parts = table["DESCRIPTION"].str.split(" ")
    table["DESCRIPTION"] = parts.str[1] + " kVA " + parts.str[0].str.lower()
    st.dataframe(
        table[["ASSET_ID", "DESCRIPTION", "FEEDER_ID", "PEAK_LOADING_PCT", "HOURS_OVER_100"]],
        hide_index=True, use_container_width=True, height=36 * 12 + 38,
        column_config={
            "ASSET_ID": st.column_config.TextColumn("Transformer"),
            "DESCRIPTION": st.column_config.TextColumn("Rating"),
            "FEEDER_ID": st.column_config.TextColumn("Feeder"),
            "PEAK_LOADING_PCT": st.column_config.ProgressColumn("Peak loading", min_value=0, max_value=180, format="%.0f%%"),
            "HOURS_OVER_100": st.column_config.NumberColumn("Hrs > 100 %", format="%d"),
        })

with right, ui.card("Feeder reliability, 12 months", f"System SAIDI {saidi:,.0f} min, SAIFI {saifi:.2f}. "
                                                     "Worst 12 feeders by SAIDI."):
    worst = rel.sort_values("SAIDI", ascending=False).head(12)
    sb = alt.Chart(worst).mark_bar(size=12, color=ACCENT).encode(
        y=alt.Y("FEEDER_ID:N", sort="-x", title=None),
        x=alt.X("SAIDI:Q", title="Customer-minutes per customer"),
        tooltip=[alt.Tooltip("FEEDER_ID:N", title="Feeder"), alt.Tooltip("CONSTRUCTION:N", title="Construction"),
                 alt.Tooltip("CUSTOMERS:Q", title="Customers", format=","), alt.Tooltip("SAIDI:Q", format=".0f")])
    ui.chart(sb, 36 * 12 + 2)

# --- IESO transmission outages -----------------------------------------------------------
tx = query("""SELECT outage_id, equipment_name, equipment_type, voltage_kv, planned_start, planned_end,
                     priority, request_status, is_active
              FROM GRID_DB.MARTS.V_TX_OUTAGES
              WHERE planned_end >= CURRENT_TIMESTAMP()::TIMESTAMP_NTZ""")
active = tx.loc[tx["IS_ACTIVE"], "OUTAGE_ID"].nunique()
with ui.card("IESO planned transmission outages",
             f"Real IESO data: {tx['OUTAGE_ID'].nunique():,} outage requests open, {active:,} active now, "
             f"{tx.loc[tx['VOLTAGE_KV'] >= 500, 'OUTAGE_ID'].nunique():,} involving 500 kV equipment."):
    kv = tx["VOLTAGE_KV"].fillna(0).astype(int)
    labelled = tx.assign(KV=kv.where(kv > 0).astype("Int64").astype(str).replace("<NA>", "n/a") + " kV")
    labelled["KV"] = labelled["KV"].replace("n/a kV", "n/a")
    top_types = labelled["EQUIPMENT_TYPE"].value_counts().head(8).index
    by_type = (labelled[labelled["EQUIPMENT_TYPE"].isin(top_types)]
               .groupby(["EQUIPMENT_TYPE", "KV"]).size().reset_index(name="N"))
    kv_order = sorted(by_type["KV"].unique(), key=lambda s: -int(s.split()[0]) if s != "n/a" else 0)
    tb = alt.Chart(by_type).mark_bar(size=14, stroke="white", strokeWidth=1).encode(
        y=alt.Y("EQUIPMENT_TYPE:N", sort="-x", title=None),
        x=alt.X("sum(N):Q", title="Equipment items out of service (8 most common types)"),
        color=alt.Color("KV:N", sort=kv_order, scale=alt.Scale(scheme="blues", reverse=True), title=None),
        order=alt.Order("KV:N", sort="descending"),
        tooltip=[alt.Tooltip("EQUIPMENT_TYPE:N", title="Equipment"), alt.Tooltip("KV:N", title="Voltage"),
                 alt.Tooltip("N:Q", title="Items")])
    ui.chart(tb, 26 * by_type["EQUIPMENT_TYPE"].nunique() + 40)
    with st.expander("Outage list"):
        st.dataframe(tx.sort_values("PLANNED_START"), hide_index=True, use_container_width=True,
                     column_config={"VOLTAGE_KV": st.column_config.NumberColumn("kV", format="%.0f"),
                                    "IS_ACTIVE": st.column_config.CheckboxColumn("Active")})
ui.footer()
