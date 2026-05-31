"use strict";

const $ = (sel) => document.querySelector(sel);
let CONTROLS = [];          // metadata from /api/state
// connection lifecycle state machine -- single source of truth (see enterState)
const ST = { DISCONNECTED: "disconnected", CONNECTED: "connected", RECONNECTING: "reconnecting" };
let connState = ST.DISCONNECTED;
let currentTab = "basic";

// reset/disconnect handling
let lastConn = null;        // {port, baud, slave} for auto-reconnect
let lastUptime = null;      // device uptime counter; a backward jump => reset
let heartbeatTimer = null;
let reconnectTimer = null;
let statusUnsupportedNoted = false;

// --------------------------------------------------------------------- utils
async function api(path, opts) {
  const res = await fetch(path, opts);
  let data;
  try { data = await res.json(); } catch { data = { ok: false, error: res.statusText }; }
  if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function postJSON(path, body) {
  return api(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

// like api() but never throws — returns the HTTP status so the heartbeat can
// tell a dead port (503) from a transient error (4xx) without try/catch noise.
async function rawFetch(path, opts) {
  try {
    const res = await fetch(path, opts);
    let data = {};
    try { data = await res.json(); } catch { /* non-JSON */ }
    return { status: res.status, ok: res.ok, data };
  } catch {
    return { status: 0, ok: false, data: {} };   // network error to our server
  }
}

let toastTimer = null;
function toast(msg, kind = "ok") {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "toast " + kind;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 2600);
}

const hex = (v) => "0x" + (v & 0xff).toString(16).toUpperCase().padStart(2, "0");

function debounce(fn, ms) {
  let t;
  return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}

// ----------------------------------------------------------------- port list
async function loadPorts() {
  try {
    const { ports } = await api("/api/ports");
    const sel = $("#port");
    const prev = sel.value;
    sel.innerHTML = "";
    if (ports.length === 0) {
      sel.innerHTML = '<option value="">(no ports found)</option>';
    }
    for (const p of ports) {
      const o = document.createElement("option");
      o.value = p.device;
      o.textContent = p.description ? `${p.device} — ${p.description}` : p.device;
      sel.appendChild(o);
    }
    if (prev) sel.value = prev;
  } catch (e) {
    toast(e.message, "error");
  }
}

// --------------------------------------------------------------- connection
// The only place connection side-effects live: entering a state fully defines
// the UI (buttons, inputs, tabs, banner, status line) and the background timers
// (heartbeat, auto-reconnect). Callers just raise events by calling enterState,
// so no path can leave a stale banner, an orphaned timer, or visible tabs.
function enterState(next, info) {
  connState = next;
  const conn = (next === ST.CONNECTED);

  // both timers off; the new state re-arms only what it needs
  stopHeartbeat();
  stopReconnect();

  $("#connect").disabled    = conn;
  $("#disconnect").disabled = (next === ST.DISCONNECTED);
  $("#port").disabled  = conn;
  $("#baud").disabled  = conn;
  $("#slave").disabled = conn;

  $("#tabs").hidden = !conn;
  if (conn) {
    showTab(currentTab);
  } else {
    $("#tab-basic").hidden = true;
    $("#tab-color").hidden = true;
  }

  if (next === ST.RECONNECTING) {
    showBanner("Device disconnected — waiting for it to come back…", "warn");
    connStatus("Not connected.", "");
    startReconnect();
  } else if (conn) {
    clearBanner();
    connStatus(`Connected to ${info.port} (slave ${info.slave}), PID ${hex(info.pid)}.`, "connected");
    startHeartbeat();
  } else {
    clearBanner();
    connStatus("Not connected.", "");
  }
}

function connStatus(msg, cls) {
  const s = $("#conn-status");
  s.textContent = msg;
  s.className = "status" + (cls ? " " + cls : "");
}

function showTab(name) {
  currentTab = name;
  for (const t of ["basic", "color"]) $("#tab-" + t).hidden = (t !== name);
  document.querySelectorAll(".tab").forEach((b) => {
    b.classList.toggle("active", b.dataset.tab === name);
  });
}

async function connect() {
  const port = $("#port").value;
  if (!port) { toast("Pick a serial port first", "error"); return; }
  const cfg = { port, baud: Number($("#baud").value), slave: Number($("#slave").value) };
  try {
    const info = await postJSON("/api/connect", cfg);
    lastConn = cfg;
    lastUptime = null;
    statusUnsupportedNoted = false;
    enterState(ST.CONNECTED, info);
    renderControls();
    await loadSettings();
    toast("Connected");
  } catch (e) {
    connStatus(e.message, "error");
    toast(e.message, "error");
  }
}

async function disconnect() {
  lastConn = null;            // intentional disconnect: don't auto-reconnect
  try { await postJSON("/api/disconnect", {}); } catch {}
  enterState(ST.DISCONNECTED);
}

// ---------------------------------------------------- heartbeat & recovery
function showBanner(msg, kind) {
  const b = $("#banner");
  b.textContent = msg;
  b.className = "banner" + (kind ? " " + kind : "");
  b.hidden = false;
}
function clearBanner() { $("#banner").hidden = true; }

function startHeartbeat() { stopHeartbeat(); heartbeatTimer = setInterval(heartbeat, 4000); heartbeat(); }
function stopHeartbeat() { if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; } }

async function heartbeat() {
  const { status, data } = await rawFetch("/api/health");
  if (status === 0) return;                  // can't reach our own server; skip
  if (status === 503) {                      // device gone -> hand off to reconnect
    if (connState === ST.CONNECTED) enterState(ST.RECONNECTING);
    return;
  }
  if (!data.ok) return;                      // transient (e.g. 400) — ignore tick
  if (data.status_supported && typeof data.uptime === "number") {
    if (lastUptime !== null && data.uptime < lastUptime - 1) {
      toast("Device was reset — resyncing", "error");
      loadSettings();                        // re-pull the reverted register state
    }
    lastUptime = data.uptime;
    if (data.magic_ok === false) toast("Unexpected firmware magic", "error");
  } else if (!statusUnsupportedNoted) {
    statusUnsupportedNoted = true;
    toast("Reset detection unavailable (older bitstream)");
  }
}

function startReconnect() { stopReconnect(); reconnectTimer = setInterval(tryReconnect, 3000); }
function stopReconnect() { if (reconnectTimer) { clearInterval(reconnectTimer); reconnectTimer = null; } }

async function tryReconnect() {
  if (!lastConn) { enterState(ST.DISCONNECTED); return; }
  let avail = false;
  try {
    const { ports } = await api("/api/ports");
    avail = ports.some((p) => p.device === lastConn.port);
  } catch { /* keep waiting */ }
  if (!avail) return;                        // port not back yet
  try {
    const info = await postJSON("/api/connect", lastConn);
    lastUptime = null;
    enterState(ST.CONNECTED, info);
    renderControls();
    await loadSettings();
    toast("Reconnected");
  } catch { /* port present but not ready yet; keep trying */ }
}

// ----------------------------------------------------------------- controls
function buildControlRow(c) {
    const row = document.createElement("div");
    row.className = "control";
    row.dataset.id = c.id;
    if (c.help) row.title = c.help;

    const name = document.createElement("div");
    name.className = "name";
    name.innerHTML = `${c.name}<small>${c.help || ""}</small>`;
    row.appendChild(name);

    const widget = document.createElement("div");
    widget.className = "widget";
    const val = document.createElement("div");
    val.className = "val";

    if (c.type === "byte") {
      const range = document.createElement("input");
      range.type = "range"; range.min = 0; range.max = 255; range.value = 0;
      range.dataset.role = "input";
      range.addEventListener("input", () => { val.textContent = `${range.value} (${hex(+range.value)})`; });
      range.addEventListener("change", () => applyControl(c.id, Number(range.value)));
      widget.appendChild(range);
      row.appendChild(widget);
      row.appendChild(val);
    } else if (c.type === "gamma") {
      const scale = c.scale || 100;
      const range = document.createElement("input");
      range.type = "range"; range.min = c.min; range.max = c.max;
      range.step = c.step || 1; range.value = c.default || c.min;
      range.dataset.role = "input";
      const show = () => { val.textContent = "γ " + (range.value / scale).toFixed(2); };
      range.addEventListener("input", () => { show(); previewGammaDebounced(range.value); });
      range.addEventListener("change", () => applyControl(c.id, Number(range.value)));
      show();
      widget.appendChild(range);
      row.appendChild(widget);
      row.appendChild(val);
    } else if (c.type === "bit") {
      const cb = document.createElement("input");
      cb.type = "checkbox"; cb.className = "switch"; cb.dataset.role = "input";
      cb.addEventListener("change", () => applyControl(c.id, cb.checked));
      widget.appendChild(cb);
      row.appendChild(widget);
      row.appendChild(val);
    } else if (c.type === "pattern") {
      const sel = document.createElement("select");
      sel.dataset.role = "input";
      for (const o of c.options) {
        const opt = document.createElement("option");
        opt.value = o.id; opt.textContent = o.label;
        sel.appendChild(opt);
      }
      sel.addEventListener("change", () => applyControl(c.id, sel.value));
      widget.appendChild(sel);
      row.appendChild(widget);
      row.appendChild(val);
    }
    return row;
}

const GAMMA_CONTROL_IDS = ["gamma_enable", "gamma"];

function renderControls() {
  const root = $("#controls");
  root.innerHTML = "";
  root.className = "controls-cols";
  const colSliders = document.createElement("div");
  colSliders.className = "control-col col-sliders";
  const colChecks = document.createElement("div");
  colChecks.className = "control-col col-checks";
  for (const c of CONTROLS) {
    if (GAMMA_CONTROL_IDS.includes(c.id)) continue;   // shown in the gamma block
    const row = buildControlRow(c);
    (c.type === "bit" ? colChecks : colSliders).appendChild(row);  // bits | rest
  }
  root.appendChild(colSliders);
  root.appendChild(colChecks);
  renderGammaControls();
}

function renderGammaControls() {
  const root = $("#gamma-controls");
  root.innerHTML = "";
  for (const id of GAMMA_CONTROL_IDS) {
    const c = CONTROLS.find((x) => x.id === id);
    if (c) root.appendChild(buildControlRow(c));
  }
}

function setWidgetValue(c, value) {
  const row = document.querySelector(`.control[data-id="${c.id}"]`);
  if (!row) return;
  const input = row.querySelector('[data-role="input"]');
  const val = row.querySelector(".val");
  if (c.type === "byte") {
    input.value = value;
    val.textContent = `${value} (${hex(value)})`;
  } else if (c.type === "gamma") {
    const scale = c.scale || 100;
    input.value = value;
    val.textContent = "γ " + (value / scale).toFixed(2);
  } else if (c.type === "bit") {
    input.checked = !!value;
  } else if (c.type === "pattern") {
    input.value = value;
  }
}

async function loadSettings() {
  try {
    const data = await api("/api/settings");
    // identity table
    const tbl = $("#identity");
    tbl.innerHTML = "";
    for (const r of data.identity) {
      const tr = document.createElement("tr");
      const ok = r.ok ? '<span class="tag-ok">&#10003;</span>' : '<span class="tag-bad">&#10007;</span>';
      tr.innerHTML = `<td>${r.label}</td><td class="mono">${hex(r.addr)}</td>` +
        `<td class="mono">${r.value === null ? "—" : hex(r.value)}</td><td>${ok}</td>`;
      tbl.appendChild(tr);
    }
    // controls
    for (const c of CONTROLS) setWidgetValue(c, data.controls[c.id]);
    // gamma visualization (reads the full SLOP+GAM table from the device)
    readDeviceGamma();
    loadMatrix();
  } catch (e) {
    toast(e.message, "error");
  }
}

async function applyControl(id, value) {
  try {
    await postJSON("/api/control", { id, value });
    const c = CONTROLS.find((x) => x.id === id);
    toast(`${c ? c.name : id} updated`);
    if (id === "gamma") readDeviceGamma();   // reflect the now-on-device curve
  } catch (e) {
    toast(e.message, "error");
    loadSettings();   // re-sync widgets to actual device state on failure
  }
}

// -------------------------------------------------------------- gamma curve
const GAMMA_REG_NAME = (addr) => (addr === 0x7a ? "SLOP" : "GAM" + (addr - 0x7b + 1));

function renderGammaCurve(points, registers, caption) {
  $("#gamma-caption").textContent = caption || "";

  const S = 240, pad = 30, plot = S - 2 * pad;
  const sx = (x) => pad + (x / 255) * plot;
  const sy = (y) => pad + plot - (y / 255) * plot;
  const poly = points.map((p) => `${sx(p[0]).toFixed(1)},${sy(p[1]).toFixed(1)}`).join(" ");
  // knee markers = the 15 breakpoints (skip the origin [0] and the 255 endpoint)
  const knees = points.slice(1, points.length - 1)
    .map((p) => `<circle class="gamma-knee" cx="${sx(p[0]).toFixed(1)}" cy="${sy(p[1]).toFixed(1)}" r="2.5"/>`)
    .join("");

  $("#gamma-plot").innerHTML = `
    <svg viewBox="0 0 ${S} ${S}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="gamma curve">
      <line class="gamma-axis" x1="${pad}" y1="${pad}" x2="${pad}" y2="${pad + plot}"/>
      <line class="gamma-axis" x1="${pad}" y1="${pad + plot}" x2="${pad + plot}" y2="${pad + plot}"/>
      <line class="gamma-ref" x1="${sx(0)}" y1="${sy(0)}" x2="${sx(255)}" y2="${sy(255)}"/>
      <polyline class="gamma-line" points="${poly}"/>
      ${knees}
      <text class="gamma-label" x="${pad - 4}" y="${pad}" text-anchor="end">255</text>
      <text class="gamma-label" x="${pad - 4}" y="${pad + plot}" text-anchor="end">0</text>
      <text class="gamma-label" x="${pad + plot}" y="${pad + plot + 14}" text-anchor="end">in 255</text>
      <text class="gamma-label" x="${pad}" y="${pad + plot + 14}" text-anchor="middle">0</text>
      <text class="gamma-label" x="6" y="${pad + 6}">out</text>
    </svg>`;

  const tbl = $("#gamma-regs");
  tbl.innerHTML = "";
  for (const [k, v] of Object.entries(registers)) {
    const addr = parseInt(k, 16);
    const tr = document.createElement("tr");
    tr.innerHTML = `<td class="name">${GAMMA_REG_NAME(addr)}</td>` +
      `<td class="addr">${k.toUpperCase()}</td>` +
      `<td class="val">${hex(v)} (${v})</td>`;
    tbl.appendChild(tr);
  }
}

async function previewGamma(value) {
  try {
    const d = await api(`/api/gamma?value=${encodeURIComponent(value)}`);
    renderGammaCurve(d.points, d.registers, `preview — γ ${d.exponent.toFixed(2)} (not yet applied)`);
  } catch (e) { /* preview is best-effort */ }
}
const previewGammaDebounced = debounce(previewGamma, 120);

async function readDeviceGamma() {
  try {
    const d = await api("/api/gamma/device");
    renderGammaCurve(d.points, d.registers, `on device — γ ≈ ${d.exponent.toFixed(2)}`);
  } catch (e) { toast(e.message, "error"); }
}

// -------------------------------------------------------------- color matrix
const rgbCss = (a) => `rgb(${a[0]},${a[1]},${a[2]})`;

function heatColor(v) {                       // signed -255..255 -> diverging
  const t = Math.min(1, Math.abs(v) / 255);
  const base = [43, 53, 66];
  const tgt = v >= 0 ? [232, 88, 79] : [74, 163, 255];   // red + / blue -
  return rgbCss(base.map((b, i) => Math.round(b + (tgt[i] - b) * t)));
}
const heatText = (v) => (Math.abs(v) / 255 > 0.5 ? "#06121f" : "#d7e0ea");

function renderMatrix(d) {
  $("#matrix-autocc").checked = d.auto_contrast;

  const grid = $("#matrix-grid");
  grid.innerHTML = "";
  const tbl = document.createElement("table");
  tbl.className = "matrix-grid";
  let tr = document.createElement("tr");
  tr.innerHTML = "<th></th>" + d.cols.map((c) => `<th>${c}</th>`).join("");
  tbl.appendChild(tr);

  for (let r = 0; r < d.rows.length; r++) {
    tr = document.createElement("tr");
    const th = document.createElement("th");
    th.className = "rowhead"; th.textContent = d.rows[r];
    tr.appendChild(th);
    for (let c = 0; c < d.cols.length; c++) {
      const i = r * d.cols.length + c;
      const co = d.coeffs[i];
      const td = document.createElement("td");
      td.className = "matrix-cell";
      const chip = document.createElement("div");
      chip.className = "matrix-chip";
      const setChip = (v) => {
        chip.style.background = heatColor(v);
        chip.style.color = heatText(v);
        chip.textContent = (v / d.scale).toFixed(2);
      };
      setChip(co.signed);
      const sl = document.createElement("input");
      sl.type = "range"; sl.min = -255; sl.max = 255; sl.step = 1; sl.value = co.signed;
      sl.addEventListener("input", () => setChip(Number(sl.value)));
      sl.addEventListener("change", () => applyMatrixCoeff(i, Number(sl.value)));
      td.appendChild(chip);
      td.appendChild(sl);
      tr.appendChild(td);
    }
    tbl.appendChild(tr);
  }
  grid.appendChild(tbl);

  const sw = $("#matrix-swatches");
  sw.innerHTML = "";
  for (const s of d.swatches) {
    const row = document.createElement("div");
    row.className = "swatch-row";
    row.innerHTML =
      `<span class="nm">${s.name}</span>` +
      `<span class="swatch" style="background:${rgbCss(s.in)}" title="${s.in}"></span>` +
      `<span class="swatch-arrow">→</span>` +
      `<span class="swatch" style="background:${rgbCss(s.out)}" title="${s.out}"></span>`;
    sw.appendChild(row);
  }
}

async function loadMatrix() {
  try { renderMatrix(await api("/api/matrix")); }
  catch (e) { toast(e.message, "error"); }
}

async function applyMatrixCoeff(index, value) {
  try {
    renderMatrix(await postJSON("/api/matrix/coeff", { index, value }));
    toast("Matrix updated");
  } catch (e) { toast(e.message, "error"); loadMatrix(); }
}

// --------------------------------------------------------------------- raw
async function rawRead() {
  try {
    const addr = $("#raw-addr").value.trim();
    const { registers } = await api(`/api/raw?addr=${encodeURIComponent(addr)}&count=1`);
    const [k, v] = Object.entries(registers)[0];
    $("#raw-value").value = hex(v);
    $("#raw-result").textContent = `${k} = ${hex(v)} (${v})`;
  } catch (e) { toast(e.message, "error"); }
}

async function rawWrite() {
  try {
    const addr = $("#raw-addr").value.trim();
    const value = $("#raw-value").value.trim();
    const { registers } = await postJSON("/api/raw", { addr, value });
    const [k, v] = Object.entries(registers)[0];
    $("#raw-result").textContent = `wrote ${k} = ${hex(v)}`;
    toast(`Wrote ${k} = ${hex(v)}`);
    loadSettings();
  } catch (e) { toast(e.message, "error"); }
}

// -------------------------------------------------------------------- init
async function init() {
  $("#connect").addEventListener("click", connect);
  $("#disconnect").addEventListener("click", disconnect);
  $("#refresh-ports").addEventListener("click", loadPorts);
  $("#reload").addEventListener("click", loadSettings);
  document.querySelectorAll(".tab").forEach((b) => {
    b.addEventListener("click", () => showTab(b.dataset.tab));
  });
  $("#raw-read").addEventListener("click", rawRead);
  $("#raw-write").addEventListener("click", rawWrite);
  $("#matrix-autocc").addEventListener("change", async (e) => {
    try { renderMatrix(await postJSON("/api/matrix/contrast_center", { on: e.target.checked })); }
    catch (err) { toast(err.message, "error"); loadMatrix(); }
  });

  await loadPorts();
  // pull control metadata (and recover if the server is already connected)
  try {
    const st = await api("/api/state");
    CONTROLS = st.controls;
    if (st.connected) {
      lastConn = { port: st.port, baud: Number($("#baud").value), slave: st.slave };
      lastUptime = null;
      enterState(ST.CONNECTED, { port: st.port, slave: st.slave, pid: 0 });
      renderControls();
      await loadSettings();
    }
  } catch (e) { toast(e.message, "error"); }
}

document.addEventListener("DOMContentLoaded", init);
