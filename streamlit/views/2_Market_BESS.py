"""Day-ahead Ontario Zonal Price, interchange, and battery arbitrage."""
import altair as alt
import pandas as pd
import streamlit as st

import ui
from common import ACCENT, DIVERGING, query, session

ui.page_header(
    "Market & storage",
    "Day-ahead prices, interchange with neighbours, and what a battery would earn on arbitrage.",
    method="""
- **Prices:** the day-ahead Ontario Zonal Price in $/MWh, published since Market Renewal (May 2025).
  IESO keeps about 90 days of daily files, and history accumulates as the pipeline runs.
- **Interchange:** actual flow per intertie. Positive values are net exports from Ontario.
- **BESS simulator:** a Snowpark procedure, run on the day-ahead prices, one cycle per day. For each
  day it searches every split hour, charges in the cheapest hours before it and discharges in the
  priciest hours after it. Losses come from the round-trip efficiency. It counts energy arbitrage only,
  with no capacity or ancillary revenue.
""")

start, end, p_start, p_end = ui.period_filter("market_period", default="60D", options=("30D", "60D", "90D"))
hourly = query("""SELECT delivery_date, delivery_hour, zonal_price FROM GRID_DB.MARTS.V_GRID_HOURLY
                  WHERE delivery_date BETWEEN ? AND ? AND zonal_price IS NOT NULL""", (p_start, end))
hourly["DELIVERY_DATE"] = pd.to_datetime(hourly["DELIVERY_DATE"])
cur = hourly[hourly["DELIVERY_DATE"] >= pd.Timestamp(start)]
prev = hourly[hourly["DELIVERY_DATE"] < pd.Timestamp(start)]
if cur.empty:
    st.info("No day-ahead prices in this period yet.")
    st.stop()

daily = cur.groupby("DELIVERY_DATE")["ZONAL_PRICE"].agg(["min", "mean", "max"]).reset_index()
daily["SPREAD"] = daily["max"] - daily["min"]
prev_spread = prev.groupby("DELIVERY_DATE")["ZONAL_PRICE"].agg(lambda s: s.max() - s.min())
flows = query("""SELECT interface, SUM(flow_mw) AS net_mwh, SUM(import_mw) AS imp_mwh, SUM(export_mw) AS exp_mwh
                 FROM GRID_DB.STAGING.INTERTIE_HOURLY
                 WHERE delivery_date BETWEEN ? AND ? GROUP BY interface""", (start, end))
total_net = float(flows.loc[flows["INTERFACE"] == "TOTAL", "NET_MWH"].sum())

k = st.columns(4)
ui.kpi(k[0], "Average price", f"${cur['ZONAL_PRICE'].mean():,.2f}/MWh",
       ui.fmt_delta(cur["ZONAL_PRICE"].mean(), prev["ZONAL_PRICE"].mean() if len(prev) else None),
       spark=daily["mean"].round(2).tolist(), delta_color="inverse")
ui.kpi(k[1], "Highest hour", f"${cur['ZONAL_PRICE'].max():,.0f}/MWh",
       help=f"{cur.loc[cur['ZONAL_PRICE'].idxmax(), 'DELIVERY_DATE']:%b %d}, "
            f"HE{int(cur.loc[cur['ZONAL_PRICE'].idxmax(), 'DELIVERY_HOUR'])}")
ui.kpi(k[2], "Avg daily spread", f"${daily['SPREAD'].mean():,.0f}/MWh",
       ui.fmt_delta(daily["SPREAD"].mean(), prev_spread.mean() if len(prev_spread) else None),
       spark=daily["SPREAD"].round(1).tolist(), help="Daily max minus min hourly price: the arbitrage opportunity.")
ui.kpi(k[3], "Net exports", f"{total_net / 1e6:,.2f} TWh", help="All interties, actual flow over the period.")

# --- price range + duration curve -----------------------------------------------------
top_decile = cur["ZONAL_PRICE"].quantile(0.9)
left, right = st.columns([2, 1])
with left, ui.card("Daily price", "Line is the daily average, band is the daily min to max, $/MWh"):
    x = alt.X("DELIVERY_DATE:T", title=None, axis=alt.Axis(format="%b %d", labelOverlap=True))
    band = alt.Chart(daily).mark_area(opacity=0.16, color=ACCENT).encode(x=x, y=alt.Y("min:Q", title=None), y2="max:Q")
    line = alt.Chart(daily).mark_line(color=ACCENT).encode(
        x=x, y="mean:Q",
        tooltip=[alt.Tooltip("DELIVERY_DATE:T", title="Date"), alt.Tooltip("mean:Q", title="Avg", format="$.2f"),
                 alt.Tooltip("min:Q", title="Min", format="$.2f"), alt.Tooltip("max:Q", title="Max", format="$.2f")])
    ui.chart(band + line, 270)

