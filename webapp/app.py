#!/usr/bin/env python3
"""Flask web app to control the OV7670 over the Tang Nano 9K Modbus bridge.

Pick a serial port, connect to the FPGA's Modbus RTU slave, read the live camera
settings, and change individual controls (brightness, gain, AWB, mirror, test
pattern, ...) or poke raw registers. Each control maps 1:1 to an OV7670 register
and every change is a live SCCB write on the device.

Run:
    pip install -r webapp/requirements.txt
    python webapp/app.py            # then open http://127.0.0.1:5000
"""

import os
import threading

from flask import Flask, Response, jsonify, render_template, request

import ov7670
from modbus_client import (FRAME_H, FRAME_W, ModbusError, ModbusRTU,
                           rgb565_to_rgba)

try:
    from serial.tools import list_ports
except ImportError:  # pragma: no cover - pyserial always ships list_ports
    list_ports = None

app = Flask(__name__)

# Single shared serial connection, serialized with a lock (the bus is a single
# physical resource and a transaction must complete before the next starts).
_lock = threading.Lock()
_client = None  # type: ModbusRTU | None


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _require_client():
    if _client is None:
        raise RuntimeError("not connected -- pick a port and connect first")
    return _client


def _read_snapshot(client):
    """Read every register the settings page needs into {addr: byte}."""
    return {addr: client.read_reg(addr) for addr in ov7670.needed_registers()}


def _apply_control(client, control, value):
    """Write a control change; return the affected {addr: byte} after writing."""
    ctype = control["type"]
    if ctype == "byte":
        v = int(value) & 0xFF
        client.write_reg(control["reg"], v)
        return {control["reg"]: client.read_reg(control["reg"])}

    if ctype == "bit":
        on = bool(value)
        reg, mask = control["reg"], control["mask"]
        cur = client.read_reg(reg)
        new = (cur | mask) if on else (cur & ~mask)
        client.write_reg(reg, new)
        return {reg: client.read_reg(reg)}

    if ctype == "gamma":
        g = float(value) / control.get("scale", 100)
        regs = ov7670.gamma_registers(g)
        for addr, v in regs.items():
            client.write_reg(addr, v)
        sample = control["sample_reg"]
        return {sample: client.read_reg(sample)}

    if ctype == "pattern":
        opt = next((o for o in control["options"] if o["id"] == value), None)
        if opt is None:
            raise ValueError(f"unknown pattern option {value!r}")
        xreg, yreg = ov7670.PATTERN_REGS
        affected = {}
        for reg, want in ((xreg, opt["xsc"]), (yreg, opt["ysc"])):
            cur = client.read_reg(reg)
            new = (cur | 0x80) if want else (cur & ~0x80)
            client.write_reg(reg, new)
            affected[reg] = client.read_reg(reg)
        return affected

    raise ValueError(f"unknown control type {ctype}")


def _error(msg, status=400):
    return jsonify(ok=False, error=str(msg)), status


def _classify(e):
    """Map a client-op exception to a response. If the serial port died
    (SerialException subclasses OSError), tear down the connection so /api/state
    reports disconnected and the UI can prompt a reconnect; transient
    timeouts/CRC are already retried in the client and just surface as errors."""
    global _client
    if isinstance(e, OSError):
        if _client is not None:
            _client.close()
            _client = None
        return _error(f"device disconnected: {e}", status=503)
    return _error(e)


# --------------------------------------------------------------------------- #
# routes
# --------------------------------------------------------------------------- #
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/ports")
def api_ports():
    ports = []
    seen = set()
    if list_ports is not None:
        for p in list_ports.comports():
            ports.append({"device": p.device, "description": p.description or ""})
            seen.add(p.device)
    # the project's stable symlink is handy and often not enumerated
    for extra in ("/dev/ttyGowin",):
        if os.path.exists(extra) and extra not in seen:
            ports.insert(0, {"device": extra, "description": "Tang Nano 9K (symlink)"})
    return jsonify(ok=True, ports=ports)


@app.route("/api/state")
def api_state():
    """Connection status + the control metadata the UI renders from."""
    connected = _client is not None
    return jsonify(
        ok=True,
        connected=connected,
        port=_client.port if connected else None,
        slave=_client.slave if connected else None,
        controls=ov7670.CONTROLS,
    )


