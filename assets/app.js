/* Public copy of the "Ontario Grid & Asset Intelligence" Streamlit in Snowflake app.
   Every page mirrors streamlit/views/*.py: same SQL results (exported from Snowflake), same Altair
   charts as Vega-Lite specs, and the two Snowpark procedures ported line for line to JavaScript. */
"use strict";

// ---------------------------------------------------------------- palette (common.py)
const SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"];
const SEQUENTIAL_BLUE = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"];
const ACCENT = SERIES[0];
const DIVERGING = { pos: "#2a78d6", neg: "#e34948" };
const MUTED = "#9aa1ab";
const INK_MUTED = "#6b7280";
const GRID = "#e8eaee";
const FUELS = ["HYDRO", "GAS", "WIND", "SOLAR", "NUCLEAR", "BIOFUEL"];
const ASSET_TYPES = ["TRANSFORMER", "POLE"];
const WAREHOUSES = ["WH_INGEST", "WH_TRANSFORM", "WH_BI"];
const PERIODS = { "30D": 30, "60D": 60, "90D": 90, "6M": 182, "12M": 365 };
const TITLE_CASE = "upper(slice(datum.label, 0, 1)) + lower(slice(datum.label, 1))";
const TYPE_LABEL = "datum.label == 'POLE' ? 'Poles' : 'Transformers'";

// ---------------------------------------------------------------- chart theme (ui.py)
const VL_CONFIG = {
  background: "transparent",
  font: "Source Sans 3, Source Sans Pro, sans-serif",
  view: { stroke: null },
  padding: { top: 6, right: 4, bottom: 2, left: 2 },
  axis: { labelColor: INK_MUTED, titleColor: INK_MUTED, labelFontSize: 11, titleFontSize: 11, titleFontWeight: "normal",
          domain: false, ticks: false, gridColor: GRID, gridDash: [2, 3], labelPadding: 6 },
  axisX: { grid: false },
  legend: { orient: "top", labelColor: "#374151", labelFontSize: 11, symbolType: "circle", symbolSize: 70,
            columnPadding: 14, padding: 0 },
  line: { strokeWidth: 2 },
  bar: { cornerRadiusEnd: 3 },
  range: { category: SERIES },
  title: { anchor: "start", fontSize: 12, fontWeight: "normal", color: INK_MUTED },
};

// ---------------------------------------------------------------- data
const D = {};
const state = {
  grid_period: "90D", market_period: "60D", cf_fuel: "WIND",
  regions: ["NORTH", "SOUTH", "EAST"], types: ["TRANSFORMER", "POLE"], budget: 4,
  bess: { power: 50, energy: 200, rte: 0.86, capex: 450, om: 12 },
};

function rows(cols) {
  const keys = Object.keys(cols || {});
  const n = keys.length ? cols[keys[0]].length : 0;
  const out = new Array(n);
  for (let i = 0; i < n; i++) { const o = {}; for (const k of keys) o[k] = cols[k][i]; out[i] = o; }
  return out;
}

async function loadData() {
  const names = ["meta", "daily", "hourly", "capacity_factor", "flows", "assets", "reliability", "tx_outages", "ops"];
  await Promise.all(names.map(async (n) => { D[n] = await (await fetch(`data/${n}.json`)).json(); }));
  D.L = D.meta.latest_day;
  D.dailyRows = rows(D.daily);
  D.hourlyRows = rows(D.hourly).map((r) => ({ d: r.D, h: r.H, mw: r.MW, p: r.P }));
  D.assetRows = rows(D.assets);
  D.relRows = rows(D.reliability);
  D.txRows = rows(D.tx_outages);
}

// ---------------------------------------------------------------- dates + maths
const addDays = (iso, n) => { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const utc = (iso) => new Date(iso.length === 10 ? iso + "T00:00:00Z" : iso + "Z");
const fmtDay = (iso, opt) => utc(iso).toLocaleDateString("en-US", { timeZone: "UTC", ...opt });
const local = (iso) => iso + "T00:00:00";            // Vega parses this in local time, so labels keep the day
const monthStart = (iso) => iso.slice(0, 7) + "-01";

function periodWindow(choice) {
  const days = PERIODS[choice], end = D.L;
  const start = addDays(end, -(days - 1)), prevEnd = addDays(start, -1);
  return { start, end, pStart: addDays(prevEnd, -(days - 1)) };
}
const nums = (a) => a.filter((v) => v !== null && v !== undefined && !Number.isNaN(v));
const sum = (a) => nums(a).reduce((s, v) => s + v, 0);
const mean = (a) => { const v = nums(a); return v.length ? sum(v) / v.length : NaN; };
const max = (a) => Math.max(...nums(a));
function quantile(a, q) {            // pandas default: linear interpolation
  const v = nums(a).slice().sort((x, y) => x - y);
  if (!v.length) return NaN;
  const pos = (v.length - 1) * q, lo = Math.floor(pos), hi = Math.ceil(pos);
  return v[lo] + (v[hi] - v[lo]) * (pos - lo);
}
const groupBy = (arr, keyFn) => { const m = new Map(); for (const r of arr) { const k = keyFn(r); if (!m.has(k)) m.set(k, []); m.get(k).push(r); } return m; };
const argmax = (arr, f) => arr.reduce((best, r) => (best === null || f(r) > f(best) ? r : best), null);
const argmin = (arr, f) => arr.reduce((best, r) => (best === null || f(r) < f(best) ? r : best), null);
const title = (s) => s.toLowerCase().replace(/(^|[^a-z])([a-z])/g, (m, a, b) => a + b.toUpperCase());

// ---------------------------------------------------------------- formatting (ui.py)
const fx = (x, d = 0) => x.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const signed = (x, d) => (x >= 0 ? "+" : "-") + Math.abs(x).toFixed(d);
const fmtMW = (x) => (Math.abs(x) >= 10000 ? `${fx(x / 1000, 1)} GW` : `${fx(x)} MW`);
function fmtMoney(x, d = 1) {
  if (Math.abs(x) >= 1e6) return `$${fx(x / 1e6, d)}M`;
  if (Math.abs(x) >= 1e3) return `$${fx(x / 1e3)}k`;
  return `$${fx(x)}`;
}
function fmtDelta(now, before, unit = "%", pts = false) {
  if (before === null || before === undefined || now === null || Number.isNaN(before) || Number.isNaN(now) || before === 0) return null;
  return pts ? `${signed(now - before, 1)} pts` : `${signed((100 * (now - before)) / Math.abs(before), 1)} ${unit}`;
}
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const md = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>").replace(/`(.+?)`/g, "<code>$1</code>")
  .replace(/\*(.+?)\*/g, "<em>$1</em>").replace(/ {2}\n/g, "<br>");

// ---------------------------------------------------------------- DOM helpers
function h(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "class") e.className = v;
    else if (k === "html") e.innerHTML = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined && v !== false) e.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat()) {
    if (kid === null || kid === undefined || kid === false) continue;
    e.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return e;
}
const icon = (name, attrs = {}) => h("span", { class: "icon", "aria-hidden": "true", ...attrs }, name);

let pending = [];
function chart(parent, spec, height) {
  const div = h("div", { class: "chart" });
  parent.append(div);
  pending.push([div, {
    $schema: "https://vega.github.io/schema/vega-lite/v5.json",
    width: "container", height, autosize: { type: "fit", contains: "padding" }, config: VL_CONFIG, ...spec,
  }]);
}
function flushCharts() {
  const jobs = pending; pending = [];
  for (const [div, spec] of jobs) vegaEmbed(div, spec, { actions: false, renderer: "svg" }).catch((e) => console.error(e, spec));
}

function pageHeader(root, titleText, subtitle, method) {
  const pop = h("div", { class: "popover", role: "dialog" }, h("ul", {}, method.map((m) => h("li", { html: md(m) }))));
  const btn = h("button", { class: "btn", type: "button", "aria-expanded": "false",
    onclick: (ev) => { ev.stopPropagation(); const open = pop.classList.toggle("open"); btn.setAttribute("aria-expanded", open); } },
    icon("info"), "Method", icon("expand_more"));
  document.addEventListener("click", (ev) => { if (!pop.contains(ev.target)) pop.classList.remove("open"); });
  root.append(h("div", { class: "page-head" },
    h("div", {}, h("h2", {}, titleText), h("p", { class: "caption" }, subtitle)),
    h("div", { class: "head-right" },
      h("span", { class: "badge", title: "Snowflake snapshot; the live app refreshes daily" }, icon("schedule"),
        `Data to ${fmtDay(D.L, { month: "short", day: "2-digit", year: "numeric" })}`),
      btn, pop)));
}

function spark(values, tone) {
  const v = nums(values);
  if (v.length < 2) return null;
  const lo = Math.min(...v), hi = Math.max(...v), span = hi - lo || 1;
  const W = 300, H = 50, y = (x) => H - ((x - (lo - span * 0.9)) / (span * 2.0)) * H;
  const pts = v.map((x, i) => [(i / (v.length - 1)) * W, y(x)]);
  const line = pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join("");
  const colors = { good: ["#21c354", "rgba(33,195,84,.13)"], bad: ["#ff4b4b", "rgba(255,75,75,.13)"], off: ["#a3a8b4", "rgba(163,168,180,.25)"] }[tone];
  const svg = `<svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-hidden="true">
    <path d="${line}L${W},${H}L0,${H}Z" fill="${colors[1]}"/>
    <path d="${line}" fill="none" stroke="${colors[0]}" stroke-width="1.6" vector-effect="non-scaling-stroke"/></svg>`;
  return h("div", { html: svg }).firstChild;
}

