"""Summary: the grid this month, the market, and the asset risk position."""
import altair as alt
import pandas as pd
import streamlit as st

import ui
from common import ACCENT, FUELS, MUTED, color_scale, query

ui.page_header(
    "Ontario grid & distribution assets",
    "The provincial grid over the last 30 days, and where a distribution utility's asset risk sits.",
    method="""
- **Grid and market:** IESO public reports, loaded daily into Snowflake.
- **Assets:** Lakeshore Hydro is a fictional utility. Its asset register is synthetic, but transformer
  loading follows the real Ontario demand shape.
- **Comparisons:** deltas compare the last 30 complete days with the 30 days before.
""")

end = ui.latest_day()
grid = query("""SELECT * FROM GRID_DB.MARTS.V_GRID_DAILY
                WHERE delivery_date BETWEEN DATEADD(DAY, -59, ?) AND ? ORDER BY delivery_date""", (end, end))
cur, prev = grid.tail(30), grid.head(len(grid) - 30)
assets = query("""SELECT health_band, asset_type, COUNT(*) AS n, SUM(replacement_cost_cad) AS cost
                  FROM GRID_DB.MARTS.V_ASSET_RISK GROUP BY ALL""")
poor = assets[assets["HEALTH_BAND"].str[0].isin(["1", "2"])]
overloaded = query("SELECT COUNT_IF(peak_loading_pct > 100) AS n FROM GRID_DB.MARTS.XFMR_LOADING_SUMMARY")["N"].iloc[0]

k = st.columns(4)
ui.kpi(k[0], "Avg Ontario demand", ui.fmt_mw(cur["AVG_DEMAND_MW"].mean()),
       ui.fmt_delta(cur["AVG_DEMAND_MW"].mean(), prev["AVG_DEMAND_MW"].mean()),
       spark=cur["AVG_DEMAND_MW"].tolist(), delta_color="off", help="Daily average of hourly Ontario demand, last 30 days.")
price = cur["AVG_DA_PRICE"].dropna()
ui.kpi(k[1], "Day-ahead price", f"${price.mean():,.2f}/MWh" if len(price) else "n/a",
       ui.fmt_delta(price.mean(), prev["AVG_DA_PRICE"].mean()), spark=price.tolist(), delta_color="inverse",
       help="Average day-ahead Ontario Zonal Price.")
ui.kpi(k[2], "Non-emitting supply", f"{cur['NON_EMITTING_PCT'].mean():.1f} %",
       ui.fmt_delta(cur["NON_EMITTING_PCT"].mean(), prev["NON_EMITTING_PCT"].mean(), pct_points=True),
       spark=cur["NON_EMITTING_PCT"].tolist(), help="Nuclear + hydro + wind + solar share of transmission-connected output.")
ui.kpi(k[3], "Assets in poor health", f"{int(poor['N'].sum()):,}", note=ui.fmt_money(poor["COST"].sum()) + " to replace",
       help="Transformers and poles with a health index below 50.")

st.space("small")
c1, c2, c3 = st.columns(3)

# --- grid: one stacked bar of energy share --------------------------------------
shares = pd.DataFrame({"FUEL": FUELS, "MWH": [cur[f"{f}_MWH"].sum() for f in FUELS]})
shares["SHARE"] = shares["MWH"] / shares["MWH"].sum()
top = shares.sort_values("SHARE", ascending=False).iloc[0]
with c1, ui.card("Supply mix", "Share of energy, last 30 days"):
    bar = alt.Chart(shares).mark_bar(height=26, cornerRadius=4, stroke="white", strokeWidth=2).encode(
        x=alt.X("SHARE:Q", stack="normalize", axis=None),
        color=alt.Color("FUEL:N", scale=color_scale(FUELS), sort=FUELS,
                        legend=alt.Legend(columns=3, labelFontSize=11, labelExpr=ui.TITLE_CASE)),
        order=alt.Order("fuel_rank:Q"),
        tooltip=["FUEL:N", alt.Tooltip("SHARE:Q", format=".1%")],
    ).transform_calculate(fuel_rank=f"indexof({FUELS}, datum.FUEL)")
    ui.chart(bar, 92)
    peak = grid.loc[grid["PEAK_DEMAND_MW"].idxmax()]
    st.markdown(f"**{top['FUEL'].title()}** leads at **{top['SHARE']:.0%}**  \n"
                f"60-day peak **{ui.fmt_mw(peak['PEAK_DEMAND_MW'])}** on {peak['DELIVERY_DATE']:%b %d}")
    st.page_link("views/1_Grid_Overview.py", label="Supply & demand", icon=":material/arrow_forward:")

# --- market: daily average price -------------------------------------------------
with c2, ui.card("Day-ahead price", "Daily average and range, $/MWh"):
    p = grid.dropna(subset=["AVG_DA_PRICE"])
    band = alt.Chart(p).mark_area(opacity=0.18, color=ACCENT).encode(
        x=alt.X("DELIVERY_DATE:T", title=None, axis=alt.Axis(format="%b %d", labelOverlap=True)),
        y=alt.Y("MIN_DA_PRICE:Q", title=None), y2="MAX_DA_PRICE:Q")
    line = alt.Chart(p).mark_line(color=ACCENT).encode(
        x="DELIVERY_DATE:T", y="AVG_DA_PRICE:Q",
        tooltip=[alt.Tooltip("DELIVERY_DATE:T", title="Date"), alt.Tooltip("AVG_DA_PRICE:Q", title="Avg", format="$.2f")])
    ui.chart(band + line, 92)
    spread = (p["MAX_DA_PRICE"] - p["MIN_DA_PRICE"]).mean() if len(p) else 0
    st.markdown(ui.md(f"Average daily spread **${spread:,.0f}/MWh**  \n"
                      f"Highest hour **${p['MAX_DA_PRICE'].max():,.0f}/MWh**") if len(p) else "No prices yet")
    st.page_link("views/2_Market_BESS.py", label="Market & storage", icon=":material/arrow_forward:")

# --- assets: health bands ----------------------------------------------------------
with c3, ui.card("Asset health", "Transformers and poles by health band"):
    bands = assets.groupby("HEALTH_BAND", as_index=False)["N"].sum()
    bands["LABEL"] = bands["HEALTH_BAND"].str[4:].str.title()
    bands["POOR"] = bands["HEALTH_BAND"].str[0].isin(["1", "2"])
    hb = alt.Chart(bands).mark_bar(cornerRadiusEnd=3, size=12).encode(
        y=alt.Y("LABEL:N", sort=alt.EncodingSortField("HEALTH_BAND"), title=None),
        x=alt.X("N:Q", title=None, axis=None),
        color=alt.condition("datum.POOR", alt.value("#d03b3b"), alt.value(MUTED)),
        tooltip=[alt.Tooltip("LABEL:N", title="Band"), alt.Tooltip("N:Q", title="Assets", format=",")])
    ui.chart(hb, 92)
    very_poor = int(assets.loc[assets["HEALTH_BAND"].str[0] == "1", "N"].sum())
    st.markdown(f"**{very_poor:,}** assets very poor  \n**{int(overloaded):,}** transformers above nameplate at peak")
    st.page_link("views/3_Asset_Health.py", label="Asset health", icon=":material/arrow_forward:")

ui.footer()
