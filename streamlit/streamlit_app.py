"""Entry point: page config, navigation and shared styling."""
from pathlib import Path

import streamlit as st

import ui

ASSETS = Path(__file__).parent / "assets"

st.set_page_config(page_title="Ontario Grid & Asset Intelligence", page_icon=":material/bolt:", layout="wide")
ui.inject_css()

pages = {
    "Overview": [
        st.Page("views/0_Home.py", title="Summary", icon=":material/space_dashboard:", default=True),
    ],
    "Grid": [
        st.Page("views/1_Grid_Overview.py", title="Supply & demand", icon=":material/bolt:"),
        st.Page("views/2_Market_BESS.py", title="Market & storage", icon=":material/battery_charging_full:"),
    ],
    "Distribution": [
        st.Page("views/3_Asset_Health.py", title="Asset health", icon=":material/monitor_heart:"),
        st.Page("views/4_Capital_Plan.py", title="Capital plan", icon=":material/request_quote:"),
    ],
    "Platform": [
        st.Page("views/5_Platform_Ops.py", title="Operations", icon=":material/monitoring:"),
    ],
}

st.logo(str(ASSETS / "logo.svg"), icon_image=str(ASSETS / "icon.svg"), size="large")
with st.sidebar:
    st.caption("IESO public market data and Lakeshore Hydro, a fictional distribution utility.")

st.navigation(pages).run()
