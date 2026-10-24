"""Snowflake session, cached queries and the chart palette shared by every page."""
from __future__ import annotations

import pathlib
from decimal import Decimal

import altair as alt
import pandas as pd
import streamlit as st

# Categorical slots (fixed order, never cycled), validated for the light surface
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
SEQUENTIAL_BLUE = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]
ACCENT = SERIES[0]
DIVERGING = {"pos": "#2a78d6", "neg": "#e34948", "mid": "#d6d5d0"}
MUTED = "#9aa1ab"

# Each entity owns a slot, so a filter never repaints the survivors
FUELS = ["HYDRO", "GAS", "WIND", "SOLAR", "NUCLEAR", "BIOFUEL"]
ASSET_TYPES = ["TRANSFORMER", "POLE"]
WAREHOUSES = ["WH_INGEST", "WH_TRANSFORM", "WH_BI"]


def color_scale(domain: list[str]) -> alt.Scale:
    return alt.Scale(domain=domain, range=SERIES[: len(domain)])


@st.cache_resource
def session():
    """Active session inside Snowflake; config.toml session when run locally."""
    try:
        from snowflake.snowpark.context import get_active_session
        return get_active_session()
    except Exception:
        import tomllib
        from snowflake.snowpark import Session
        root = pathlib.Path(__file__).resolve().parents[1]
        cfg = tomllib.loads((root / "config.toml").read_text())["snowflake"]
        if "private_key_file" in cfg:   # relative to the repo, not the working directory
            cfg["private_key_file"] = str(root / cfg["private_key_file"])
        cfg.update(role="GRID_ADMIN", warehouse="WH_BI", database="GRID_DB")
        return Session.builder.configs(cfg).create()


@st.cache_data(ttl=600, show_spinner=False)
def query(sql: str, params: tuple | None = None) -> pd.DataFrame:
    df = session().sql(sql, params=list(params) if params else None).to_pandas()
    # NUMBER columns can arrive as Decimal; charts and maths want floats
    for col in df.columns[df.dtypes == object]:
        values = df[col].dropna()
        if len(values) and isinstance(values.iloc[0], Decimal):
            df[col] = df[col].astype(float)
    return df