with right, ui.card("Price duration", f"10% of hours cleared above ${top_decile:,.0f}/MWh"):
    pdc = cur.sort_values("ZONAL_PRICE", ascending=False).reset_index(drop=True)
    pdc["EXCEEDED"] = (pdc.index + 1) / len(pdc)
    curve = alt.Chart(pdc).mark_line(color=ACCENT).encode(
        x=alt.X("EXCEEDED:Q", title="Share of hours", axis=alt.Axis(format="%", tickCount=5)),
        y=alt.Y("ZONAL_PRICE:Q", title=None),
        tooltip=[alt.Tooltip("EXCEEDED:Q", format=".0%", title="Hours above"),
                 alt.Tooltip("ZONAL_PRICE:Q", format="$.2f", title="Price")])
    ui.chart(curve, 270)

# --- price shape by hour + interchange -------------------------------------------------
shape = cur.groupby("DELIVERY_HOUR")["ZONAL_PRICE"].describe(percentiles=[0.1, 0.9]).reset_index()
cheap, dear = shape.loc[shape["mean"].idxmin()], shape.loc[shape["mean"].idxmax()]
left, right = st.columns(2)
with left, ui.card("Price by hour of day", f"Cheapest HE{int(cheap['DELIVERY_HOUR'])} (${cheap['mean']:,.0f}), "
                                           f"priciest HE{int(dear['DELIVERY_HOUR'])} (${dear['mean']:,.0f}). "
                                           "Band: 10th to 90th percentile."):
    xh = alt.X("DELIVERY_HOUR:Q", title="Hour ending (EST)", scale=alt.Scale(domain=[1, 24]),
               axis=alt.Axis(values=[1, 6, 12, 18, 24]))
    hb = alt.Chart(shape).mark_area(opacity=0.16, color=ACCENT).encode(x=xh, y=alt.Y("10%:Q", title=None), y2="90%:Q")
    hl = alt.Chart(shape).mark_line(color=ACCENT, point=alt.OverlayMarkDef(size=28, filled=True)).encode(
        x=xh, y="mean:Q",
        tooltip=[alt.Tooltip("DELIVERY_HOUR:Q", title="HE"), alt.Tooltip("mean:Q", title="Avg", format="$.2f"),
                 alt.Tooltip("10%:Q", title="P10", format="$.2f"), alt.Tooltip("90%:Q", title="P90", format="$.2f")])
    ui.chart(hb + hl, 250)


def tie_name(code: str) -> str:
    if code.startswith("PQ."):
        return f"Québec {code[3:]}"
    return {"NEW-YORK": "New York", "MANITOBA SK": "Manitoba SK"}.get(code, code.title())


ties = flows[flows["INTERFACE"] != "TOTAL"].copy()
ties["NAME"] = ties["INTERFACE"].map(tie_name)
ties["NET_GWH"] = ties["NET_MWH"] / 1000
ties = ties[ties["NET_GWH"].abs() >= 1].sort_values("NET_GWH", ascending=False)
biggest = ties.iloc[0] if len(ties) else None
with right, ui.card("Net interchange by intertie",
                    f"Largest net export: {biggest['NAME']} ({biggest['NET_GWH']:,.0f} GWh)" if biggest is not None else None):
    bars = alt.Chart(ties).mark_bar(size=12).encode(
        y=alt.Y("NAME:N", sort="-x", title=None),
        x=alt.X("NET_GWH:Q", title="GWh (negative = net import)"),
        color=alt.condition("datum.NET_GWH >= 0", alt.value(DIVERGING["pos"]), alt.value(DIVERGING["neg"])),
        tooltip=[alt.Tooltip("NAME:N", title="Intertie"), alt.Tooltip("NET_GWH:Q", title="Net GWh", format=",.0f")])
    rule = alt.Chart(pd.DataFrame({"x": [0]})).mark_rule(color="#c7cbd1").encode(x="x:Q")
    ui.chart(bars + rule, max(180, 22 * len(ties)))

# --- BESS simulator ------------------------------------------------------------------------
@st.cache_data(ttl=3600, show_spinner="Running SP_BESS_ARBITRAGE in Snowflake ...")
def simulate(power, energy, rte, start, end):
    return session().sql("CALL GRID_DB.APPS.SP_BESS_ARBITRAGE(?, ?, ?, ?, ?)",
                         params=[power, energy, rte, start, end]).to_pandas()