function kpi(parent, { label, value, delta = null, deltaColor = "normal", sparkData = null, help = null, note = null }) {
  let tone = "off", chip = null;
  if (note !== null) {
    chip = h("span", { class: "delta off" }, note);
  } else if (delta) {
    const up = !delta.trim().startsWith("-");
    tone = deltaColor === "off" ? "off" : (up === (deltaColor === "normal") ? "good" : "bad");
    chip = h("span", { class: `delta ${tone}` }, icon(up ? "arrow_upward" : "arrow_downward"), delta);
  }
  parent.append(h("div", { class: "kpi" },
    h("div", { class: "label" }, label, help ? icon("help", { title: help, role: "img", "aria-label": help }) : null),
    h("div", { class: "value" }, value), chip,
    sparkData ? spark(sparkData, tone) : h("div", { class: "pad" })));
}

function card(parent, titleText, takeaway = null, extraClass = "") {
  const c = h("div", { class: `card ${extraClass}` }, h("div", { class: "title" }, titleText),
    takeaway ? h("p", { class: "caption", html: md(takeaway) }) : null);
  parent.append(c);
  return c;
}
const row = (parent, cls) => { const r = h("div", { class: `row ${cls}` }); parent.append(r); return r; };
const pageLink = (to, label) => h("a", { class: "link", href: `#/${to}` }, icon("arrow_forward"), label);
const footer = (root) => root.append(h("p", { class: "foot" },
  "Ontario Grid & Asset Intelligence. IESO public reports and synthetic distribution assets (Lakeshore Hydro is fictional), built on Snowflake."));

function segmented(options, value, onChange) {
  return h("div", { class: "seg", role: "group" }, options.map((o) =>
    h("button", { type: "button", class: o === value ? "on" : "", "aria-pressed": o === value, onclick: () => onChange(o) }, o)));
}
function pills(options, selected, onToggle, fmt = (x) => x) {
  return h("div", { class: "pills", role: "group" }, options.map((o) =>
    h("button", { type: "button", class: `pill ${selected.includes(o) ? "on" : ""}`, "aria-pressed": selected.includes(o),
      onclick: () => onToggle(o) }, fmt(o))));
}

function table(parent, columns, data, height = null) {
  const wrap = h("div", { class: "table-wrap", style: height ? `max-height:${height}px` : null });
  const head = h("tr", {}, columns.map((c) => h("th", { class: c.num ? "num" : "" }, c.label)));
  const body = data.map((r) => h("tr", {}, columns.map((c) => {
    const v = r[c.key];
    if (c.bar) {
      const pct = Math.max(0, Math.min(1, (v - c.bar[0]) / (c.bar[1] - c.bar[0])));
      return h("td", {}, h("div", { class: "bar-cell" }, h("div", { class: "track" },
        h("div", { class: "fill", style: `width:${(pct * 100).toFixed(1)}%` })), c.fmt ? c.fmt(v) : v));
    }
    return h("td", { class: c.num ? "num" : "" }, v === null || v === undefined ? "" : (c.fmt ? c.fmt(v) : v));
  })));
  wrap.append(h("table", {}, h("thead", {}, head), h("tbody", {}, body)));
  parent.append(wrap);
}
const expander = (parent, label) => { const d = h("details", {}, h("summary", {}, label)); parent.append(d); return d; };

// ================================================================ Summary (0_Home.py)
function pageSummary(root) {
  pageHeader(root, "Ontario grid & distribution assets",
    "The provincial grid over the last 30 days, and where a distribution utility's asset risk sits.", [
      "**Grid and market:** IESO public reports, loaded daily into Snowflake.",
      "**Assets:** Lakeshore Hydro is a fictional utility. Its asset register is synthetic, but transformer loading follows the real Ontario demand shape.",
      "**Comparisons:** deltas compare the last 30 complete days with the 30 days before.",
    ]);
  const end = D.L;
  const grid = D.dailyRows.filter((r) => r.DELIVERY_DATE >= addDays(end, -59) && r.DELIVERY_DATE <= end);
  const cur = grid.slice(-30), prev = grid.slice(0, grid.length - 30);
  const poor = D.assetRows.filter((a) => "12".includes(a.HEALTH_BAND[0]));

  const k = row(root, "r4");
  const col = (rs, c) => rs.map((r) => r[c]);
  kpi(k, { label: "Avg Ontario demand", value: fmtMW(mean(col(cur, "AVG_DEMAND_MW"))),
    delta: fmtDelta(mean(col(cur, "AVG_DEMAND_MW")), mean(col(prev, "AVG_DEMAND_MW"))), deltaColor: "off",
    sparkData: col(cur, "AVG_DEMAND_MW"), help: "Daily average of hourly Ontario demand, last 30 days." });
  const price = nums(col(cur, "AVG_DA_PRICE"));
  kpi(k, { label: "Day-ahead price", value: price.length ? `$${fx(mean(price), 2)}/MWh` : "n/a",
    delta: fmtDelta(mean(price), mean(col(prev, "AVG_DA_PRICE"))), deltaColor: "inverse", sparkData: price,
    help: "Average day-ahead Ontario Zonal Price." });
  kpi(k, { label: "Non-emitting supply", value: `${mean(col(cur, "NON_EMITTING_PCT")).toFixed(1)} %`,
    delta: fmtDelta(mean(col(cur, "NON_EMITTING_PCT")), mean(col(prev, "NON_EMITTING_PCT")), "%", true),
    sparkData: col(cur, "NON_EMITTING_PCT"), help: "Nuclear + hydro + wind + solar share of transmission-connected output." });
  kpi(k, { label: "Assets in poor health", value: fx(poor.length), note: `${fmtMoney(sum(col(poor, "REPLACEMENT_COST_CAD")))} to replace`,
    help: "Transformers and poles with a health index below 50." });

  const c = row(root, "r3");
  const shares = FUELS.map((f) => ({ FUEL: f, MWH: sum(col(cur, `${f}_MWH`)) }));
  const tot = sum(shares.map((s) => s.MWH));
  shares.forEach((s) => { s.SHARE = s.MWH / tot; });
  const top = argmax(shares, (s) => s.SHARE);
  const peak = argmax(grid, (r) => r.PEAK_DEMAND_MW);
  const c1 = card(c, "Supply mix", "Share of energy, last 30 days");
  chart(c1, {
    data: { values: shares },
    transform: [{ calculate: `indexof(${JSON.stringify(FUELS)}, datum.FUEL)`, as: "fuel_rank" }],
    mark: { type: "bar", height: 26, cornerRadius: 4, stroke: "white", strokeWidth: 2 },
    encoding: {
      x: { field: "SHARE", type: "quantitative", stack: "normalize", axis: null },
      color: { field: "FUEL", type: "nominal", scale: { domain: FUELS, range: SERIES.slice(0, 6) }, sort: FUELS,
               legend: { columns: 3, labelFontSize: 11, labelExpr: TITLE_CASE, title: null } },
      order: { field: "fuel_rank", type: "quantitative" },
      tooltip: [{ field: "FUEL", type: "nominal", title: "Fuel" }, { field: "SHARE", type: "quantitative", format: ".1%", title: "Share" }],
    },
  }, 92);
  c1.append(h("p", { class: "stat", html: md(`**${title(top.FUEL)}** leads at **${Math.round(top.SHARE * 100)}%**  \n60-day peak **${fmtMW(peak.PEAK_DEMAND_MW)}** on ${fmtDay(peak.DELIVERY_DATE, { month: "short", day: "2-digit" })}`) }),
    pageLink("supply", "Supply & demand"));

  const p = grid.filter((r) => r.AVG_DA_PRICE !== null).map((r) => ({ ...r, DATE: local(r.DELIVERY_DATE) }));
  const c2 = card(c, "Day-ahead price", "Daily average and range, $/MWh");
  chart(c2, { data: { values: p }, layer: [
    { mark: { type: "area", opacity: 0.18, color: ACCENT }, encoding: {
      x: { field: "DATE", type: "temporal", title: null, axis: { format: "%b %d", labelOverlap: true } },
      y: { field: "MIN_DA_PRICE", type: "quantitative", title: null }, y2: { field: "MAX_DA_PRICE" } } },
    { mark: { type: "line", color: ACCENT }, encoding: {
      x: { field: "DATE", type: "temporal" }, y: { field: "AVG_DA_PRICE", type: "quantitative" },
      tooltip: [{ field: "DATE", type: "temporal", title: "Date" }, { field: "AVG_DA_PRICE", type: "quantitative", title: "Avg", format: "$.2f" }] } },
  ] }, 92);
  const spread = mean(p.map((r) => r.MAX_DA_PRICE - r.MIN_DA_PRICE));
  c2.append(h("p", { class: "stat", html: md(`Average daily spread **$${fx(spread)}/MWh**  \nHighest hour **$${fx(max(col(p, "MAX_DA_PRICE")))}/MWh**`) }),
    pageLink("market", "Market & storage"));

  const c3 = card(c, "Asset health", "Transformers and poles by health band");
  const bands = [...groupBy(D.assetRows, (a) => a.HEALTH_BAND)].map(([b, rs]) => ({
    HEALTH_BAND: b, RANK: +b[0], LABEL: title(b.slice(4)), POOR: "12".includes(b[0]), N: rs.length }));
  chart(c3, { data: { values: bands }, mark: { type: "bar", cornerRadiusEnd: 3, size: 12 }, encoding: {
    y: { field: "LABEL", type: "nominal", sort: { field: "RANK", op: "min" }, title: null },
    x: { field: "N", type: "quantitative", title: null, axis: null },
    color: { condition: { test: "datum.POOR", value: "#d03b3b" }, value: MUTED },
    tooltip: [{ field: "LABEL", type: "nominal", title: "Band" }, { field: "N", type: "quantitative", title: "Assets", format: "," }] } }, 92);
  const veryPoor = D.assetRows.filter((a) => a.HEALTH_BAND[0] === "1").length;
  c3.append(h("p", { class: "stat", html: md(`**${fx(veryPoor)}** assets very poor  \n**${fx(D.meta.overloaded_xfmr)}** transformers above nameplate at peak`) }),
    pageLink("assets", "Asset health"));
  footer(root);
}

