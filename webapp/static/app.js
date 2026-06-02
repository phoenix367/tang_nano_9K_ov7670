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
    $("#tab-capture").hidden = true;
    clearGrabCanvas();          // drop any grabbed frame from a prior session
    $("#board-health").hidden = true;
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
  for (const t of ["basic", "color", "capture", "overlay"]) $("#tab-" + t).hidden = (t !== name);
  document.querySelectorAll(".tab").forEach((b) => {
    b.classList.toggle("active", b.dataset.tab === name);
  });
  if (name === "color") resizeGammaPlot();   // table height is known once visible
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
    currentTab = "basic";       // a fresh connection lands on Basic controls
    enterState(ST.CONNECTED, info);
    renderControls();
    await loadSettings();
    loadOsdState();
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
  renderHealth(data.status_supported ? data.health : null);
}

function setChip(el, state, text) {
  el.textContent = text;
  el.className = "health-chip " + state;     // state: ok | bad | idle
}

function renderHealth(health) {
  const box = $("#board-health");
  if (!health) { box.hidden = true; return; }
  box.hidden = false;
  const mon = !!health.monitoring;
  setChip($("#health-overall"),
          health.any_hang ? "bad" : (mon ? "ok" : "idle"),
          health.any_hang ? "HANG" : (mon ? "Healthy" : "starting…"));
  const sub = (el, label, hang) => setChip(el, !mon ? "idle" : (hang ? "bad" : "ok"), label);
  sub($("#health-lcd"), "LCD", health.lcd_hang);
  sub($("#health-mem"), "Memory", health.memory_hang);
  sub($("#health-cam"), "Camera", health.camera_hang);
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

  const S = 320, pad = 36, plot = S - 2 * pad;   // bigger plot, ~matches the table height
  const sx = (x) => pad + (x / 255) * plot;
  const sy = (y) => pad + plot - (y / 255) * plot;
  const poly = points.map((p) => `${sx(p[0]).toFixed(1)},${sy(p[1]).toFixed(1)}`).join(" ");
  // knee markers = the 15 breakpoints (skip the origin [0] and the 255 endpoint)
  const knees = points.slice(1, points.length - 1)
    .map((p) => `<circle class="gamma-knee" cx="${sx(p[0]).toFixed(1)}" cy="${sy(p[1]).toFixed(1)}" r="2.5"/>`)
    .join("");

  $("#gamma-plot").innerHTML = `
    <svg viewBox="0 0 ${S} ${S}" width="${S}" height="${S}" role="img" aria-label="gamma curve">
      <line class="gamma-axis" x1="${pad}" y1="${pad}" x2="${pad}" y2="${pad + plot}"/>
      <line class="gamma-axis" x1="${pad}" y1="${pad + plot}" x2="${pad + plot}" y2="${pad + plot}"/>
      <line class="gamma-ref" x1="${sx(0)}" y1="${sy(0)}" x2="${sx(255)}" y2="${sy(255)}"/>
      <polyline class="gamma-line" points="${poly}"/>
      ${knees}
      <text class="gamma-label" x="${pad - 4}" y="${pad + 3}" text-anchor="end">255</text>
      <text class="gamma-label" x="${pad - 4}" y="${pad + plot}" text-anchor="end">0</text>
      <text class="gamma-label" x="${pad + plot}" y="${pad + plot + 14}" text-anchor="end">in 255</text>
      <text class="gamma-label" x="${pad}" y="${pad + plot + 14}" text-anchor="middle">0</text>
      <text class="gamma-label" x="11" y="${pad + plot / 2}" text-anchor="middle"
            transform="rotate(-90 11 ${pad + plot / 2})">out</text>
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
  resizeGammaPlot();   // size the plot square to the (now-rendered) table height
}

// Match the gamma plot's size to the register table. The table has zero height
// while the Color tab is hidden, so this is also re-run when the tab is shown.
function resizeGammaPlot() {
  const svg = document.querySelector("#gamma-plot svg");
  const h = $("#gamma-regs").offsetHeight;
  if (svg && h > 0) {
    svg.setAttribute("width", h);
    svg.setAttribute("height", h);
  }
}

async function previewGamma(value) {
  try {
    const d = await api(`/api/gamma?value=${encodeURIComponent(value)}`);
    renderGammaCurve(d.points, d.registers, `preview — γ ${d.exponent.toFixed(2)} (not yet applied)`);
  } catch { /* preview is best-effort */ }
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

// ---- CIE 1931 chromaticity diagram ----------------------------------------
// Spectral locus (2° observer): [wavelength_nm, x, y]. The closing edge back to
// 380 nm is the (non-spectral) line of purples.
const SPECTRAL_LOCUS = [
  [380, 0.1741, 0.0050], [400, 0.1733, 0.0048], [420, 0.1714, 0.0051],
  [440, 0.1644, 0.0109], [460, 0.1440, 0.0297], [470, 0.1241, 0.0578],
  [480, 0.0913, 0.1327], [490, 0.0454, 0.2950], [500, 0.0082, 0.5384],
  [510, 0.0139, 0.7502], [520, 0.0743, 0.8338], [530, 0.1547, 0.8059],
  [540, 0.2296, 0.7543], [550, 0.3016, 0.6923], [560, 0.3731, 0.6245],
  [570, 0.4441, 0.5547], [580, 0.5125, 0.4866], [590, 0.5752, 0.4242],
  [600, 0.6270, 0.3725], [610, 0.6658, 0.3340], [620, 0.6915, 0.3083],
  [630, 0.7079, 0.2920], [640, 0.7190, 0.2809], [650, 0.7260, 0.2740],
  [700, 0.7347, 0.2653],
];
const SRGB_PRIMARIES = [[0.64, 0.33], [0.30, 0.60], [0.15, 0.06]];  // R, G, B
const D65 = [0.3127, 0.3290];
const SVG_NS = "http://www.w3.org/2000/svg";

const srgbToLinear = (c) => (c /= 255, c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);

function rgbToXy(r, g, b) {                       // sRGB (D65) -> CIE xy
  const R = srgbToLinear(r), G = srgbToLinear(g), B = srgbToLinear(b);
  const X = 0.4124 * R + 0.3576 * G + 0.1805 * B;
  const Y = 0.2126 * R + 0.7152 * G + 0.0722 * B;
  const Z = 0.0193 * R + 0.1192 * G + 0.9505 * B;
  const s = X + Y + Z;
  return s <= 0 ? D65.slice() : [X / s, Y / s];   // black -> white point
}

function wavelengthToRgb(wl) {                     // Bruton approximation, vivid
  let r = 0, g = 0, b = 0;
  if (wl < 440) { r = -(wl - 440) / 60; b = 1; }
  else if (wl < 490) { g = (wl - 440) / 50; b = 1; }
  else if (wl < 510) { g = 1; b = -(wl - 510) / 20; }
  else if (wl < 580) { r = (wl - 510) / 70; g = 1; }
  else if (wl < 645) { r = 1; g = -(wl - 645) / 65; }
  else { r = 1; }
  return [r, g, b].map((c) => Math.round(Math.max(0, Math.min(1, c)) * 255));
}

function svgEl(tag, attrs, text) {
  const e = document.createElementNS(SVG_NS, tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (text != null) e.textContent = text;
  return e;
}

// diagram geometry (viewBox units) and chromaticity <-> pixel mappings
const CHROMA = { W: 240, H: 240, pad: 22, XMAX: 0.75, YMAX: 0.85 };
const chromaPx = (x) => CHROMA.pad + (x / CHROMA.XMAX) * (CHROMA.W - 2 * CHROMA.pad);
const chromaPy = (y) => (CHROMA.H - CHROMA.pad) - (y / CHROMA.YMAX) * (CHROMA.H - 2 * CHROMA.pad);
const chromaInvX = (sx) => ((sx - CHROMA.pad) / (CHROMA.W - 2 * CHROMA.pad)) * CHROMA.XMAX;
const chromaInvY = (sy) => ((CHROMA.H - CHROMA.pad - sy) / (CHROMA.H - 2 * CHROMA.pad)) * CHROMA.YMAX;
const clampCoeff = (v) => Math.max(-255, Math.min(255, v));
const clamp8 = (v) => Math.max(0, Math.min(255, Math.round(v)));

// JS mirror of ov7670.matrix_apply: 2x3 chroma matrix + BT.601 luma -> sRGB.
function matrixApply(signed, r, g, b) {
  const y = 0.299 * r + 0.587 * g + 0.114 * b;
  const cr = (signed[0] * r + signed[1] * g + signed[2] * b) / 256;
  const cb = (signed[3] * r + signed[4] * g + signed[5] * b) / 256;
  return [clamp8(y + 1.402 * cr), clamp8(y - 0.344 * cb - 0.714 * cr), clamp8(y + 1.772 * cb)];
}

// Draggable primaries: input RGB key -> its [Cr-coeff, Cb-coeff] column indices.
const PRIMARY_COLS = { "255,0,0": [0, 3], "0,255,0": [1, 4], "0,0,255": [2, 5] };
let MATRIX_STATE = null;       // last matrix payload (mutated live while dragging)
let chromaDrag = null;

// A primary's output depends only on its own column, so its chromaticity is a
// 2->2 function of (Cr-coeff, Cb-coeff). The map has clamped plateaus (the output
// jams in a cube corner), so a local solver gets stuck; a small grid search over
// the 2-D coefficient space is robust. A light pull toward the current values
// (a0,b0) breaks ties on a plateau, keeping the drag stable.
function solvePrimaryCoeffs(inRgb, target, a0, b0) {
  const y = 0.299 * inRgb[0] + 0.587 * inRgb[1] + 0.114 * inRgb[2];
  const ch = Math.max(...inRgb);                    // the 255 channel
  const fwd = (a, b) => {
    const cr = (a * ch) / 256, cb = (b * ch) / 256;
    return rgbToXy(clamp8(y + 1.402 * cr), clamp8(y - 0.344 * cb - 0.714 * cr), clamp8(y + 1.772 * cb));
  };
  let best = [a0, b0], bestCost = Infinity;
  const consider = (a, b) => {
    const f = fwd(a, b);
    const cost = (f[0] - target[0]) ** 2 + (f[1] - target[1]) ** 2
      + 1e-7 * ((a - a0) ** 2 + (b - b0) ** 2);
    if (cost < bestCost) { bestCost = cost; best = [a, b]; }
  };
  for (let a = -255; a <= 255; a += 15) for (let b = -255; b <= 255; b += 15) consider(a, b);
  const [ca, cb] = best;                            // refine around the coarse best
  bestCost = Infinity;
  for (let a = Math.max(-255, ca - 15); a <= Math.min(255, ca + 15); a += 2)
    for (let b = Math.max(-255, cb - 15); b <= Math.min(255, cb + 15); b += 2) consider(a, b);
  return [clampCoeff(Math.round(best[0])), clampCoeff(Math.round(best[1]))];
}

function setCoeffMeta(meta, signed) {
  meta.signed = signed; meta.raw = Math.abs(signed);
  meta.neg = signed < 0; meta.value = Math.round((signed / 256) * 1000) / 1000;
}

function chromaPointerMove(ev) {
  if (!chromaDrag || !MATRIX_STATE) return;
  const r = $("#chroma-svg").getBoundingClientRect();
  const sx = ((ev.clientX - r.left) / r.width) * CHROMA.W;
  const sy = ((ev.clientY - r.top) / r.height) * CHROMA.H;
  const tx = Math.max(0, Math.min(CHROMA.XMAX, chromaInvX(sx)));
  const ty = Math.max(0, Math.min(CHROMA.YMAX, chromaInvY(sy)));
  const [ci, cj] = chromaDrag.cols;
  const signed = MATRIX_STATE.coeffs.map((c) => c.signed);
  const [na, nb] = solvePrimaryCoeffs(chromaDrag.in, [tx, ty], signed[ci], signed[cj]);
  setCoeffMeta(MATRIX_STATE.coeffs[ci], na);
  setCoeffMeta(MATRIX_STATE.coeffs[cj], nb);
  const cur = MATRIX_STATE.coeffs.map((c) => c.signed);
  MATRIX_STATE.swatches = MATRIX_STATE.swatches.map((s) => ({ ...s, out: matrixApply(cur, ...s.in) }));
  renderMatrix(MATRIX_STATE);                        // live: grid + diagram follow
}

async function chromaPointerUp() {
  window.removeEventListener("pointermove", chromaPointerMove);
  window.removeEventListener("pointerup", chromaPointerUp);
  const drag = chromaDrag; chromaDrag = null;
  if (!drag || !MATRIX_STATE) return;
  const [ci, cj] = drag.cols;                        // write the two changed coeffs
  const updates = [[ci, MATRIX_STATE.coeffs[ci].signed], [cj, MATRIX_STATE.coeffs[cj].signed]];
  try {
    let payload;
    for (const [index, value] of updates) payload = await postJSON("/api/matrix/coeff", { index, value });
    renderMatrix(payload);
    toast("Matrix updated");
  } catch (e) { toast(e.message, "error"); loadMatrix(); }
}

function renderChroma(swatches) {
  const el = $("#chroma-svg");
  if (!el) return;
  el.innerHTML = "";
  const px = chromaPx, py = chromaPy, { XMAX, YMAX } = CHROMA;

  // faint fill of the visible-gamut horseshoe
  const locusPts = SPECTRAL_LOCUS.map(([, x, y]) => `${px(x)},${py(y)}`).join(" ");
  el.appendChild(svgEl("polygon", { points: locusPts, fill: "#11161c" }));
  // axes
  el.appendChild(svgEl("line", { x1: px(0), y1: py(0), x2: px(XMAX), y2: py(0), stroke: "#2c3744" }));
  el.appendChild(svgEl("line", { x1: px(0), y1: py(0), x2: px(0), y2: py(YMAX), stroke: "#2c3744" }));
  el.appendChild(svgEl("text", { x: px(XMAX), y: py(0) + 12, fill: "#8a97a6", "font-size": 9, "text-anchor": "end" }, "x"));
  el.appendChild(svgEl("text", { x: px(0) - 6, y: py(YMAX) + 3, fill: "#8a97a6", "font-size": 9, "text-anchor": "end" }, "y"));
  // spectral locus, coloured by wavelength
  for (let i = 0; i < SPECTRAL_LOCUS.length - 1; i++) {
    const [w, x, y] = SPECTRAL_LOCUS[i], [, x2, y2] = SPECTRAL_LOCUS[i + 1];
    el.appendChild(svgEl("line", {
      x1: px(x), y1: py(y), x2: px(x2), y2: py(y2),
      stroke: rgbCss(wavelengthToRgb(w)), "stroke-width": 2,
    }));
  }
  // line of purples
  const a = SPECTRAL_LOCUS[SPECTRAL_LOCUS.length - 1], b0 = SPECTRAL_LOCUS[0];
  el.appendChild(svgEl("line", { x1: px(a[1]), y1: py(a[2]), x2: px(b0[1]), y2: py(b0[2]), stroke: "#9a4fd0", "stroke-width": 2 }));
  // sRGB gamut triangle + white point
  el.appendChild(svgEl("polygon", {
    points: SRGB_PRIMARIES.map((p) => `${px(p[0])},${py(p[1])}`).join(" "),
    fill: "none", stroke: "#8a97a6", "stroke-width": 1, "stroke-dasharray": "3 2",
  }));
  el.appendChild(svgEl("path", {
    d: `M${px(D65[0]) - 3},${py(D65[1])}h6M${px(D65[0])},${py(D65[1]) - 3}v6`,
    stroke: "#d7e0ea", "stroke-width": 1,
  }));
  // each reference colour: before (hollow) -> after (filled); primaries draggable
  for (const s of swatches) {
    const [ix, iy] = rgbToXy(...s.in), [ox, oy] = rgbToXy(...s.out);
    const cols = PRIMARY_COLS[s.in.join(",")];
    el.appendChild(svgEl("line", { x1: px(ix), y1: py(iy), x2: px(ox), y2: py(oy), stroke: "#d7e0ea", "stroke-width": 1, opacity: 0.45 }));
    el.appendChild(svgEl("circle", { cx: px(ix), cy: py(iy), r: 3, fill: "none", stroke: rgbCss(s.in), "stroke-width": 1.5 }));
    const dot = svgEl("circle", {
      cx: px(ox), cy: py(oy), r: cols ? 4.5 : 3.4, fill: rgbCss(s.out),
      stroke: cols ? "#d7e0ea" : "#0f1419", "stroke-width": cols ? 1.4 : 0.8,
    });
    if (cols) {
      dot.style.cursor = "grab";
      dot.setAttribute("data-primary", s.name);
      dot.addEventListener("pointerdown", (ev) => {
        ev.preventDefault();
        chromaDrag = { cols, in: s.in };
        window.addEventListener("pointermove", chromaPointerMove);
        window.addEventListener("pointerup", chromaPointerUp);
      });
    }
    dot.appendChild(svgEl("title", {}, `${s.name}: ${s.in} → ${s.out}${cols ? "  (drag to retune)" : ""}`));
    el.appendChild(dot);
  }
}

function renderMatrix(d) {
  MATRIX_STATE = d;
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

  renderChroma(d.swatches);
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

async function dumpRegisters() {
  const btn = $("#raw-dump");
  btn.disabled = true;
  try {
    const data = await api("/api/dump");          // { ok, registers: {"0x00": int, ...} }
    const registers = {};
    for (const [addr, v] of Object.entries(data.registers)) registers[addr] = hex(v);
    const dump = {
      description: "OV7670 camera register dump (addresses 0x00–0xC9, 8-bit hex values)",
      registers,
    };
    const blob = new Blob([JSON.stringify(dump, null, 2) + "\n"], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "ov7670_registers.json";
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
    toast(`Dumped ${Object.keys(registers).length} registers`);
  } catch (e) {
    toast(e.message, "error");
  } finally {
    btn.disabled = false;
  }
}

async function resetDefaults() {
  if (!window.confirm("Re-run the camera initialization? This resets every "
                      + "register to its default and discards live tweaks.")) return;
  const btn = $("#raw-reset");
  btn.disabled = true;
  try {
    await postJSON("/api/reset_defaults", {});
    toast("Re-running camera init…");
    // the device reloads its ROM config over the next tens of ms; give it a
    // moment, then re-read the (reverted) register state.
    setTimeout(async () => {
      try { await loadSettings(); toast("Camera reset to defaults"); }
      catch (e) { toast(e.message, "error"); }
      btn.disabled = false;
    }, 700);
  } catch (e) {
    toast(e.message, "error");
    btn.disabled = false;
  }
}

// --------------------------------------------------------------- OSD overlay
async function loadOsdState() {
  try {
    const { enabled } = await api("/api/osd");
    $("#osd-enable").checked = !!enabled;
  } catch { /* not connected yet — leave the checkbox as-is */ }
}

const OSD_COLS = 60, OSD_ROWS = 17;

function osdLines() {
  return $("#osd-text").value.split("\n").slice(0, OSD_ROWS).map((l) => l.slice(0, OSD_COLS));
}

// Cap the editor to OSD_ROWS lines of OSD_COLS chars, preserving the caret.
function clampOsd() {
  const ta = $("#osd-text");
  const pos = ta.selectionStart;
  const clamped = osdLines().join("\n");
  if (clamped !== ta.value) {
    ta.value = clamped;
    const p = Math.min(pos, clamped.length);
    ta.selectionStart = ta.selectionEnd = p;
  }
  updateOsdCount();
}

function updateOsdCount() {
  const lines = $("#osd-text").value.split("\n");
  const longest = lines.reduce((m, l) => Math.max(m, l.length), 0);
  $("#osd-count").textContent = `${Math.min(lines.length, OSD_ROWS)}/${OSD_ROWS} rows · ${longest}/${OSD_COLS} cols`;
}

function insertOsdChar(ch) {
  const ta = $("#osd-text");
  const s = ta.selectionStart, e = ta.selectionEnd;
  ta.value = ta.value.slice(0, s) + ch + ta.value.slice(e);
  ta.selectionStart = ta.selectionEnd = s + ch.length;
  clampOsd();
  ta.focus();
}

// Box-drawing / block pseudographics — keep in sync with webapp/osd_charset.py
// (the font ROM carries these in the C1 range; the server encodes them to bytes).
const OSD_PSEUDO = [
  "─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼",
  "═", "║", "╔", "╗", "╚", "╝", "╠", "╣", "╦", "╩", "╬",
  "█", "▀", "▄", "▌", "▐", "░", "▒", "▓", "■", "·",
];

function addGlyphButton(grid, ch, title) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = "glyph";
  b.textContent = ch;
  b.title = title;
  b.addEventListener("click", () => insertOsdChar(ch));
  grid.appendChild(b);
}

// Palettes of glyphs the OSD font can render but are awkward/impossible to type:
// special Latin-1 symbols (0xA1..0xFF) and box-drawing/block pseudographics.
function buildOsdPalette() {
  const sym = $("#osd-symbols");
  if (sym && !sym.childElementCount) {
    for (let code = 0xA1; code <= 0xFF; code++) {
      const ch = String.fromCharCode(code);
      addGlyphButton(sym, ch, `0x${code.toString(16).toUpperCase()} (${code})`);
    }
  }
  const ps = $("#osd-pseudo");
  if (ps && !ps.childElementCount) {
    for (const ch of OSD_PSEUDO) addGlyphButton(ps, ch, ch);
  }
}

async function sendOsd() {
  const btn = $("#osd-send");
  btn.disabled = true;
  try {
    const lines = osdLines();
    await postJSON("/api/osd", { clear: true, lines, enabled: $("#osd-enable").checked });
    $("#osd-status").textContent = `Sent ${lines.length} line(s) to the display.`;
    toast("Overlay updated");
  } catch (e) { toast(e.message, "error"); }
  finally { btn.disabled = false; }
}

// A tree sparrow in line-art style, modelled on a real reference: a plump
// egg-shaped body, head tucked at the upper-left with a '<' beak and 'o' eye, a
// dark stippled back/wing (░▒ shading) over a pale open belly, and the
// characteristic barred tail (\\ feathers) sweeping down to the lower-right,
// standing on two feet. Drawn only with characters the OSD font renders.
const OSD_SPARROW = [
  "             _.-\"\"-._",
  "           .'     ░░░ `.",
  "          /    ░░▒▒▒▒▒  `.",
  "         <  o ░▒▒▒▒▒▒▒▒   `.",
  "          \\ .   ░▒▒▒▒▒▒▒▒▒   `.",
  "          |    ░▒▒▒▒▒▒▒▒▒▒▒   `._",
  "          |     ░▒▒▒▒▒▒▒▒▒▒▒░    `-._",
  "           \\    ░▒▒▒▒▒▒▒▒▒░ \\\\\\\\\\   `-._",
  "            \\     ░▒▒▒▒▒▒░ \\\\\\\\\\\\\\\\\\\\\\   `-._",
  "             \\     ░░▒▒░  \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\   `-._",
  "              `.    ░░  \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\  `>",
  "                `._    \\\\\\\\\\\\\\\\\\\\\\\\______,,..--''`",
  "                  `--..___,,..--'``",
  "                   |    |",
  "                   |    |",
  "                  _/\\__/\\_",
].join("\n");

