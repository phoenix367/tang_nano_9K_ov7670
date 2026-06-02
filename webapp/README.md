# OV7670 Modbus control web app

A small Flask web app to control the OV7670 camera on the Tang Nano 9K over the
Modbus RTU bridge (FT2232H channel-B UART, 1 Mbaud 8-E-1, slave id 7). It exposes
the camera's registers through the FPGA's `modbus_rtu_slave` (Direct 1:1
mapping: holding-register address = OV7670 register number), so every control
change is a live SCCB write on the device.

Features:

- **Pick a serial port** (auto-detected, plus the project's `/dev/ttyGowin`
  symlink) and connect; the connect step sanity-reads the Product ID.
- **Tabbed UI** once connected: a **Basic controls** tab (identity, controls,
  raw register access), a **Color** tab (gamma curve + color matrix), and a
  **Capture** tab (grab a 640×480 frame into PSRAM ch1, stream it back over
  Modbus, draw it to a canvas, save as PNG).
- **Read camera settings** — identity registers (PID/VER/MIDH/MIDL) and the
  decoded value of every control.
- **Change specific controls** — brightness, contrast, gain, exposure, the
  AGC/AWB/AEC auto modes, mirror/flip, negative, night mode, gamma correction
  (on/off + a gamma-curve slider that generates SLOP + GAM1..GAM15 from one
  exponent), and the test pattern selector. Bit-field controls are applied
  read-modify-write.
- **Gamma curve block** — enable toggle + a gamma-exponent slider, an SVG plot
  of the live curve, and the SLOP/GAM register values.
- **Color matrix block** — the 2×3 chroma matrix (MTX1..6 + MTXS) as a signed
  heatmap grid with per-cell sliders, an auto-contrast toggle, and before→after
  reference color swatches.
- **Raw register access** — read/write any OV7670 register by address.
- **Reset resilience** — a heartbeat (`/api/health`) polls the bridge's status
  registers (`0xF0` magic, `0xF1/0xF2` uptime). If the board is hard-reset the
  uptime jumps backward → the UI resyncs to the (re-initialised) register state.
  If the serial port drops (power-cycle / re-flash) the app shows a banner and
  auto-reconnects when it returns. Transient timeouts (e.g. the post-reset
  re-init window) are retried in the client. Falls back gracefully on an older
  bitstream without the status registers (liveness only, no reset detection).

## Run

```bash
pip install -r webapp/requirements.txt
python webapp/app.py
# open http://127.0.0.1:5000
```

The device node must be readable/writable by your user. The project's udev rule
(`udev/99-gowin-ft2232h.rules`) makes `/dev/ttyGowin` world rw; otherwise run as
a user in the `dialout` group or pick the right `/dev/ttyUSB*`.

## Tests

The `ModbusRTU` client is backed by [pymodbus](https://pymodbus.readthedocs.io)
(`ModbusSerialClient`, RTU framer) so framing/CRC come from a spec-compliant
library; this module is a thin device-specific wrapper around it.

A pytest suite under `tests/` runs **without hardware** — a fake in-memory Modbus
slave (`tests/fake_modbus.py`) is wired in as pymodbus's serial transport (it
emits real RTU frames), so the pymodbus-backed client and the Flask routes are
exercised end-to-end.

```bash
pip install -r webapp/requirements-dev.txt
cd webapp && python -m pytest tests -q
```

Coverage:

- `test_modbus_client.py` — FC03/06, exceptions, comms-fault → error mapping,
  frame-grab loop, OSD, register R/W.
- `test_ov7670.py` — register set, decode, gamma-curve math, color-matrix
  decode/transform.
- `test_app.py` — every API route plus the not-connected / Modbus-exception /
  device-lost (503) error paths.
- `test_device_hw.py` and `test_device_conformance.py` — **host-in-the-loop**
  tests against a real board (the wrapper, and a vanilla-pymodbus conformance
  check). Skipped unless `OV7670_PORT` is set; see [doc/testing.md](../doc/testing.md).

## Linting

Python is linted with [Ruff](https://docs.astral.sh/ruff/) (config in the repo
root `ruff.toml`, covering `webapp/` and `scripts/`); the browser JS is linted
with [ESLint](https://eslint.org/) (`eslint.config.mjs`). Both run in CI
(`.github/workflows/lint.yml`).

```bash
pip install -r webapp/requirements-dev.txt && ruff check .   # from the repo root
cd webapp && npm install && npm run lint                     # JS
```

## Layout

| File | Purpose |
|------|---------|
| `app.py` | Flask app + REST API (`/api/ports`, `/api/connect`, `/api/settings`, `/api/control`, `/api/raw`). |
| `modbus_client.py` | Modbus RTU master over pyserial (CRC-16 + FC03/FC06). |
| `ov7670.py` | Register map + declarative control model (matches `src/ov7670_regs.vh`). |
| `templates/index.html`, `static/` | Single-page UI (vanilla JS). |

## Notes

- The bridge is single-master: the app keeps one serial connection, serialized
  with a lock. Run a single instance.
- An FC03 read burst is capped at ~13 registers by the slave's `MAX_FRAME`; the
  app reads the settings registers individually, well under that.
- Writing COM7 (`0x12`) with the reset bit set will reset the camera; the curated
  controls avoid it, but the raw panel does not guard against it.