with ui.card("Battery arbitrage", "One daily cycle on day-ahead prices, computed by a Snowpark procedure."):
    with st.form("bess", border=False):
        f = st.columns([1, 1, 1, 1, 1, 0.8], vertical_alignment="bottom")
        power = f[0].number_input("Power (MW)", 1.0, 500.0, 50.0, step=5.0)
        energy = f[1].number_input("Energy (MWh)", 1.0, 2000.0, 200.0, step=10.0)
        rte = f[2].number_input("Round-trip efficiency", 0.70, 0.95, 0.86, step=0.01, format="%.2f")
        capex = f[3].number_input("Capex ($/kWh)", 100.0, 1500.0, 450.0, step=25.0)
        om = f[4].number_input("Fixed O&M ($/kW-yr)", 0.0, 100.0, 12.0, step=1.0)
        f[5].form_submit_button("Simulate", type="primary", use_container_width=True)

    sim = simulate(power, energy, rte, start, end)
    if sim.empty:
        st.caption("No complete price days in the period.")
    else:
        n_days = len(sim)
        annual = sim["NET_REVENUE"].sum() * 365 / n_days
        annual_net = annual - om * power * 1000
        payback = capex * energy * 1000 / annual_net if annual_net > 0 else None
        r = st.columns(4)
        ui.kpi(r[0], f"Net revenue ({n_days} days)", ui.fmt_money(sim["NET_REVENUE"].sum(), 2))
        ui.kpi(r[1], "Annualised", ui.fmt_money(annual, 2), help="Period revenue scaled to 365 days.")
        ui.kpi(r[2], "Avg buy / sell price", f"${sim['AVG_CHARGE_PRICE'].mean():,.0f} / ${sim['AVG_DISCHARGE_PRICE'].mean():,.0f}",
               help="Average charging vs discharging price, $/MWh.")
        ui.kpi(r[3], "Simple payback", f"{payback:,.0f} yrs" if payback else "never",
               help="Capex / (annualised arbitrage minus fixed O&M). Arbitrage alone rarely funds storage; "
                    "capacity and ancillary-service revenue usually make up the difference.")
        sim = sim.sort_values("DELIVERY_DATE")
        sim["CUMULATIVE"] = sim["NET_REVENUE"].cumsum()
        cum = alt.Chart(sim).mark_area(
            line={"color": ACCENT, "strokeWidth": 2},
            color=alt.Gradient(gradient="linear", x1=1, x2=1, y1=1, y2=0,
                               stops=[alt.GradientStop(color="white", offset=0),
                                      alt.GradientStop(color="#b7d3f6", offset=1)])).encode(
            x=alt.X("DELIVERY_DATE:T", title=None, axis=alt.Axis(format="%b %d", labelOverlap=True)),
            y=alt.Y("CUMULATIVE:Q", title=None, axis=alt.Axis(format="$~s")),
            tooltip=[alt.Tooltip("DELIVERY_DATE:T", title="Date"),
                     alt.Tooltip("NET_REVENUE:Q", title="Day", format="$,.0f"),
                     alt.Tooltip("CUMULATIVE:Q", title="Cumulative", format="$,.0f")])
        ui.chart(cum, 210)
        with st.expander("Daily dispatch"):
            st.dataframe(sim.drop(columns=["CUMULATIVE"]), hide_index=True, use_container_width=True,
                         column_config={
                             "DELIVERY_DATE": st.column_config.DateColumn("Date"),
                             "CHARGE_COST": st.column_config.NumberColumn("Charge cost", format="$%.0f"),
                             "DISCHARGE_REVENUE": st.column_config.NumberColumn("Discharge revenue", format="$%.0f"),
                             "NET_REVENUE": st.column_config.NumberColumn("Net", format="$%.0f"),
                             "CYCLES": st.column_config.NumberColumn("Cycles", format="%.0f"),
                             "AVG_CHARGE_PRICE": st.column_config.NumberColumn("Avg buy", format="$%.2f"),
                             "AVG_DISCHARGE_PRICE": st.column_config.NumberColumn("Avg sell", format="$%.2f"),
                             "FIRST_CHARGE_HOUR": st.column_config.NumberColumn("First charge HE"),
                             "LAST_DISCHARGE_HOUR": st.column_config.NumberColumn("Last discharge HE")})
ui.footer()
