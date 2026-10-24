"""Ontario supply mix, demand and carbon intensity (IESO public reports)."""
import altair as alt
import pandas as pd
import streamlit as st

import ui
from common import ACCENT, FUELS, SEQUENTIAL_BLUE, SERIES, color_scale, query

ui.page_header(
    "Supply & demand",
    "Ontario demand, generation by fuel and carbon intensity.",
    method="""
- **Sources:** IESO *Demand*, *Generator Output by Fuel Type* and *Generator Output & Capability* reports.
- **Non-emitting share:** nuclear + hydro + wind + solar, as a share of transmission-connected output.
- **Carbon intensity:** gas output times 0.40 tCO2e/MWh, divided by total output. This is an estimate.
- **Capacity factor:** output divided by capability (dispatchable units) or by available capacity (wind, solar).
- **Hours:** IESO hours are hour-ending (HE), in EST.
""")

start, end, p_start, p_end = ui.period_filter("grid_period")
days = query("""SELECT * FROM GRID_DB.MARTS.V_GRID_DAILY
                WHERE delivery_date BETWEEN ? AND ? ORDER BY delivery_date""", (p_start, end))
cur = days[pd.to_datetime(days["DELIVERY_DATE"]) >= pd.Timestamp(start)]
prev = days[pd.to_datetime(days["DELIVERY_DATE"]) < pd.Timestamp(start)]
if cur.empty:
    st.info("No data in this period.")
    st.stop()

peak = cur.loc[cur["PEAK_DEMAND_MW"].idxmax()]
k = st.columns(4)
ui.kpi(k[0], "Peak demand", ui.fmt_mw(peak["PEAK_DEMAND_MW"]),
       ui.fmt_delta(peak["PEAK_DEMAND_MW"], prev["PEAK_DEMAND_MW"].max()), spark=cur["PEAK_DEMAND_MW"].tolist(), delta_color="off",
       help=f"Highest hourly Ontario demand: {peak['DELIVERY_DATE']:%b %d}, HE{int(peak['PEAK_HOUR'])}.")
ui.kpi(k[1], "Average demand", ui.fmt_mw(cur["AVG_DEMAND_MW"].mean()),
       ui.fmt_delta(cur["AVG_DEMAND_MW"].mean(), prev["AVG_DEMAND_MW"].mean()), spark=cur["AVG_DEMAND_MW"].tolist(),
       delta_color="off")
ui.kpi(k[2], "Non-emitting share", f"{cur['NON_EMITTING_PCT'].mean():.1f} %",
       ui.fmt_delta(cur["NON_EMITTING_PCT"].mean(), prev["NON_EMITTING_PCT"].mean(), pct_points=True),
       spark=cur["NON_EMITTING_PCT"].tolist())
ui.kpi(k[3], "Carbon intensity", f"{cur['EST_CARBON_G_PER_KWH'].mean():.0f} g/kWh",
       ui.fmt_delta(cur["EST_CARBON_G_PER_KWH"].mean(), prev["EST_CARBON_G_PER_KWH"].mean()),
       spark=cur["EST_CARBON_G_PER_KWH"].tolist(), delta_color="inverse", help="Estimate, see Method.")

# --- supply mix + energy share -----------------------------------------------------
mix = cur.melt(id_vars="DELIVERY_DATE", value_vars=[f"{f}_MWH" for f in FUELS], var_name="FUEL", value_name="MWH")
mix["FUEL"] = mix["FUEL"].str.replace("_MWH", "")
mix["GWH"] = mix["MWH"] / 1000
shares = mix.groupby("FUEL", as_index=False)["MWH"].sum()
shares["SHARE"] = shares["MWH"] / shares["MWH"].sum()
prev_mwh = {f: prev[f"{f}_MWH"].sum() for f in FUELS}
prev_total = sum(prev_mwh.values()) or 1
shares["CHANGE_PTS"] = [100 * (r.SHARE - prev_mwh[r.FUEL] / prev_total) for r in shares.itertuples()]
mover = shares.loc[shares["CHANGE_PTS"].abs().idxmax()]