@app.route("/api/health")
def api_health():
    """Cheap liveness probe for the heartbeat: firmware magic + uptime counter.
    The uptime is 0 at reset and free-runs, so a value that jumps backward tells
    the host the device was hard-reset (re-init wiped its register state)."""
    with _lock:
        try:
            client = _require_client()
            magic = client.read_reg(ov7670.STATUS_MAGIC_ADDR)
            hi, lo = client.read_holding(ov7670.STATUS_UPTIME_ADDR, 2)
            uptime = ((hi & 0xFF) << 8) | (lo & 0xFF)
        except ModbusError as e:
            # the device answered (so it's alive) but has no status registers --
            # an older bitstream without the bridge's reserved 0xF0..0xF2 block.
            return jsonify(ok=True, alive=True, status_supported=False, detail=str(e))
        except (RuntimeError, ValueError, TimeoutError, OSError) as e:
            return _classify(e)
    return jsonify(ok=True, alive=True, status_supported=True, magic=magic,
                   magic_ok=(magic == ov7670.STATUS_MAGIC), uptime=uptime)


@app.route("/api/connect", methods=["POST"])
def api_connect():
    global _client
    data = request.get_json(force=True, silent=True) or {}
    port = data.get("port")
    if not port:
        return _error("no port specified")
    baud = int(data.get("baud", 1000000))
    slave = int(data.get("slave", 7))
    timeout = float(data.get("timeout", 1.0))
    with _lock:
        if _client is not None:
            _client.close()
            _client = None
        try:
            client = ModbusRTU(port, baud=baud, slave=slave, timeout=timeout)
        except Exception as e:  # serial open failure
            return _error(f"cannot open {port}: {e}")
        try:
            pid = client.read_reg(ov7670.IDENTITY[0][0])  # sanity read (PID)
        except Exception as e:
            client.close()
            return _error(f"connected to {port} but no Modbus response: {e}")
        _client = client
    return jsonify(ok=True, port=port, slave=slave, pid=pid)


@app.route("/api/disconnect", methods=["POST"])
def api_disconnect():
    global _client
    with _lock:
        if _client is not None:
            _client.close()
            _client = None
    return jsonify(ok=True)


@app.route("/api/settings")
def api_settings():
    with _lock:
        try:
            client = _require_client()
            snapshot = _read_snapshot(client)
        except (RuntimeError, ModbusError, ValueError, TimeoutError, OSError) as e:
            return _classify(e)
    decoded = ov7670.decode_all(snapshot)
    return jsonify(ok=True, registers={f"0x{a:02X}": v for a, v in snapshot.items()},
                   **decoded)


@app.route("/api/control", methods=["POST"])
def api_control():
    data = request.get_json(force=True, silent=True) or {}
    cid = data.get("id")
    control = ov7670.CONTROLS_BY_ID.get(cid)
    if control is None:
        return _error(f"unknown control {cid!r}")
    if "value" not in data:
        return _error("no value")
    with _lock:
        try:
            client = _require_client()
            affected = _apply_control(client, control, data["value"])
        except (RuntimeError, ModbusError, ValueError, TimeoutError, OSError) as e:
            return _classify(e)
    return jsonify(ok=True, id=cid,
                   registers={f"0x{a:02X}": v for a, v in affected.items()})


@app.route("/api/gamma")
def api_gamma():
    """Preview the curve for an exponent (pure computation, no device needed).

    `value` is the scaled exponent (g * GAMMA_SCALE), matching the slider.
    """
    value = request.args.get("value")
    if value is None:
        return _error("no value")
    try:
        g = float(value) / ov7670.GAMMA_SCALE
    except ValueError:
        return _error(f"bad value {value!r}")
    regs = ov7670.gamma_registers(g)
    return jsonify(
        ok=True,
        exponent=round(g, 2),
        registers={f"0x{a:02X}": v for a, v in sorted(regs.items())},
        points=ov7670.gamma_curve_points(regs),
    )


@app.route("/api/gamma/device")
def api_gamma_device():
    """Read SLOP + GAM1..GAM15 from the device and reconstruct the curve."""
    with _lock:
        try:
            client = _require_client()
            regs = {a: client.read_reg(a) for a in ov7670.gamma_register_addrs()}
        except (RuntimeError, ModbusError, ValueError, TimeoutError, OSError) as e:
            return _classify(e)
    return jsonify(
        ok=True,
        exponent=round(ov7670.estimate_gamma(regs) / ov7670.GAMMA_SCALE, 2),
        registers={f"0x{a:02X}": v for a, v in sorted(regs.items())},
        points=ov7670.gamma_curve_points(regs),
    )