// ================================================================ Supply & demand (1_Grid_Overview.py)
function pageSupply(root) {
  pageHeader(root, "Supply & demand", "Ontario demand, generation by fuel and carbon intensity.", [
    "**Sources:** IESO *Demand*, *Generator Output by Fuel Type* and *Generator Output & Capability* reports.",
    "**Non-emitting share:** nuclear + hydro + wind + solar, as a share of transmission-connected output.",
    "**Carbon intensity:** gas output times 0.40 tCO2e/MWh, divided by total output. This is an estimate.",
    "**Capacity factor:** output divided by capability (dispatchable units) or by available capacity (wind, solar).",
    "**Hours:** IESO hours are hour-ending (HE), in EST.",
  ]);
  root.append(h("div", { class: "controls" }, segmented(["30D", "90D", "6M", "12M"], state.grid_period, (v) => { state.grid_period = v; render(); })));
  const { start, end, pStart } = periodWindow(state.grid_period);
  const days = D.dailyRows.filter((r) => r.DELIVERY_DATE >= pStart && r.DELIVERY_DATE <= end);
  const cur = days.filter((r) => r.DELIVERY_DATE >= start), prev = days.filter((r) => r.DELIVERY_DATE < start);
  const col = (rs, c) => rs.map((r) => r[c]);
  const peak = argmax(cur, (r) => r.PEAK_DEMAND_MW);

  const k = row(root, "r4");
  kpi(k, { label: "Peak demand", value: fmtMW(peak.PEAK_DEMAND_MW), delta: fmtDelta(peak.PEAK_DEMAND_MW, prev.length ? max(col(prev, "PEAK_DEMAND_MW")) : null),
    sparkData: col(cur, "PEAK_DEMAND_MW"), deltaColor: "off",
    help: `Highest hourly Ontario demand: ${fmtDay(peak.DELIVERY_DATE, { month: "short", day: "2-digit" })}, HE${peak.PEAK_HOUR}.` });
  kpi(k, { label: "Average demand", value: fmtMW(mean(col(cur, "AVG_DEMAND_MW"))),
    delta: fmtDelta(mean(col(cur, "AVG_DEMAND_MW")), mean(col(prev, "AVG_DEMAND_MW"))), sparkData: col(cur, "AVG_DEMAND_MW"), deltaColor: "off" });
  kpi(k, { label: "Non-emitting share", value: `${mean(col(cur, "NON_EMITTING_PCT")).toFixed(1)} %`,
    delta: fmtDelta(mean(col(cur, "NON_EMITTING_PCT")), mean(col(prev, "NON_EMITTING_PCT")), "%", true), sparkData: col(cur, "NON_EMITTING_PCT") });
  kpi(k, { label: "Carbon intensity", value: `${fx(mean(col(cur, "EST_CARBON_G_PER_KWH")))} g/kWh`,
    delta: fmtDelta(mean(col(cur, "EST_CARBON_G_PER_KWH")), mean(col(prev, "EST_CARBON_G_PER_KWH"))),
    sparkData: col(cur, "EST_CARBON_G_PER_KWH"), deltaColor: "inverse", help: "Estimate, see Method." });

  const mix = cur.flatMap((r) => FUELS.map((f) => ({ DATE: local(r.DELIVERY_DATE), FUEL: f, GWH: (r[`${f}_MWH`] || 0) / 1000 })));
  const tot = sum(mix.map((m) => m.GWH));
  const prevMwh = Object.fromEntries(FUELS.map((f) => [f, sum(col(prev, `${f}_MWH`))]));
  const prevTot = sum(Object.values(prevMwh)) || 1;
  const shares = FUELS.slice().sort().map((f) => {
    const share = sum(mix.filter((m) => m.FUEL === f).map((m) => m.GWH)) / tot;
    return { FUEL: f, SHARE: share, CHANGE_PTS: 100 * (share - prevMwh[f] / prevTot) };
  });
  const mover = argmax(shares, (s) => Math.abs(s.CHANGE_PTS));

  let r = row(root, "r21");
  const left = card(r, "Generation by fuel", `GWh per day. ${title(mover.FUEL)} share ${mover.CHANGE_PTS > 0 ? "up" : "down"} ${Math.abs(mover.CHANGE_PTS).toFixed(1)} pts on the previous period.`);
  chart(left, { data: { values: mix },
    transform: [{ calculate: `indexof(${JSON.stringify(FUELS)}, datum.FUEL)`, as: "fuel_rank" }],
    mark: { type: "area", stroke: "white", strokeWidth: 0.6 }, encoding: {
      x: { field: "DATE", type: "temporal", title: null, axis: { format: "%b %d", labelOverlap: true } },
      y: { field: "GWH", type: "quantitative", stack: true, title: null },
      color: { field: "FUEL", type: "nominal", scale: { domain: FUELS, range: SERIES.slice(0, 6) }, sort: FUELS, legend: { labelExpr: TITLE_CASE, title: null } },
      order: { field: "fuel_rank", type: "quantitative" },
      tooltip: [{ field: "DATE", type: "temporal", title: "Date" }, { field: "FUEL", type: "nominal", title: "Fuel" },
                { field: "GWH", type: "quantitative", title: "GWh", format: ",.1f" }] } }, 290);
  const right = card(r, "Energy share", "Share of output in the period");
  const order = shares.slice().sort((a, b) => b.SHARE - a.SHARE).map((s) => s.FUEL);
  const enc = {
    y: { field: "FUEL", type: "nominal", sort: order, title: null, axis: { labelExpr: TITLE_CASE } },
    x: { field: "SHARE", type: "quantitative", title: null, axis: { format: "%", tickCount: 4 }, scale: { domain: [0, max(shares.map((s) => s.SHARE)) * 1.18] } },
  };
  chart(right, { data: { values: shares }, layer: [
    { mark: { type: "bar", size: 16 }, encoding: { ...enc, color: { field: "FUEL", type: "nominal", scale: { domain: FUELS, range: SERIES.slice(0, 6) }, legend: null },
      tooltip: [{ field: "FUEL", type: "nominal", title: "Fuel" }, { field: "SHARE", type: "quantitative", format: ".1%", title: "Share" },
                { field: "CHANGE_PTS", type: "quantitative", format: "+.1f", title: "Change (pts)" }] } },
    { mark: { type: "text", align: "left", dx: 4, fontSize: 11, color: "#374151" }, encoding: { ...enc, text: { field: "SHARE", type: "quantitative", format: ".0%" } } },
  ] }, 290);

  const hrs = D.hourlyRows.filter((x) => x.d >= start && x.d <= end && x.mw !== null);
  const heat = [...groupBy(hrs, (x) => `${monthStart(x.d)}|${x.h}`)].map(([key, rs]) => {
    const [m, hr] = key.split("|");
    return { MONTH: local(m), DELIVERY_HOUR: +hr, AVG_MW: Math.round(mean(rs.map((x) => x.mw))) };
  });
  const hot = argmax(heat, (x) => x.AVG_MW);
  r = row(root, "r2");
  const pk = card(r, "Daily peak demand", `Highest ${fmtMW(peak.PEAK_DEMAND_MW)} on ${fmtDay(peak.DELIVERY_DATE, { weekday: "short", month: "short", day: "2-digit" }).replace(",", "")}, hour ending ${peak.PEAK_HOUR}.`);
  const curD = cur.map((x) => ({ ...x, DATE: local(x.DELIVERY_DATE) }));
  const xd = { field: "DATE", type: "temporal", title: null, axis: { format: "%b %d", labelOverlap: true } };
  chart(pk, { layer: [
    { data: { values: curD }, mark: { type: "line", color: ACCENT }, encoding: { x: xd,
      y: { field: "PEAK_DEMAND_MW", type: "quantitative", title: null, scale: { zero: false }, axis: { format: "~s" } } } },
    { data: { values: curD }, params: [{ name: "hover", select: { type: "point", fields: ["DATE"], nearest: true, on: "pointerover", clear: "pointerout" } }],
      mark: { type: "circle", size: 60, color: ACCENT, stroke: "white", strokeWidth: 1.5 }, encoding: { x: xd,
      y: { field: "PEAK_DEMAND_MW", type: "quantitative" }, opacity: { condition: { param: "hover", empty: false, value: 1 }, value: 0 },
      tooltip: [{ field: "DATE", type: "temporal", title: "Date" }, { field: "PEAK_DEMAND_MW", type: "quantitative", title: "Peak MW", format: ",.0f" },
                { field: "PEAK_HOUR", type: "quantitative", title: "Hour ending" }] } },
    { data: { values: [{ DATE: local(peak.DELIVERY_DATE), PEAK_DEMAND_MW: peak.PEAK_DEMAND_MW }] },
      mark: { type: "circle", size: 70, color: ACCENT, stroke: "white", strokeWidth: 1.5 }, encoding: { x: xd, y: { field: "PEAK_DEMAND_MW", type: "quantitative" } } },
  ] }, 250);
  const hm = card(r, "Demand by hour", `Average MW. Highest around HE${hot.DELIVERY_HOUR} in ${fmtDay(hot.MONTH.slice(0, 10), { month: "long" })}.`);
  chart(hm, { data: { values: heat }, mark: { type: "rect", stroke: "white", strokeWidth: 1, cornerRadius: 2 }, encoding: {
    x: { field: "DELIVERY_HOUR", type: "ordinal", title: "Hour ending (EST)", axis: { labelAngle: 0, values: [1, 6, 12, 18, 24] } },
    y: { field: "MONTH", type: "ordinal", timeUnit: "yearmonth", title: null, axis: { format: "%b %Y" } },
    color: { field: "AVG_MW", type: "quantitative", title: null, scale: { range: SEQUENTIAL_BLUE }, legend: { orient: "right", format: "~s", gradientLength: 140 } },
    tooltip: [{ field: "MONTH", type: "ordinal", timeUnit: "yearmonth", title: "Month" }, { field: "DELIVERY_HOUR", type: "ordinal", title: "HE" },
              { field: "AVG_MW", type: "quantitative", title: "Avg MW", format: ",.0f" }] } }, 250);

  const cfc = card(root, "Generator capacity factor", "Top 15 units by energy for the selected fuel.");
  cfc.append(h("div", { class: "controls" }, pills(FUELS, [state.cf_fuel], (f) => { state.cf_fuel = f; render(); }, title)));
  const gens = rows(D.capacity_factor[`${state.grid_period}|${state.cf_fuel}`]);
  if (!gens.length) cfc.append(h("p", { class: "caption" }, "No units of this fuel reported in the period."));
  else {
    const encc = {
      y: { field: "GENERATOR", type: "nominal", sort: "-x", title: null },
      x: { field: "CAPACITY_FACTOR", type: "quantitative", title: null, axis: { format: "%", tickCount: 5 },
           scale: { domain: [0, Math.min(1, max(gens.map((g) => g.CAPACITY_FACTOR)) * 1.15)] } },
    };
    chart(cfc, { data: { values: gens }, layer: [
      { mark: { type: "bar", size: 12, color: SERIES[FUELS.indexOf(state.cf_fuel)] }, encoding: { ...encc,
        tooltip: [{ field: "GENERATOR", type: "nominal", title: "Unit" }, { field: "CAPACITY_FACTOR", type: "quantitative", format: ".1%", title: "CF" },
                  { field: "OUTPUT_GWH", type: "quantitative", title: "Output GWh" }, { field: "CAPABILITY_MW", type: "quantitative", title: "Max MW" }] } },
      { mark: { type: "text", align: "left", dx: 4, fontSize: 11, color: "#374151" }, encoding: { ...encc, text: { field: "CAPACITY_FACTOR", type: "quantitative", format: ".0%" } } },
    ] }, 24 * gens.length + 20);
  }
  const ex = expander(root, "Daily data");
  table(ex, [
    { key: "DELIVERY_DATE", label: "Date" },
    { key: "AVG_DEMAND_MW", label: "Avg MW", num: true, fmt: (v) => fx(v) },
    { key: "PEAK_DEMAND_MW", label: "Peak MW", num: true, fmt: (v) => fx(v) },
    { key: "PEAK_HOUR", label: "Peak HE", num: true },
    { key: "NON_EMITTING_PCT", label: "Non-emitting %", num: true, fmt: (v) => v.toFixed(1) },
    { key: "EST_CARBON_G_PER_KWH", label: "g/kWh", num: true, fmt: (v) => fx(v) },
    ...FUELS.map((f) => ({ key: `${f}_MWH`, label: `${title(f)} MWh`, num: true, fmt: (v) => fx(v) })),
  ], cur.slice().reverse(), 360);
  footer(root);
}