// A car (side view) in line-art style: cabin with windshield pillars, body, and
// two wheels tucked into arches. Drawn only with characters the OSD font renders.
const OSD_CAR = [
  "                  ______",
  "               __/      \\___",
  "           ___/   |  |      \\____",
  "          /       |  |           \\",
  "    _____/    _________________    \\_____",
  "   |         /                 \\         |",
  "   |    ____/                   \\____     |",
  "   |   /    \\                   /    \\    |",
  "   '--|  ()  |-----------------|  ()  |--'",
  "       \\____/                   \\____/",
].join("\n");

// Load a piece of ASCII art into the editor, enable the overlay, and send it.
async function drawArt(art) {
  $("#osd-text").value = art;
  $("#osd-enable").checked = true;
  clampOsd();
  await sendOsd();
}

async function clearOsd() {
  try {
    await postJSON("/api/osd", { clear: true });
    $("#osd-text").value = "";
    updateOsdCount();
    $("#osd-status").textContent = "Overlay cleared.";
    toast("Overlay cleared");
  } catch (e) { toast(e.message, "error"); }
}

async function toggleOsd() {
  const on = $("#osd-enable").checked;
  try {
    await postJSON("/api/osd", { enabled: on });
    toast(on ? "Overlay shown" : "Overlay hidden");
  } catch (e) { toast(e.message, "error"); $("#osd-enable").checked = !on; }
}