def _matrix_payload(client):
    """Read the matrix registers and build the full decoded/swatch payload."""
    snap = {a: client.read_reg(a) for a in ov7670.MTX_REGS + [ov7670.MTXS_REG]}
    signed, meta, mtxs = ov7670.decode_matrix(snap)
    return {
        "ok": True,
        "scale": ov7670.MTX_SCALE,
        "rows": ov7670.MATRIX_ROWS,
        "cols": ov7670.MATRIX_COLS,
        "coeffs": meta,
        "mtxs": mtxs,
        "auto_contrast": bool(mtxs & ov7670.MTXS_AUTO_CONTRAST),
        "registers": {f"0x{a:02X}": v for a, v in sorted(snap.items())},
        "swatches": ov7670.matrix_swatches(signed),
    }


@app.route("/api/matrix")
def api_matrix():
    with _lock:
        try:
            client = _require_client()
            payload = _matrix_payload(client)
        except (RuntimeError, ModbusError, ValueError, TimeoutError, OSError) as e:
            return _classify(e)
    return jsonify(payload)


@app.route("/api/matrix/coeff", methods=["POST"])
def api_matrix_coeff():
    data = request.get_json(force=True, silent=True) or {}
    try:
        index = int(data["index"])
        value = int(data["value"])
    except (KeyError, TypeError, ValueError):
        return _error("need integer index (0..5) and signed value")
    if not (0 <= index < len(ov7670.MTX_REGS)):
        return _error(f"index {index} out of range 0..5")
    mag = min(255, abs(value))
    with _lock:
        try:
            client = _require_client()
            client.write_reg(ov7670.MTX_REGS[index], mag)        # magnitude
            mtxs = client.read_reg(ov7670.MTXS_REG)              # sign bit (RMW)
            mtxs = (mtxs | (1 << index)) if value < 0 else (mtxs & ~(1 << index))
            client.write_reg(ov7670.MTXS_REG, mtxs)
            payload = _matrix_payload(client)
        except (RuntimeError, ModbusError, ValueError, TimeoutError, OSError) as e:
            return _classify(e)
    return jsonify(payload)


@app.route("/api/matrix/contrast_center", methods=["POST"])
def api_matrix_contrast_center():
    data = request.get_json(force=True, silent=True) or {}
    on = bool(data.get("on"))
    with _lock:
        try:
            client = _require_client()
            mtxs = client.read_reg(ov7670.MTXS_REG)
            mtxs = (mtxs | ov7670.MTXS_AUTO_CONTRAST) if on \
                else (mtxs & ~ov7670.MTXS_AUTO_CONTRAST)
            client.write_reg(ov7670.MTXS_REG, mtxs)
            payload = _matrix_payload(client)
        except (RuntimeError, ModbusError, ValueError, TimeoutError, OSError) as e:
            return _classify(e)
    return jsonify(payload)


@app.route("/api/grab", methods=["POST"])
def api_grab():
    """Capture a frame into ch1 and stream it back as raw RGBA for a canvas draw.

    Holds the bus lock for the whole ~10 s download (single physical resource),
    so the heartbeat just waits its turn. The body is FRAME_W*FRAME_H*4 bytes;
    width/height ship in headers so the client sizes its ImageData."""
    with _lock:
        try:
            client = _require_client()
            pixels = client.grab_frame()
        except (RuntimeError, ModbusError, ValueError, TimeoutError, OSError) as e:
            return _classify(e)
    body = rgb565_to_rgba(pixels)
    resp = Response(body, mimetype="application/octet-stream")
    resp.headers["X-Frame-Width"] = str(FRAME_W)
    resp.headers["X-Frame-Height"] = str(FRAME_H)
    return resp


@app.route("/api/raw", methods=["GET", "POST"])
def api_raw():
    with _lock:
        try:
            client = _require_client()
            if request.method == "GET":
                addr = int(request.args.get("addr", "0"), 0)
                count = int(request.args.get("count", "1"), 0)
                vals = client.read_holding(addr, count)
                regs = {f"0x{addr + i:02X}": (v & 0xFF) for i, v in enumerate(vals)}
                return jsonify(ok=True, registers=regs)
            data = request.get_json(force=True, silent=True) or {}
            addr = int(data["addr"]) if isinstance(data.get("addr"), int) \
                else int(str(data.get("addr")), 0)
            value = int(data["value"]) if isinstance(data.get("value"), int) \
                else int(str(data.get("value")), 0)
            client.write_reg(addr, value)
            return jsonify(ok=True, registers={f"0x{addr:02X}": client.read_reg(addr)})
        except (RuntimeError, ModbusError, ValueError, TimeoutError, OSError,
                KeyError, TypeError) as e:
            return _classify(e)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=False, threaded=True)