// ================================================================ Market & storage (2_Market_BESS.py)
function bessArbitrage(power, energy, rte, start, end) {      // SP_BESS_ARBITRAGE, ported
  const byDay = new Map();
  for (const x of D.hourlyRows) {
    if (x.d < start || x.d > end || x.p === null) continue;
    if (!byDay.has(x.d)) byDay.set(x.d, {});
    byDay.get(x.d)[x.h] = x.p;
  }
  const n = Math.max(1, Math.ceil(energy / power)), mwhPerHour = energy / n, out = [];
  for (const day of [...byDay.keys()].sort()) {
    const prices = byDay.get(day);
    if (Object.keys(prices).length < 24 || 2 * n > 24) continue;
    const p = Array.from({ length: 24 }, (_, i) => prices[i + 1]);
    let best = null;
    for (let split = n; split <= 24 - n; split++) {
      const charge = [...Array(split).keys()].sort((a, b) => p[a] - p[b]).slice(0, n);
      const discharge = Array.from({ length: 24 - split }, (_, i) => i + split).sort((a, b) => p[b] - p[a]).slice(0, n);
      const cost = sum(charge.map((i) => p[i])) * mwhPerHour;
      const revenue = sum(discharge.map((i) => p[i])) * mwhPerHour * rte;
      if (best === null || revenue - cost > best[0]) best = [revenue - cost, cost, revenue, charge, discharge];
    }
    const [net, cost, revenue, charge, discharge] = best;
    out.push(net <= 0
      ? { DELIVERY_DATE: day, CHARGE_COST: 0, DISCHARGE_REVENUE: 0, NET_REVENUE: 0, CYCLES: 0, AVG_CHARGE_PRICE: null, AVG_DISCHARGE_PRICE: null, FIRST_CHARGE_HOUR: null, LAST_DISCHARGE_HOUR: null }
      : { DELIVERY_DATE: day, CHARGE_COST: +cost.toFixed(2), DISCHARGE_REVENUE: +revenue.toFixed(2), NET_REVENUE: +net.toFixed(2), CYCLES: 1,
          AVG_CHARGE_PRICE: +(sum(charge.map((i) => p[i])) / n).toFixed(2), AVG_DISCHARGE_PRICE: +(sum(discharge.map((i) => p[i])) / n).toFixed(2),
          FIRST_CHARGE_HOUR: Math.min(...charge) + 1, LAST_DISCHARGE_HOUR: Math.max(...discharge) + 1 });
  }
  return out;
}

function tieName(code) {
  if (code.startsWith("PQ.")) return `Québec ${code.slice(3)}`;
  return { "NEW-YORK": "New York", "MANITOBA SK": "Manitoba SK" }[code] || title(code);
}