left, right = st.columns([2, 1])
with left, ui.card("Generation by fuel", f"GWh per day. {mover['FUEL'].title()} share "
                                          f"{'up' if mover['CHANGE_PTS'] > 0 else 'down'} "
                                          f"{abs(mover['CHANGE_PTS']):.1f} pts on the previous period."):
    area = alt.Chart(mix).mark_area(stroke="white", strokeWidth=0.6).encode(
        x=alt.X("DELIVERY_DATE:T", title=None, axis=alt.Axis(format="%b %d", labelOverlap=True)),
        y=alt.Y("GWH:Q", stack=True, title=None),
        color=alt.Color("FUEL:N", scale=color_scale(FUELS), sort=FUELS, legend=alt.Legend(labelExpr=ui.TITLE_CASE)),
        order=alt.Order("fuel_rank:Q"),
        tooltip=[alt.Tooltip("DELIVERY_DATE:T", title="Date"), alt.Tooltip("FUEL:N", title="Fuel"),
                 alt.Tooltip("GWH:Q", title="GWh", format=",.1f")],
    ).transform_calculate(fuel_rank=f"indexof({FUELS}, datum.FUEL)")
    ui.chart(area, 290)

with right, ui.card("Energy share", "Share of output in the period"):
    order = shares.sort_values("SHARE", ascending=False)["FUEL"].tolist()
    share_chart = alt.Chart(shares).mark_bar(size=16).encode(
        y=alt.Y("FUEL:N", sort=order, title=None, axis=alt.Axis(labelExpr=ui.TITLE_CASE)),
        x=alt.X("SHARE:Q", title=None, axis=alt.Axis(format="%", tickCount=4),
                scale=alt.Scale(domain=[0, float(shares["SHARE"].max()) * 1.18])),
        color=alt.Color("FUEL:N", scale=color_scale(FUELS), legend=None),
        tooltip=[alt.Tooltip("FUEL:N", title="Fuel"), alt.Tooltip("SHARE:Q", format=".1%", title="Share"),
                 alt.Tooltip("CHANGE_PTS:Q", format="+.1f", title="Change (pts)")])
    labels = share_chart.mark_text(align="left", dx=4, fontSize=11, color="#374151").encode(
        text=alt.Text("SHARE:Q", format=".0%"), color=alt.value("#374151"))
    ui.chart(share_chart + labels, 290)

# --- daily peak + demand heatmap ---------------------------------------------------
heat = query("""SELECT month_start, delivery_hour, ROUND(AVG(ontario_demand_mw)) AS avg_mw
                FROM GRID_DB.MARTS.V_GRID_HOURLY WHERE delivery_date BETWEEN ? AND ? GROUP BY 1, 2""", (start, end))
hot = heat.loc[heat["AVG_MW"].idxmax()]

left, right = st.columns(2)
with left, ui.card("Daily peak demand", f"Highest {ui.fmt_mw(peak['PEAK_DEMAND_MW'])} on "
                                        f"{peak['DELIVERY_DATE']:%a %b %d}, hour ending {int(peak['PEAK_HOUR'])}."):
    base = alt.Chart(cur).encode(x=alt.X("DELIVERY_DATE:T", title=None, axis=alt.Axis(format="%b %d", labelOverlap=True)))
    line = base.mark_line(color=ACCENT).encode(y=alt.Y("PEAK_DEMAND_MW:Q", title=None, scale=alt.Scale(zero=False),
                                                       axis=alt.Axis(format="~s")))
    hover = alt.selection_point(fields=["DELIVERY_DATE"], nearest=True, on="pointerover", empty=False)
    dots = base.mark_circle(size=60, color=ACCENT, stroke="white", strokeWidth=1.5).encode(
        y="PEAK_DEMAND_MW:Q", opacity=alt.condition(hover, alt.value(1), alt.value(0)),
        tooltip=[alt.Tooltip("DELIVERY_DATE:T", title="Date"),
                 alt.Tooltip("PEAK_DEMAND_MW:Q", title="Peak MW", format=",.0f"),
                 alt.Tooltip("PEAK_HOUR:Q", title="Hour ending")]).add_params(hover)
    top = alt.Chart(pd.DataFrame([peak])).mark_circle(size=70, color=ACCENT, stroke="white", strokeWidth=1.5).encode(
        x="DELIVERY_DATE:T", y="PEAK_DEMAND_MW:Q")
    ui.chart(line + dots + top, 250)

