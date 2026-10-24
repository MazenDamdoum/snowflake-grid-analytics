"""Budget-constrained replacement plan from the risk register."""
import altair as alt
import pandas as pd
import streamlit as st

import ui
from common import ACCENT, ASSET_TYPES, color_scale, query, session

ui.page_header(
    "Capital plan",
    "Which replacements remove the most risk for a given annual budget.",
    method="""
- **Engine:** the Snowpark procedure `SP_CAPITAL_PLAN`.
- **Must-do assets:** assets serving critical customers with a health index below 30 are selected first.
- **Everything else:** assets are picked greedily by risk removed per dollar until the budget is spent.
- **Risk removed:** (PoF - 2 %) x CoF, because a new asset still carries about 2 % PoF.
- **Costs:** indicative installed costs in CAD.
- **Audit:** every run is written to `MARTS.CAPITAL_PLAN_RUNS`.
""")

BUDGETS = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15]
budget_m = st.select_slider("Annual replacement budget", BUDGETS, value=4, format_func=lambda b: f"${b}M")


@st.cache_data(ttl=3600, show_spinner="Running SP_CAPITAL_PLAN in Snowflake ...")
def plan_for(budget_cad: float) -> pd.DataFrame:
    return session().sql("CALL GRID_DB.APPS.SP_CAPITAL_PLAN(?)", params=[budget_cad]).to_pandas()


plan = plan_for(budget_m * 1e6)
frontier = plan_for(max(BUDGETS) * 1e6)
total_risk = float(query("SELECT SUM(risk_score) AS r FROM GRID_DB.MARTS.V_ASSET_RISK")["R"].iloc[0])
if plan.empty:
    st.warning("The budget is too small for any replacement.")
    st.stop()

spend = plan["REPLACEMENT_COST_CAD"].sum()
removed = plan["RISK_REDUCTION"].sum()
must = int((plan["SELECTION_REASON"] != "RISK_PER_DOLLAR").sum())
k = st.columns(4)
ui.kpi(k[0], "Assets replaced", f"{len(plan):,}",
       note=f"{(plan['ASSET_TYPE'] == 'POLE').sum():,} poles, {(plan['ASSET_TYPE'] == 'TRANSFORMER').sum():,} transformers")
ui.kpi(k[1], "Spend", ui.fmt_money(spend, 2), note=f"of ${budget_m}M budget")
ui.kpi(k[2], "Portfolio risk removed", f"{100 * removed / total_risk:.1f} %",
       help="Sum of risk removed / total risk across all assets.")
ui.kpi(k[3], "Must-do (critical customers)", f"{must}",
       note="none below HI 30 at critical sites" if must == 0 else None)

left, right = st.columns([2, 1])
frontier["CUM_RISK"] = frontier["RISK_REDUCTION"].cumsum() / total_risk
at_budget = frontier.loc[frontier["CUMULATIVE_COST_CAD"] <= budget_m * 1e6, "CUM_RISK"].max()
with left, ui.card("Risk removed vs. spend",
                   f"${budget_m}M removes {100 * removed / total_risk:.0f} % of portfolio risk; "
                   f"${max(BUDGETS)}M would remove {100 * frontier['CUM_RISK'].iloc[-1]:.0f} %."):
    curve = alt.Chart(frontier).mark_line(color=ACCENT, interpolate="step-after").encode(
        x=alt.X("CUMULATIVE_COST_CAD:Q", title=None, axis=alt.Axis(format="$~s")),
        y=alt.Y("CUM_RISK:Q", title=None, axis=alt.Axis(format="%")),
        tooltip=[alt.Tooltip("PLAN_RANK:Q", title="Rank"), alt.Tooltip("ASSET_ID:N", title="Asset"),
                 alt.Tooltip("CUMULATIVE_COST_CAD:Q", title="Cumulative spend", format="$,.0f"),
                 alt.Tooltip("CUM_RISK:Q", title="Risk removed", format=".1%")])
    marker = pd.DataFrame({"x": [budget_m * 1e6], "y": [at_budget], "t": [f"${budget_m}M"]})
    rule = alt.Chart(marker).mark_rule(color="#9aa1ab", strokeDash=[4, 3]).encode(x="x:Q")
    dot = alt.Chart(marker).mark_circle(size=70, color=ACCENT, stroke="white", strokeWidth=1.5).encode(x="x:Q", y="y:Q")
    label = alt.Chart(marker).mark_text(align="left", dx=6, dy=-8, fontSize=11, color="#374151").encode(
        x="x:Q", y="y:Q", text="t:N")
    ui.chart(curve + rule + dot + label, 290)

with right, ui.card("Spend by region", "Replacement cost in the plan"):
    by = plan.groupby(["REGION", "ASSET_TYPE"], as_index=False)["REPLACEMENT_COST_CAD"].sum()
    bars = alt.Chart(by).mark_bar(size=34, stroke="white", strokeWidth=1).encode(
        x=alt.X("REGION:N", title=None, axis=alt.Axis(labelAngle=0, labelExpr="upper(slice(datum.label,0,1)) + lower(slice(datum.label,1))")),
        y=alt.Y("REPLACEMENT_COST_CAD:Q", title=None, stack=True, axis=alt.Axis(format="$~s")),
        color=alt.Color("ASSET_TYPE:N", scale=color_scale(ASSET_TYPES),
                        legend=alt.Legend(labelExpr="datum.label == 'POLE' ? 'Poles' : 'Transformers'")),
        order=alt.Order("ASSET_TYPE:N"),
        tooltip=[alt.Tooltip("REGION:N", title="Region"), alt.Tooltip("ASSET_TYPE:N", title="Type"),
                 alt.Tooltip("REPLACEMENT_COST_CAD:Q", title="Spend", format="$,.0f")])
    ui.chart(bars, 290)

with ui.card("Replacement list", f"{len(plan):,} assets in priority order"):
    shown = plan.assign(ASSET_TYPE=plan["ASSET_TYPE"].str.title(), REGION=plan["REGION"].str.title(),
                        REPLACEMENT_COST_CAD=plan["REPLACEMENT_COST_CAD"].map("${:,.0f}".format),
                        CUMULATIVE_COST_CAD=plan["CUMULATIVE_COST_CAD"].map("${:,.0f}".format))
    st.dataframe(
        shown[["PLAN_RANK", "ASSET_ID", "ASSET_TYPE", "REGION", "FEEDER_ID", "HEALTH_INDEX",
               "RISK_REDUCTION", "REPLACEMENT_COST_CAD", "CUMULATIVE_COST_CAD"]],
        hide_index=True, use_container_width=True, height=360,
        column_config={
            "PLAN_RANK": st.column_config.NumberColumn("#", format="%d", width="small"),
            "ASSET_ID": st.column_config.TextColumn("Asset"),
            "ASSET_TYPE": st.column_config.TextColumn("Type"),
            "REGION": st.column_config.TextColumn("Region"),
            "FEEDER_ID": st.column_config.TextColumn("Feeder"),
            "HEALTH_INDEX": st.column_config.ProgressColumn("Health", min_value=0, max_value=100, format="%.0f"),
            "RISK_REDUCTION": st.column_config.NumberColumn("Risk removed", format="%.2f"),
            "REPLACEMENT_COST_CAD": st.column_config.TextColumn("Cost"),
            "CUMULATIVE_COST_CAD": st.column_config.TextColumn("Cumulative"),
        })
    st.download_button("Download CSV", plan.to_csv(index=False), file_name=f"capital_plan_{budget_m}M.csv",
                       mime="text/csv", icon=":material/download:")
ui.footer()