function pageMarket(root) {
  pageHeader(root, "Market & storage", "Day-ahead prices, interchange with neighbours, and what a battery would earn on arbitrage.", [
    "**Prices:** the day-ahead Ontario Zonal Price in $/MWh, published since Market Renewal (May 2025). IESO keeps about 90 days of daily files, and history accumulates as the pipeline runs.",
    "**Interchange:** actual flow per intertie. Positive values are net exports from Ontario.",
    "**BESS simulator:** in Snowflake this is a Snowpark procedure (SP_BESS_ARBITRAGE); this public copy runs the same algorithm in your browser. One cycle per day: for each day it searches every split hour, charges in the cheapest hours before it and discharges in the priciest hours after it. Losses come from the round-trip efficiency. It counts energy arbitrage only, with no capacity or ancillary revenue.",
  ]);
  root.append(h("div", { class: "controls" }, segmented(["30D", "60D", "90D"], state.market_period, (v) => { state.market_period = v; render(); })));
  const { start, end, pStart } = periodWindow(state.market_period);
  const hourly = D.hourlyRows.filter((x) => x.d >= pStart && x.d <= end && x.p !== null);
  const cur = hourly.filter((x) => x.d >= start), prev = hourly.filter((x) => x.d < start);
  const daily = [...groupBy(cur, (x) => x.d)].map(([d, rs]) => {
    const p = rs.map((x) => x.p);
    return { DATE: local(d), min: Math.min(...p), mean: mean(p), max: Math.max(...p), SPREAD: Math.max(...p) - Math.min(...p) };
  });
  const prevSpread = [...groupBy(prev, (x) => x.d)].map(([, rs]) => Math.max(...rs.map((x) => x.p)) - Math.min(...rs.map((x) => x.p)));
  const flows = rows(D.flows[state.market_period]);
  const totalNet = sum(flows.filter((f) => f.INTERFACE === "TOTAL").map((f) => f.NET_MWH));
  const peakHour = argmax(cur, (x) => x.p);

  const k = row(root, "r4");
  kpi(k, { label: "Average price", value: `$${fx(mean(cur.map((x) => x.p)), 2)}/MWh`,
    delta: fmtDelta(mean(cur.map((x) => x.p)), prev.length ? mean(prev.map((x) => x.p)) : null), sparkData: daily.map((d) => d.mean), deltaColor: "inverse" });
  kpi(k, { label: "Highest hour", value: `$${fx(peakHour.p)}/MWh`, help: `${fmtDay(peakHour.d, { month: "short", day: "2-digit" })}, HE${peakHour.h}` });
  kpi(k, { label: "Avg daily spread", value: `$${fx(mean(daily.map((d) => d.SPREAD)))}/MWh`,
    delta: fmtDelta(mean(daily.map((d) => d.SPREAD)), prevSpread.length ? mean(prevSpread) : null), sparkData: daily.map((d) => d.SPREAD),
    help: "Daily max minus min hourly price: the arbitrage opportunity." });
  kpi(k, { label: "Net exports", value: `${fx(totalNet / 1e6, 2)} TWh`, help: "All interties, actual flow over the period." });

  const topDecile = quantile(cur.map((x) => x.p), 0.9);
  let r = row(root, "r21");
  const dp = card(r, "Daily price", "Line is the daily average, band is the daily min to max, $/MWh");
  const xdt = { field: "DATE", type: "temporal", title: null, axis: { format: "%b %d", labelOverlap: true } };
  chart(dp, { data: { values: daily }, layer: [
    { mark: { type: "area", opacity: 0.16, color: ACCENT }, encoding: { x: xdt, y: { field: "min", type: "quantitative", title: null }, y2: { field: "max" } } },
    { mark: { type: "line", color: ACCENT }, encoding: { x: xdt, y: { field: "mean", type: "quantitative" },
      tooltip: [{ field: "DATE", type: "temporal", title: "Date" }, { field: "mean", type: "quantitative", title: "Avg", format: "$.2f" },
                { field: "min", type: "quantitative", title: "Min", format: "$.2f" }, { field: "max", type: "quantitative", title: "Max", format: "$.2f" }] } },
  ] }, 270);
  const pd = card(r, "Price duration", `10% of hours cleared above $${fx(topDecile)}/MWh`);
  const sorted = cur.map((x) => x.p).sort((a, b) => b - a);
  const pdc = sorted.map((p, i) => ({ EXCEEDED: (i + 1) / sorted.length, ZONAL_PRICE: p }));
  chart(pd, { data: { values: pdc }, mark: { type: "line", color: ACCENT }, encoding: {
    x: { field: "EXCEEDED", type: "quantitative", title: "Share of hours", axis: { format: "%", tickCount: 5 } },
    y: { field: "ZONAL_PRICE", type: "quantitative", title: null },
    tooltip: [{ field: "EXCEEDED", type: "quantitative", format: ".0%", title: "Hours above" }, { field: "ZONAL_PRICE", type: "quantitative", format: "$.2f", title: "Price" }] } }, 270);

  const shape = [...groupBy(cur, (x) => x.h)].map(([hr, rs]) => {
    const p = rs.map((x) => x.p);
    return { DELIVERY_HOUR: hr, mean: mean(p), p10: quantile(p, 0.1), p90: quantile(p, 0.9) };
  }).sort((a, b) => a.DELIVERY_HOUR - b.DELIVERY_HOUR);
  const cheap = argmin(shape, (s) => s.mean), dear = argmax(shape, (s) => s.mean);
  r = row(root, "r2");
  const ph = card(r, "Price by hour of day", `Cheapest HE${cheap.DELIVERY_HOUR} ($${fx(cheap.mean)}), priciest HE${dear.DELIVERY_HOUR} ($${fx(dear.mean)}). Band: 10th to 90th percentile.`);
  const xh = { field: "DELIVERY_HOUR", type: "quantitative", title: "Hour ending (EST)", scale: { domain: [1, 24] }, axis: { values: [1, 6, 12, 18, 24] } };
  chart(ph, { data: { values: shape }, layer: [
    { mark: { type: "area", opacity: 0.16, color: ACCENT }, encoding: { x: xh, y: { field: "p10", type: "quantitative", title: null }, y2: { field: "p90" } } },
    { mark: { type: "line", color: ACCENT, point: { size: 28, filled: true } }, encoding: { x: xh, y: { field: "mean", type: "quantitative" },
      tooltip: [{ field: "DELIVERY_HOUR", type: "quantitative", title: "HE" }, { field: "mean", type: "quantitative", title: "Avg", format: "$.2f" },
                { field: "p10", type: "quantitative", title: "P10", format: "$.2f" }, { field: "p90", type: "quantitative", title: "P90", format: "$.2f" }] } },
  ] }, 250);

  const ties = flows.filter((f) => f.INTERFACE !== "TOTAL").map((f) => ({ NAME: tieName(f.INTERFACE), NET_GWH: f.NET_MWH / 1000 }))
    .filter((t) => Math.abs(t.NET_GWH) >= 1).sort((a, b) => b.NET_GWH - a.NET_GWH);
  const biggest = ties[0];
  const ic = card(r, "Net interchange by intertie", biggest ? `Largest net export: ${biggest.NAME} (${fx(biggest.NET_GWH)} GWh)` : null);
  chart(ic, { layer: [
    { data: { values: ties }, mark: { type: "bar", size: 12 }, encoding: {
      y: { field: "NAME", type: "nominal", sort: "-x", title: null },
      x: { field: "NET_GWH", type: "quantitative", title: "GWh (negative = net import)" },
      color: { condition: { test: "datum.NET_GWH >= 0", value: DIVERGING.pos }, value: DIVERGING.neg },
      tooltip: [{ field: "NAME", type: "nominal", title: "Intertie" }, { field: "NET_GWH", type: "quantitative", title: "Net GWh", format: ",.0f" }] } },
    { data: { values: [{ x: 0 }] }, mark: { type: "rule", color: "#c7cbd1" }, encoding: { x: { field: "x", type: "quantitative" } } },
  ] }, Math.max(180, 22 * ties.length));

  // --- battery arbitrage
  const bc = card(root, "Battery arbitrage", "One daily cycle on day-ahead prices. In Snowflake this runs as a Snowpark procedure; here the same algorithm runs in your browser.");
  const b = state.bess;
  const inputs = [["power", "Power (MW)", 1, 500, 5], ["energy", "Energy (MWh)", 1, 2000, 10], ["rte", "Round-trip efficiency", 0.7, 0.95, 0.01],
                  ["capex", "Capex ($/kWh)", 100, 1500, 25], ["om", "Fixed O&M ($/kW-yr)", 0, 100, 1]];
  const form = h("form", { class: "row", style: "grid-template-columns:repeat(5,minmax(0,1fr)) minmax(0,.8fr);align-items:end;margin-bottom:14px",
    onsubmit: (ev) => {
      ev.preventDefault();
      for (const [key, , lo, hi] of inputs) {
        const v = parseFloat(form.querySelector(`[name=${key}]`).value);
        if (!Number.isNaN(v)) b[key] = Math.min(hi, Math.max(lo, v));
      }
      render();
    } },
    inputs.map(([key, label, lo, hi, step]) => h("div", { class: "field" }, h("label", { for: `bess-${key}` }, label),
      h("input", { id: `bess-${key}`, name: key, type: "number", min: lo, max: hi, step, value: b[key] }))),
    h("button", { class: "btn primary", type: "submit" }, "Simulate"));
  bc.append(form);
  const sim = bessArbitrage(b.power, b.energy, b.rte, start, end);
  if (!sim.length) { bc.append(h("p", { class: "caption" }, "No complete price days in the period.")); }
  else {
    const net = sum(sim.map((s) => s.NET_REVENUE)), annual = (net * 365) / sim.length, annualNet = annual - b.om * b.power * 1000;
    const payback = annualNet > 0 ? (b.capex * b.energy * 1000) / annualNet : null;
    const rk = h("div", { class: "row r4" });
    bc.append(rk);
    kpi(rk, { label: `Net revenue (${sim.length} days)`, value: fmtMoney(net, 2) });
    kpi(rk, { label: "Annualised", value: fmtMoney(annual, 2), help: "Period revenue scaled to 365 days." });
    kpi(rk, { label: "Avg buy / sell price", value: `$${fx(mean(sim.map((s) => s.AVG_CHARGE_PRICE)))} / $${fx(mean(sim.map((s) => s.AVG_DISCHARGE_PRICE)))}`,
      help: "Average charging vs discharging price, $/MWh." });
    kpi(rk, { label: "Simple payback", value: payback ? `${fx(payback)} yrs` : "never",
      help: "Capex / (annualised arbitrage minus fixed O&M). Arbitrage alone rarely funds storage; capacity and ancillary-service revenue usually make up the difference." });
    let cumv = 0;
    const cum = sim.map((s) => ({ DATE: local(s.DELIVERY_DATE), NET_REVENUE: s.NET_REVENUE, CUMULATIVE: (cumv += s.NET_REVENUE) }));
    chart(bc, { data: { values: cum }, mark: { type: "area", line: { color: ACCENT, strokeWidth: 2 },
      color: { gradient: "linear", x1: 1, x2: 1, y1: 1, y2: 0, stops: [{ color: "white", offset: 0 }, { color: "#b7d3f6", offset: 1 }] } }, encoding: {
      x: { field: "DATE", type: "temporal", title: null, axis: { format: "%b %d", labelOverlap: true } },
      y: { field: "CUMULATIVE", type: "quantitative", title: null, axis: { format: "$~s" } },
      tooltip: [{ field: "DATE", type: "temporal", title: "Date" }, { field: "NET_REVENUE", type: "quantitative", title: "Day", format: "$,.0f" },
                { field: "CUMULATIVE", type: "quantitative", title: "Cumulative", format: "$,.0f" }] } }, 210);
    const money = (v) => `$${fx(v)}`, price = (v) => `$${fx(v, 2)}`;
    table(expander(bc, "Daily dispatch"), [
      { key: "DELIVERY_DATE", label: "Date" }, { key: "CHARGE_COST", label: "Charge cost", num: true, fmt: money },
      { key: "DISCHARGE_REVENUE", label: "Discharge revenue", num: true, fmt: money }, { key: "NET_REVENUE", label: "Net", num: true, fmt: money },
      { key: "CYCLES", label: "Cycles", num: true }, { key: "AVG_CHARGE_PRICE", label: "Avg buy", num: true, fmt: price },
      { key: "AVG_DISCHARGE_PRICE", label: "Avg sell", num: true, fmt: price }, { key: "FIRST_CHARGE_HOUR", label: "First charge HE", num: true },
      { key: "LAST_DISCHARGE_HOUR", label: "Last discharge HE", num: true },
    ], sim, 320);
  }
  footer(root);
}

