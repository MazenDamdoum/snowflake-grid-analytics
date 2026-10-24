"""Layout building blocks, number formatting and the chart theme."""
from __future__ import annotations

import datetime as dt
from contextlib import contextmanager

import altair as alt
import streamlit as st

from common import SERIES, query

INK_MUTED = "#6b7280"
GRID = "#e8eaee"

PERIODS = {"30D": 30, "60D": 60, "90D": 90, "6M": 182, "12M": 365}


# ------------------------------------------------------------------ theme ----
@alt.theme.register("grid_light", enable=True)
def _grid_light():
    return alt.theme.ThemeConfig({
        "config": {
            "background": "transparent",
            "font": "Source Sans Pro, Source Sans 3, sans-serif",
            "view": {"stroke": None},
            "padding": {"top": 6, "right": 4, "bottom": 2, "left": 2},
            "axis": {"labelColor": INK_MUTED, "titleColor": INK_MUTED, "labelFontSize": 11,
                     "titleFontSize": 11, "titleFontWeight": "normal", "domain": False,
                     "ticks": False, "gridColor": GRID, "gridDash": [2, 3], "labelPadding": 6},
            "axisX": {"grid": False},
            "legend": {"orient": "top", "title": None, "labelColor": "#374151", "labelFontSize": 11,
                       "symbolType": "circle", "symbolSize": 70, "columnPadding": 14, "padding": 0},
            "line": {"strokeWidth": 2},
            "bar": {"cornerRadiusEnd": 3},
            "range": {"category": SERIES},
            "title": {"anchor": "start", "fontSize": 12, "fontWeight": "normal", "color": INK_MUTED},
        }
    })


# Vega expression: "HYDRO" -> "Hydro" for legends / axes showing data codes
TITLE_CASE = "upper(slice(datum.label, 0, 1)) + lower(slice(datum.label, 1))"


def chart(c: alt.Chart, height: int = 260) -> None:
    """Render with our Altair theme (theme=None stops Streamlit restyling it)."""
    st.altair_chart(c.properties(height=height), use_container_width=True, theme=None)


# ------------------------------------------------------------------ layout ----
def inject_css() -> None:
    st.markdown("""
<style>
  .block-container {padding-top: 2.2rem; padding-bottom: 3rem; max-width: 1440px;}
  h1, h2 {letter-spacing: -0.015em;}
  [data-testid="stMetricLabel"] p {font-size: 0.82rem; color: #6b7280;}
  [data-testid="stMetricValue"] {font-size: 1.55rem; font-weight: 600;}
  [data-testid="stCaptionContainer"] p {color: #6b7280;}
  [data-testid="stSidebarNav"] {padding-top: 0.5rem;}
</style>""", unsafe_allow_html=True)


@st.cache_data(ttl=600, show_spinner=False)
def latest_day() -> dt.date | None:
    """Last complete IESO day (demand arrives hourly; fuel mix once the day closes)."""
    df = query("SELECT MAX(delivery_date) AS d FROM GRID_DB.MARTS.V_GRID_DAILY WHERE total_gen_mwh > 0")
    return df["D"].iloc[0] if len(df) else None


def md(text: str) -> str:
    """Escape $ so Streamlit markdown does not render it as LaTeX."""
    return text.replace("$", r"\$")


def page_header(title: str, subtitle: str, method: str | None = None) -> None:
    left, right = st.columns([4, 2], vertical_alignment="bottom")
    with left:
        st.markdown(f"## {title}")
        st.caption(md(subtitle))
    with right, st.container(horizontal=True, horizontal_alignment="right", vertical_alignment="center"):
        day = latest_day()
        if day is not None:
            stale = (dt.date.today() - day).days > 2
            st.badge(f"Data to {day:%b %d, %Y}", icon=":material/schedule:", color="orange" if stale else "green")
        if method:
            with st.popover("Method", icon=":material/info:"):
                st.markdown(md(method))
    st.space("small")


def kpi(col, label: str, value: str, delta: str | None = None, spark=None, help: str | None = None,
        delta_color: str = "normal", note: str | None = None) -> None:
    """Bordered metric. `delta` is a change (arrow, coloured by delta_color; "off" for neutral
    measures such as demand); `note` is a grey descriptive subtitle without an arrow."""
    if note is not None:
        delta, delta_color = note, "off"
    col.metric(label, value, delta, border=True, chart_data=spark, chart_type="area", help=help,
               delta_color=delta_color, delta_arrow="off" if note is not None else "auto", height="stretch")


@contextmanager
def card(title: str, takeaway: str | None = None):
    with st.container(border=True):
        st.markdown(f"**{md(title)}**")
        if takeaway:
            st.caption(md(takeaway))
        yield


def period_filter(key: str, default: str = "90D", options=("30D", "90D", "6M", "12M")):
    """Segmented period picker; returns (start, end, prev_start, prev_end) ending at the latest data day."""
    choice = st.segmented_control("Period", list(options), default=default, key=key,
                                  label_visibility="collapsed") or default
    end = latest_day()
    if end is None:
        st.info("No data yet - run the loader and the task DAG first.")
        st.stop()
    days = PERIODS[choice]
    start = end - dt.timedelta(days=days - 1)
    prev_end = start - dt.timedelta(days=1)
    return start, end, prev_end - dt.timedelta(days=days - 1), prev_end


# -------------------------------------------------------------- formatting ----
def fmt_mw(x: float) -> str:
    return f"{x / 1000:,.1f} GW" if abs(x) >= 10_000 else f"{x:,.0f} MW"


def fmt_money(x: float, digits: int = 1) -> str:
    if abs(x) >= 1e6:
        return f"${x / 1e6:,.{digits}f}M"
    if abs(x) >= 1e3:
        return f"${x / 1e3:,.0f}k"
    return f"${x:,.0f}"


def fmt_delta(now: float, before: float, unit: str = "%", pct_points: bool = False) -> str | None:
    """'+3.2 %' relative change, or '+1.4 pts' for values that are already percentages."""
    if before is None or now is None or before != before or now != now or before == 0:
        return None
    if pct_points:
        return f"{now - before:+.1f} pts"
    return f"{100 * (now - before) / abs(before):+.1f} {unit}"


def footer() -> None:
    st.caption("Ontario Grid & Asset Intelligence. IESO public reports and synthetic distribution assets "
               "(Lakeshore Hydro is fictional), built on Snowflake.")