with right, ui.card("Demand by hour", f"Average MW. Highest around HE{int(hot['DELIVERY_HOUR'])} "
                                     f"in {pd.Timestamp(hot['MONTH_START']):%B}."):
    hm = alt.Chart(heat).mark_rect(stroke="white", strokeWidth=1, cornerRadius=2).encode(
        x=alt.X("DELIVERY_HOUR:O", title="Hour ending (EST)", axis=alt.Axis(labelAngle=0, values=[1, 6, 12, 18, 24])),
        y=alt.Y("yearmonth(MONTH_START):O", title=None, axis=alt.Axis(format="%b %Y")),
        color=alt.Color("AVG_MW:Q", title=None, scale=alt.Scale(range=SEQUENTIAL_BLUE),
                        legend=alt.Legend(orient="right", format="~s", gradientLength=140)),
        tooltip=[alt.Tooltip("yearmonth(MONTH_START):O", title="Month"), alt.Tooltip("DELIVERY_HOUR:O", title="HE"),
                 alt.Tooltip("AVG_MW:Q", title="Avg MW", format=",.0f")])
    ui.chart(hm, 250)

# --- capacity factor ------------------------------------------------------------------
with ui.card("Generator capacity factor", "Top 15 units by energy for the selected fuel."):
    fuel = st.pills("Fuel", FUELS, default="WIND", key="cf_fuel", format_func=str.title,
                    label_visibility="collapsed") or "WIND"
    gens = query("""SELECT generator, ROUND(SUM(output_mwh) / NULLIF(SUM(available_mwh), 0), 3) AS capacity_factor,
                           ROUND(SUM(output_mwh) / 1000, 1) AS output_gwh, MAX(max_capability_mw) AS capability_mw
                    FROM GRID_DB.MARTS.V_GENERATOR_DAILY
                    WHERE delivery_date BETWEEN ? AND ? AND fuel_type = ?
                    GROUP BY generator HAVING SUM(available_mwh) > 0
                    ORDER BY output_gwh DESC LIMIT 15""", (start, end, fuel))
    if gens.empty:
        st.caption("No units of this fuel reported in the period.")
    else:
        cf = alt.Chart(gens).mark_bar(size=12, color=SERIES[FUELS.index(fuel)]).encode(
            y=alt.Y("GENERATOR:N", sort="-x", title=None),
            x=alt.X("CAPACITY_FACTOR:Q", title=None, axis=alt.Axis(format="%", tickCount=5),
                    scale=alt.Scale(domain=[0, min(1.0, float(gens["CAPACITY_FACTOR"].max()) * 1.15)])),
            tooltip=[alt.Tooltip("GENERATOR:N", title="Unit"), alt.Tooltip("CAPACITY_FACTOR:Q", format=".1%", title="CF"),
                     alt.Tooltip("OUTPUT_GWH:Q", title="Output GWh"), alt.Tooltip("CAPABILITY_MW:Q", title="Max MW")])
        cf_labels = cf.mark_text(align="left", dx=4, fontSize=11).encode(
            text=alt.Text("CAPACITY_FACTOR:Q", format=".0%"), color=alt.value("#374151"))
        ui.chart(cf + cf_labels, 24 * len(gens) + 20)

with st.expander("Daily data"):
    st.dataframe(cur, hide_index=True, use_container_width=True)
ui.footer()