// ================================================================ Asset health (3_Asset_Health.py)
function pageAssets(root) {
  pageHeader(root, "Asset health", "Condition, loading and risk for Lakeshore Hydro's transformers and poles.", [
    "**Health index (0-100):** a Python UDF that weights age against expected life; loading stress (peak % of nameplate and hours above 100%); the latest inspection score; and, for poles, resistograph remaining strength.",
    "**Risk:** PoF x CoF. PoF is a logistic function of the health index (HI 35 gives 50%). CoF is ln(1 + customers) x (1 + 2 x critical customers).",
    "**Reliability:** SAIDI and SAIFI per IEEE 1366, for unplanned sustained interruptions.",
    "**Data:** the utility is fictional and its data synthetic. Transformer loading follows the real Ontario demand shape.",
  ]);
  const toggle = (list, v) => (list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);
  root.append(h("div", { class: "controls" },
    pills(["NORTH", "SOUTH", "EAST"], state.regions, (v) => { state.regions = toggle(state.regions, v); render(); }, title),
    pills(ASSET_TYPES, state.types, (v) => { state.types = toggle(state.types, v); render(); }, (t) => `${title(t)}s`)));
  if (!state.regions.length || !state.types.length) {
    root.append(h("p", { class: "banner" }, icon("info"), "Select at least one region and one asset type."));
    return;
  }
  const risk = D.assetRows.filter((a) => state.regions.includes(a.REGION) && state.types.includes(a.ASSET_TYPE));
  const xf = risk.filter((a) => a.ASSET_TYPE === "TRANSFORMER");
  const veryPoor = risk.filter((a) => a.HEALTH_INDEX < 30).length;
  const overloaded = xf.filter((a) => a.PEAK_LOADING_PCT > 100);

  const k = row(root, "r4");
  kpi(k, { label: "Assets", value: fx(risk.length), note: `${fx(xf.length)} transformers, ${fx(risk.length - xf.length)} poles` });
  kpi(k, { label: "Average health index", value: `${fx(mean(risk.map((a) => a.HEALTH_INDEX)))} / 100` });
  kpi(k, { label: "Very poor (HI < 30)", value: fx(veryPoor), note: `${((100 * veryPoor) / Math.max(risk.length, 1)).toFixed(1)}% of assets` });
  kpi(k, { label: "Overloaded transformers", value: fx(overloaded.length),
    note: xf.length ? `${Math.round((100 * overloaded.length) / xf.length)}% exceed nameplate at peak` : null });

  const cofHi = risk.length ? quantile(risk.map((a) => a.COF), 0.75) : 0;
  const hot = risk.filter((a) => a.POF > 0.5 && a.COF >= cofHi);
  const cofMax = max(risk.map((a) => a.COF));
  let r = row(root, "r21");
  const rm = card(r, "Risk matrix", `${fx(hot.length)} assets in the high-risk zone (PoF above 50 %, top-quartile consequence), ${fmtMoney(sum(hot.map((a) => a.REPLACEMENT_COST_CAD)))} to replace.`);
  chart(rm, { layer: [
    { data: { values: [{ x: cofHi, x2: cofMax * 1.02, y: 0.5, y2: 1 }] }, mark: { type: "rect", color: "#d03b3b", opacity: 0.06 },
      encoding: { x: { field: "x", type: "quantitative" }, x2: { field: "x2" }, y: { field: "y", type: "quantitative" }, y2: { field: "y2" } } },
    { data: { values: risk }, mark: { type: "circle", size: 34, opacity: 0.65, stroke: "white", strokeWidth: 0.6 }, encoding: {
      x: { field: "COF", type: "quantitative", title: "Consequence of failure (log scale)", scale: { type: "log", nice: false } },
      y: { field: "POF", type: "quantitative", title: "Probability of failure", axis: { format: "%" } },
      color: { field: "ASSET_TYPE", type: "nominal", scale: { domain: ASSET_TYPES, range: SERIES.slice(0, 2) }, legend: { labelExpr: TYPE_LABEL, title: null } },
      tooltip: [{ field: "ASSET_ID", type: "nominal", title: "Asset" }, { field: "DESCRIPTION", type: "nominal", title: "Description" },
                { field: "FEEDER_ID", type: "nominal", title: "Feeder" }, { field: "HEALTH_INDEX", type: "quantitative", title: "Health", format: ".0f" },
                { field: "POF", type: "quantitative", title: "PoF", format: ".0%" }, { field: "CUSTOMERS_SERVED", type: "quantitative", title: "Customers" },
                { field: "CRITICAL_CUSTOMERS", type: "quantitative", title: "Critical" },
                { field: "REPLACEMENT_COST_CAD", type: "quantitative", title: "Replacement", format: "$,.0f" }] } },
    { data: { values: [{ x: cofMax, y: 0.98, t: "High risk" }] }, mark: { type: "text", align: "right", baseline: "top", color: "#b42f2f", fontSize: 11 },
      encoding: { x: { field: "x", type: "quantitative" }, y: { field: "y", type: "quantitative" }, text: { field: "t" } } },
  ] }, 330);
  const hb = card(r, "Health bands", "Count of assets per band");
  const bands = [...groupBy(risk, (a) => `${a.HEALTH_BAND}|${a.ASSET_TYPE}`)].map(([key, rs]) => {
    const [band, type] = key.split("|");
    return { RANK: +band[0], LABEL: title(band.slice(4)), ASSET_TYPE: type, N: rs.length };
  });
  chart(hb, { data: { values: bands }, mark: { type: "bar", size: 18, stroke: "white", strokeWidth: 1 }, encoding: {
    y: { field: "LABEL", type: "nominal", title: null, sort: { field: "RANK", op: "min" } },
    x: { field: "N", type: "quantitative", title: null, stack: true },
    color: { field: "ASSET_TYPE", type: "nominal", scale: { domain: ASSET_TYPES, range: SERIES.slice(0, 2) }, legend: null },
    order: { field: "ASSET_TYPE", type: "ordinal" },
    tooltip: [{ field: "LABEL", type: "nominal", title: "Band" }, { field: "ASSET_TYPE", type: "nominal", title: "Type" }, { field: "N", type: "quantitative", title: "Assets", format: "," }] } }, 330);

  const rel = D.relRows.filter((f) => state.regions.includes(f.REGION)).map((f) => ({ ...f, SAIDI: f.CMI / f.CUSTOMERS }));
  const custs = Math.max(sum(rel.map((f) => f.CUSTOMERS)), 1);
  const saidi = sum(rel.map((f) => f.CMI)) / custs, saifi = sum(rel.map((f) => f.CI)) / custs;
  r = row(root, "r2");
  const ov = card(r, "Overloaded transformers", overloaded.length ? `Worst at ${fx(max(overloaded.map((a) => a.PEAK_LOADING_PCT)))} % of nameplate.` : null);
  const worstXf = overloaded.slice().sort((a, b) => b.PEAK_LOADING_PCT - a.PEAK_LOADING_PCT).slice(0, 12).map((a) => {
    const parts = a.DESCRIPTION.split(" ");          // "POLE 37.5 kVA 1-ph COMMERCIAL" -> "37.5 kVA pole"
    return { ...a, RATING: `${parts[1]} kVA ${parts[0].toLowerCase()}` };
  });
  table(ov, [
    { key: "ASSET_ID", label: "Transformer" }, { key: "RATING", label: "Rating" }, { key: "FEEDER_ID", label: "Feeder" },
    { key: "PEAK_LOADING_PCT", label: "Peak loading", bar: [0, 180], fmt: (v) => `${fx(v)}%` },
    { key: "HOURS_OVER_100", label: "Hrs > 100 %", num: true, fmt: (v) => fx(v) },
  ], worstXf, 36 * 12 + 38);
  const fr = card(r, "Feeder reliability, 12 months", `System SAIDI ${fx(saidi)} min, SAIFI ${saifi.toFixed(2)}. Worst 12 feeders by SAIDI.`);
  const worst = rel.slice().sort((a, b) => b.SAIDI - a.SAIDI).slice(0, 12);
  chart(fr, { data: { values: worst }, mark: { type: "bar", size: 12, color: ACCENT }, encoding: {
    y: { field: "FEEDER_ID", type: "nominal", sort: "-x", title: null },
    x: { field: "SAIDI", type: "quantitative", title: "Customer-minutes per customer" },
    tooltip: [{ field: "FEEDER_ID", type: "nominal", title: "Feeder" }, { field: "CONSTRUCTION", type: "nominal", title: "Construction" },
              { field: "CUSTOMERS", type: "quantitative", title: "Customers", format: "," }, { field: "SAIDI", type: "quantitative", format: ".0f" }] } }, 36 * 12 + 2);

  const tx = D.txRows;
  const uniq = (rs) => new Set(rs.map((x) => x.OUTAGE_ID)).size;
  const txc = card(root, "IESO planned transmission outages",
    `Real IESO data: ${fx(uniq(tx))} outage requests open, ${fx(uniq(tx.filter((x) => x.IS_ACTIVE)))} active now, ${fx(uniq(tx.filter((x) => (x.VOLTAGE_KV || 0) >= 500)))} involving 500 kV equipment.`);
  const labelled = tx.map((x) => { const kv = Math.trunc(x.VOLTAGE_KV || 0); return { ...x, KV: kv > 0 ? `${kv} kV` : "n/a" }; });
  const counts = [...groupBy(labelled, (x) => x.EQUIPMENT_TYPE)].sort((a, b) => b[1].length - a[1].length).slice(0, 8).map(([t]) => t);
  const byType = [...groupBy(labelled.filter((x) => counts.includes(x.EQUIPMENT_TYPE)), (x) => `${x.EQUIPMENT_TYPE}|${x.KV}`)]
    .map(([key, rs]) => { const [t, kv] = key.split("|"); return { EQUIPMENT_TYPE: t, KV: kv, N: rs.length }; });
  const kvOrder = [...new Set(byType.map((x) => x.KV))].sort((a, b) => (a === "n/a" ? 0 : -parseInt(a, 10)) - (b === "n/a" ? 0 : -parseInt(b, 10)));
  chart(txc, { data: { values: byType }, mark: { type: "bar", size: 14, stroke: "white", strokeWidth: 1 }, encoding: {
    y: { field: "EQUIPMENT_TYPE", type: "nominal", sort: "-x", title: null },
    x: { aggregate: "sum", field: "N", type: "quantitative", title: "Equipment items out of service (8 most common types)" },
    color: { field: "KV", type: "nominal", sort: kvOrder, scale: { scheme: "blues", reverse: true }, title: null },
    order: { field: "KV", type: "ordinal", sort: "descending" },
    tooltip: [{ field: "EQUIPMENT_TYPE", type: "nominal", title: "Equipment" }, { field: "KV", type: "nominal", title: "Voltage" }, { field: "N", type: "quantitative", title: "Items" }] } },
    26 * counts.length + 40);
  const list = expander(txc, "Outage list");
  const shown = tx.slice().sort((a, b) => (a.PLANNED_START < b.PLANNED_START ? -1 : 1)).slice(0, 150);
  table(list, [
    { key: "OUTAGE_ID", label: "Outage" }, { key: "EQUIPMENT_NAME", label: "Equipment" }, { key: "EQUIPMENT_TYPE", label: "Type" },
    { key: "VOLTAGE_KV", label: "kV", num: true, fmt: (v) => fx(v) }, { key: "PLANNED_START", label: "Planned start", fmt: (v) => v.replace("T", " ") },
    { key: "PLANNED_END", label: "Planned end", fmt: (v) => v.replace("T", " ") }, { key: "PRIORITY", label: "Priority" },
    { key: "REQUEST_STATUS", label: "Status" }, { key: "IS_ACTIVE", label: "Active", fmt: (v) => (v ? "Yes" : "") },
  ], shown, 360);
  list.append(h("p", { class: "note" }, `Showing the first ${shown.length} of ${fx(tx.length)} equipment rows by planned start.`));
  footer(root);
}