// ------------------------------------------------------------- frame capture
function setGrabProgress(pct, label) {
  $("#grab-progress-bar").style.width = pct + "%";
  $("#grab-progress-text").textContent = label;
}

function clearGrabCanvas() {
  const c = $("#grab-canvas");
  if (c) c.getContext("2d").clearRect(0, 0, c.width, c.height);
  $("#grab-save").hidden = true;
  const st = $("#grab-status");
  st.textContent = "Grab a 640×480 frame from PSRAM channel 1.";
  st.className = "status";
}

async function pollGrabProgress() {
  const { data } = await rawFetch("/api/grab/status");
  if (!data || !data.ok || !data.active || !data.total) return;
  const pct = Math.min(100, Math.floor((100 * data.done) / data.total));
  setGrabProgress(pct, `${pct}% — ${data.done.toLocaleString()} / ${data.total.toLocaleString()} px`);
}

async function cancelGrab() {
  const c = $("#grab-cancel");
  c.disabled = true;
  c.textContent = "Cancelling…";
  try { await fetch("/api/grab/cancel", { method: "POST" }); } catch { /* best effort */ }
}

async function grabFrame() {
  const btn = $("#grab"), status = $("#grab-status"), save = $("#grab-save");
  const modal = $("#grab-modal"), cancelBtn = $("#grab-cancel");
  btn.disabled = true;
  save.hidden = true;
  status.textContent = "Capturing & downloading…";
  status.className = "status";
  setGrabProgress(0, "0%");
  cancelBtn.disabled = false;
  cancelBtn.textContent = "Cancel";
  modal.hidden = false;
  // the download holds the bus for ~10 s; pause the heartbeat so health probes
  // don't pile up behind it on the server-side lock, and poll the grab's own
  // progress endpoint (no bus access) to drive the bar.
  stopHeartbeat();
  const poll = setInterval(pollGrabProgress, 200);
  const t0 = performance.now();
  try {
    const res = await fetch("/api/grab", { method: "POST" });
    if (!res.ok) {
      let body = {};
      try { body = await res.json(); } catch { /* binary/none */ }
      if (body.cancelled) {
        status.textContent = "Grab cancelled.";
        status.className = "status";
        toast("Grab cancelled");
        return;
      }
      throw new Error(body.error || `HTTP ${res.status}`);
    }
    const w = Number(res.headers.get("X-Frame-Width")) || 640;
    const h = Number(res.headers.get("X-Frame-Height")) || 480;
    const buf = new Uint8ClampedArray(await res.arrayBuffer());
    const canvas = $("#grab-canvas");
    canvas.width = w; canvas.height = h;
    canvas.getContext("2d").putImageData(new ImageData(buf, w, h), 0, 0);
    setGrabProgress(100, "100%");
    const secs = ((performance.now() - t0) / 1000).toFixed(1);
    status.textContent = `Captured ${w}×${h} in ${secs}s.`;
    status.className = "status connected";
    save.href = canvas.toDataURL("image/png");
    save.hidden = false;
    toast("Frame captured");
  } catch (e) {
    status.textContent = "Grab failed: " + e.message;
    status.className = "status error";
    toast(e.message, "error");
  } finally {
    clearInterval(poll);
    modal.hidden = true;
    btn.disabled = false;
    if (connState === ST.CONNECTED) startHeartbeat();
  }
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
  $("#raw-reset").addEventListener("click", resetDefaults);
  $("#raw-dump").addEventListener("click", dumpRegisters);
  $("#grab").addEventListener("click", grabFrame);
  $("#grab-cancel").addEventListener("click", cancelGrab);
  $("#osd-send").addEventListener("click", sendOsd);
  $("#osd-clear").addEventListener("click", clearOsd);
  $("#osd-sparrow").addEventListener("click", () => drawArt(OSD_SPARROW));
  $("#osd-car").addEventListener("click", () => drawArt(OSD_CAR));
  $("#osd-enable").addEventListener("change", toggleOsd);
  $("#osd-text").addEventListener("input", clampOsd);
  buildOsdPalette();
  updateOsdCount();
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
      loadOsdState();
    }
  } catch (e) { toast(e.message, "error"); }
}

document.addEventListener("DOMContentLoaded", init);