// ================================================================ Capital plan (4_Capital_Plan.py)
function capitalPlan(budget) {                               // SP_CAPITAL_PLAN, ported
  const assets = D.assetRows.filter((a) => a.HEALTH_INDEX !== null && (a.REPLACEMENT_COST_CAD || 0) > 0);
  const must = assets.filter((a) => (a.CRITICAL_CUSTOMERS || 0) > 0 && a.HEALTH_INDEX < 30);
  const mustIds = new Set(must.map((a) => a.ASSET_ID));
  const ranked = assets.filter((a) => !mustIds.has(a.ASSET_ID) && (a.RISK_REDUCTION || 0) > 0)
    .sort((a, b) => b.RISK_REDUCTION / b.REPLACEMENT_COST_CAD - a.RISK_REDUCTION / a.REPLACEMENT_COST_CAD);
  must.sort((a, b) => b.RISK_SCORE - a.RISK_SCORE);
  const plan = [];
  let spent = 0;
  for (const [reason, group] of [["CRITICAL_CUSTOMER_POOR_HEALTH", must], ["RISK_PER_DOLLAR", ranked]]) {
    for (const a of group) {
      const cost = a.REPLACEMENT_COST_CAD;
      if (spent + cost > budget) continue;                  // skip, a cheaper asset may still fit
      spent += cost;
      plan.push({ PLAN_RANK: plan.length + 1, ASSET_ID: a.ASSET_ID, ASSET_TYPE: a.ASSET_TYPE, REGION: a.REGION, FEEDER_ID: a.FEEDER_ID,
        HEALTH_INDEX: a.HEALTH_INDEX, RISK_SCORE: a.RISK_SCORE, REPLACEMENT_COST_CAD: cost, RISK_REDUCTION: a.RISK_REDUCTION,
        CUMULATIVE_COST_CAD: Math.round(spent * 100) / 100, SELECTION_REASON: reason });
    }
  }
  return plan;
}

const BUDGETS = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15];
function pageCapital(root) {
  pageHeader(root, "Capital plan", "Which replacements remove the most risk for a given annual budget.", [
    "**Engine:** the Snowpark procedure `SP_CAPITAL_PLAN` in Snowflake; this public copy runs the same logic in your browser.",
    "**Must-do assets:** assets serving critical customers with a health index below 30 are selected first.",
    "**Everything else:** assets are picked greedily by risk removed per dollar until the budget is spent.",
    "**Risk removed:** (PoF - 2 %) x CoF, because a new asset still carries about 2 % PoF.",
    "**Costs:** indicative installed costs in CAD.",
    "**Audit:** in Snowflake every run is written to `MARTS.CAPITAL_PLAN_RUNS`.",
  ]);
  const idx = BUDGETS.indexOf(state.budget);
  const slider = h("input", { type: "range", min: 0, max: BUDGETS.length - 1, step: 1, value: idx, "aria-label": "Annual replacement budget",
    onchange: (ev) => { state.budget = BUDGETS[+ev.target.value]; render(); },
    oninput: (ev) => { now.textContent = `$${BUDGETS[+ev.target.value]}M`; } });
  const now = h("span", { class: "now" }, `$${state.budget}M`);
  root.append(h("div", { class: "slider controls", style: "display:block" },
    h("div", { class: "field" }, h("label", {}, "Annual replacement budget: ", now)), slider,
    h("div", { class: "ticks" }, BUDGETS.map((x) => h("span", {}, `$${x}M`)))));

  const budget = state.budget * 1e6;
  const plan = capitalPlan(budget), frontier = capitalPlan(Math.max(...BUDGETS) * 1e6);
  const totalRisk = D.meta.total_risk;
  if (!plan.length) { root.append(h("p", { class: "banner" }, "The budget is too small for any replacement.")); return; }
  const spend = sum(plan.map((p) => p.REPLACEMENT_COST_CAD)), removed = sum(plan.map((p) => p.RISK_REDUCTION));
  const must = plan.filter((p) => p.SELECTION_REASON !== "RISK_PER_DOLLAR").length;

  const k = row(root, "r4");
  kpi(k, { label: "Assets replaced", value: fx(plan.length),
    note: `${fx(plan.filter((p) => p.ASSET_TYPE === "POLE").length)} poles, ${fx(plan.filter((p) => p.ASSET_TYPE === "TRANSFORMER").length)} transformers` });
  kpi(k, { label: "Spend", value: fmtMoney(spend, 2), note: `of $${state.budget}M budget` });
  kpi(k, { label: "Portfolio risk removed", value: `${((100 * removed) / totalRisk).toFixed(1)} %`, help: "Sum of risk removed / total risk across all assets." });
  kpi(k, { label: "Must-do (critical customers)", value: `${must}`, note: must === 0 ? "none below HI 30 at critical sites" : null });

  let cumr = 0;
  const fr = frontier.map((p) => ({ ...p, CUM_RISK: (cumr += p.RISK_REDUCTION) / totalRisk }));
  const atBudget = max(fr.filter((p) => p.CUMULATIVE_COST_CAD <= budget).map((p) => p.CUM_RISK));
  const r = row(root, "r21");
  const cv = card(r, "Risk removed vs. spend",
    `$${state.budget}M removes ${Math.round((100 * removed) / totalRisk)} % of portfolio risk; $${Math.max(...BUDGETS)}M would remove ${Math.round(100 * fr[fr.length - 1].CUM_RISK)} %.`);
  const marker = [{ x: budget, y: atBudget, t: `$${state.budget}M` }];
  chart(cv, { layer: [
    { data: { values: fr }, mark: { type: "line", color: ACCENT, interpolate: "step-after" }, encoding: {
      x: { field: "CUMULATIVE_COST_CAD", type: "quantitative", title: null, axis: { format: "$~s" } },
      y: { field: "CUM_RISK", type: "quantitative", title: null, axis: { format: "%" } },
      tooltip: [{ field: "PLAN_RANK", type: "quantitative", title: "Rank" }, { field: "ASSET_ID", type: "nominal", title: "Asset" },
                { field: "CUMULATIVE_COST_CAD", type: "quantitative", title: "Cumulative spend", format: "$,.0f" },
                { field: "CUM_RISK", type: "quantitative", title: "Risk removed", format: ".1%" }] } },
    { data: { values: marker }, mark: { type: "rule", color: "#9aa1ab", strokeDash: [4, 3] }, encoding: { x: { field: "x", type: "quantitative" } } },
    { data: { values: marker }, mark: { type: "circle", size: 70, color: ACCENT, stroke: "white", strokeWidth: 1.5 },
      encoding: { x: { field: "x", type: "quantitative" }, y: { field: "y", type: "quantitative" } } },
    { data: { values: marker }, mark: { type: "text", align: "left", dx: 6, dy: -8, fontSize: 11, color: "#374151" },
      encoding: { x: { field: "x", type: "quantitative" }, y: { field: "y", type: "quantitative" }, text: { field: "t" } } },
  ] }, 290);
  const sr = card(r, "Spend by region", "Replacement cost in the plan");
  const by = [...groupBy(plan, (p) => `${p.REGION}|${p.ASSET_TYPE}`)].map(([key, rs]) => {
    const [region, type] = key.split("|");
    return { REGION: region, ASSET_TYPE: type, REPLACEMENT_COST_CAD: sum(rs.map((p) => p.REPLACEMENT_COST_CAD)) };
  });
  chart(sr, { data: { values: by }, mark: { type: "bar", size: 34, stroke: "white", strokeWidth: 1 }, encoding: {
    x: { field: "REGION", type: "nominal", title: null, axis: { labelAngle: 0, labelExpr: TITLE_CASE } },
    y: { field: "REPLACEMENT_COST_CAD", type: "quantitative", title: null, stack: true, axis: { format: "$~s" } },
    color: { field: "ASSET_TYPE", type: "nominal", scale: { domain: ASSET_TYPES, range: SERIES.slice(0, 2) }, legend: { labelExpr: TYPE_LABEL, title: null } },
    order: { field: "ASSET_TYPE", type: "ordinal" },
    tooltip: [{ field: "REGION", type: "nominal", title: "Region" }, { field: "ASSET_TYPE", type: "nominal", title: "Type" },
              { field: "REPLACEMENT_COST_CAD", type: "quantitative", title: "Spend", format: "$,.0f" }] } }, 290);

  const rl = card(root, "Replacement list", `${fx(plan.length)} assets in priority order`);
  const money = (v) => `$${fx(v)}`;
  table(rl, [
    { key: "PLAN_RANK", label: "#", num: true }, { key: "ASSET_ID", label: "Asset" }, { key: "ASSET_TYPE", label: "Type", fmt: title },
    { key: "REGION", label: "Region", fmt: title }, { key: "FEEDER_ID", label: "Feeder" },
    { key: "HEALTH_INDEX", label: "Health", bar: [0, 100], fmt: (v) => fx(v) }, { key: "RISK_REDUCTION", label: "Risk removed", num: true, fmt: (v) => v.toFixed(2) },
    { key: "REPLACEMENT_COST_CAD", label: "Cost", num: true, fmt: money }, { key: "CUMULATIVE_COST_CAD", label: "Cumulative", num: true, fmt: money },
  ], plan, 360);
  const csv = () => {
    const cols = Object.keys(plan[0]);
    const text = [cols.join(","), ...plan.map((p) => cols.map((c) => p[c]).join(","))].join("\n");
    const a = h("a", { href: URL.createObjectURL(new Blob([text], { type: "text/csv" })), download: `capital_plan_${state.budget}M.csv` });
    document.body.append(a); a.click(); a.remove();
  };
  rl.append(h("p", {}, h("button", { class: "btn", type: "button", onclick: csv, style: "margin-top:12px" }, icon("download"), "Download CSV")));
  footer(root);
}

// ================================================================ Operations (5_Platform_Ops.py)
function pageOps(root) {
  pageHeader(root, "Operations", "What the platform costs, and whether its pipelines are healthy.", [
    "**Credits:** `SNOWFLAKE.ACCOUNT_USAGE`, which lags by up to about 3 hours.",
    "**Tasks, dynamic tables and storage:** `GRID_DB.INFORMATION_SCHEMA`, which is real time.",
    "**Skipped tasks:** a task is *skipped* when its stream has no new rows, so it uses no compute.",
    "**This copy:** a snapshot of the account metadata taken when the data was exported.",
  ]);
  const credits = rows(D.ops.credits), tasks = rows(D.ops.tasks), storage = rows(D.ops.storage), dts = rows(D.ops.dts);
  const ran = tasks.filter((t) => t.STATE === "SUCCEEDED" || t.STATE === "FAILED");
  const success = ran.length ? ran.filter((t) => t.STATE === "SUCCEEDED").length / ran.length : null;
  const seen = new Set(), latestDt = dts.filter((d) => (seen.has(d.NAME) ? false : seen.add(d.NAME)));
  const daily = [...groupBy(credits, (c) => c.DAY)].sort().map(([, rs]) => sum(rs.map((c) => c.CREDITS)));
  const active = sum(storage.map((s) => s.ACTIVE_BYTES));

  const k = row(root, "r4");
  kpi(k, { label: "Credits, 30 days", value: sum(credits.map((c) => c.CREDITS)).toFixed(2), sparkData: daily.length > 1 ? daily : null,
    help: "Warehouse compute only. Serverless features (tasks maintenance, MV, search optimization) are billed separately." });
  kpi(k, { label: "Storage", value: active >= 1024 ** 3 ? `${(active / 1024 ** 3).toFixed(2)} GB` : `${fx(active / 1024 ** 2)} MB`,
    note: `${fx(sum(storage.map((s) => s.ROW_COUNT)) / 1e6, 1)}M rows in ${storage.length} tables` });
  kpi(k, { label: "Task success, 7 days", value: success !== null ? `${Math.round(success * 100)}%` : "n/a",
    note: `${ran.length} runs, ${tasks.filter((t) => t.STATE === "SKIPPED").length} skipped (no new data)` });
  kpi(k, { label: "Dynamic tables", value: `${latestDt.length}`, note: `${latestDt.filter((d) => d.STATE === "SUCCEEDED").length} refreshed OK on last run` });

  let r = row(root, "r21");
  const cr = card(r, "Credits per day", "Stacked by warehouse");
  if (!credits.length) cr.append(h("p", { class: "caption" }, "No metering rows yet. ACCOUNT_USAGE lags by a few hours."));
  else chart(cr, { data: { values: credits.map((c) => ({ ...c, DATE: local(c.DAY) })) }, mark: { type: "bar", size: 14, stroke: "white", strokeWidth: 1 }, encoding: {
    x: { field: "DATE", type: "ordinal", timeUnit: "yearmonthdate", title: null, axis: { format: "%b %d", labelAngle: 0 } },
    y: { field: "CREDITS", type: "quantitative", title: null, stack: true },
    color: { field: "WAREHOUSE_NAME", type: "nominal", scale: { domain: WAREHOUSES, range: SERIES.slice(0, 3) }, legend: { title: null } },
    order: { field: "WAREHOUSE_NAME", type: "ordinal" },
    tooltip: [{ field: "DATE", type: "temporal", title: "Day" }, { field: "WAREHOUSE_NAME", type: "nominal", title: "Warehouse" },
              { field: "CREDITS", type: "quantitative", title: "Credits", format: ".3f" }] } }, 250);
  const st = card(r, "Storage by table", "Largest 8, active MB");
  const top = storage.slice().sort((a, b) => b.ACTIVE_BYTES - a.ACTIVE_BYTES).slice(0, 8)
    .map((s) => ({ TABLE: `${s.TABLE_SCHEMA}.${s.TABLE_NAME}`, MB: s.ACTIVE_BYTES / 1024 ** 2 }));
  chart(st, { data: { values: top }, mark: { type: "bar", size: 12, color: ACCENT }, encoding: {
    y: { field: "TABLE", type: "nominal", sort: "-x", title: null, axis: { labelLimit: 200 } },
    x: { field: "MB", type: "quantitative", title: null },
    tooltip: [{ field: "TABLE", type: "nominal", title: "Table" }, { field: "MB", type: "quantitative", title: "MB", format: ",.1f" }] } }, 250);

  const STATUS = { SUCCEEDED: "Succeeded", FAILED: "Failed", SKIPPED: "Skipped", CANCELLED: "Cancelled" };
  const when = (v) => (v ? `${fmtDay(v.slice(0, 10), { month: "short", day: "numeric" })}, ${v.slice(11, 16)}` : "");
  r = row(root, "r2");
  table(card(r, "Task runs", "RAW to STAGING task DAG, last 7 days"), [
    { key: "NAME", label: "Task" }, { key: "STATE", label: "Status", fmt: (v) => STATUS[v] || v },
    { key: "SCHEDULED_TIME", label: "Scheduled", fmt: when }, { key: "SECONDS", label: "Sec", num: true },
  ], tasks, 300);
  table(card(r, "Dynamic tables", "STAGING to MARTS, latest refresh of each"), [
    { key: "NAME", label: "Dynamic table" }, { key: "STATE", label: "Status", fmt: (v) => STATUS[v] || v },
    { key: "REFRESH_ACTION", label: "Action" }, { key: "DATA_TIMESTAMP", label: "Data as of", fmt: when }, { key: "SECONDS", label: "Sec", num: true },
  ], latestDt, 300);
  footer(root);
}

// ---------------------------------------------------------------- router
const ROUTES = { summary: pageSummary, supply: pageSupply, market: pageMarket, assets: pageAssets, capital: pageCapital, ops: pageOps };
const TITLES = { summary: "Summary", supply: "Supply & demand", market: "Market & storage", assets: "Asset health", capital: "Capital plan", ops: "Operations" };
let lastRoute = null;
function render() {
  const route = (location.hash.replace(/^#\/?/, "") || "summary").split("?")[0];
  const page = ROUTES[route] ? route : "summary";
  const main = document.getElementById("page");
  const keepScroll = page === lastRoute ? window.scrollY : 0;
  main.replaceChildren();
  ROUTES[page](main);
  document.querySelectorAll(".nav a").forEach((a) => a.classList.toggle("active", a.dataset.route === page));
  document.title = `${TITLES[page]} | Ontario Grid & Asset Intelligence`;
  lastRoute = page;
  window.scrollTo(0, keepScroll);
  flushCharts();
}

window.addEventListener("hashchange", render);
loadData().then(render).catch((e) => {
  document.getElementById("page").replaceChildren(h("p", { class: "loading" }, "Could not load the data snapshot."));
  console.error(e);
});
window.__grid = { D, capitalPlan, bessArbitrage };               // used by the build checks
