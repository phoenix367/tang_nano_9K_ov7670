"""Tests for the Flask API: routes, control/gamma/matrix endpoints, and the
error-classification paths (not-connected, Modbus exception, disconnect)."""


def _connect(tc):
    return tc.post("/api/connect", json={"port": "fake"}).get_json()


# ------------------------------------------------------------------ basics
def test_ports(client):
    tc, _ = client
    r = tc.get("/api/ports").get_json()
    assert r["ok"] and isinstance(r["ports"], list)


def test_state_disconnected(client):
    tc, _ = client
    r = tc.get("/api/state").get_json()
    assert r["ok"] and r["connected"] is False
    assert isinstance(r["controls"], list) and r["controls"]


def test_connect_then_state(client):
    tc, _ = client
    assert _connect(tc)["pid"] == 0x76
    r = tc.get("/api/state").get_json()
    assert r["connected"] is True and r["port"] == "fake"


def test_settings(client):
    tc, _ = client
    _connect(tc)
    r = tc.get("/api/settings").get_json()
    assert r["ok"]
    ident = {row["addr"]: row for row in r["identity"]}
    assert ident[0x0A]["ok"] and ident[0x0A]["value"] == 0x76
    assert r["controls"]["agc"] is True
    assert r["registers"]["0x0A"] == 0x76


def test_control_byte(client):
    tc, fake = client
    _connect(tc)
    r = tc.post("/api/control", json={"id": "brightness", "value": 200}).get_json()
    assert r["ok"]
    assert fake["slave"].regs[0x55] == 200


def test_control_bit_rmw(client):
    tc, fake = client
    _connect(tc)
    tc.post("/api/control", json={"id": "mirror", "value": True})
    assert fake["slave"].regs[0x1E] & 0x20            # MVFP mirror bit set
    tc.post("/api/control", json={"id": "mirror", "value": False})
    assert not (fake["slave"].regs[0x1E] & 0x20)      # cleared, neighbours preserved


def test_control_pattern(client):
    tc, fake = client
    _connect(tc)
    tc.post("/api/control", json={"id": "pattern", "value": "colorbar"})
    assert fake["slave"].regs[0x71] & 0x80
    tc.post("/api/control", json={"id": "pattern", "value": "none"})
    assert not (fake["slave"].regs[0x71] & 0x80)


def test_control_unknown_id(client):
    tc, _ = client
    _connect(tc)
    r = tc.post("/api/control", json={"id": "bogus", "value": 1})
    assert r.status_code == 400 and r.get_json()["ok"] is False


def test_control_gamma_writes_curve(client):
    tc, fake = client
    _connect(tc)
    tc.post("/api/control", json={"id": "gamma", "value": 100})   # g=1.0 -> linear
    assert fake["slave"].regs[0x7A] == 0x40                        # SLOP
    assert fake["slave"].regs[0x7B] == 0x04                        # GAM1 == first breakpoint


# ------------------------------------------------------------------ gamma
def test_gamma_preview_no_device(client):
    tc, _ = client                                   # not connected; preview is pure math
    r = tc.get("/api/gamma?value=100").get_json()
    assert r["ok"] and r["exponent"] == 1.0
    assert "0x7A" in r["registers"] and len(r["points"]) == 17


def test_gamma_device(client):
    tc, _ = client
    _connect(tc)
    r = tc.get("/api/gamma/device").get_json()
    assert r["ok"] and "0x89" in r["registers"] and len(r["points"]) == 17


# ------------------------------------------------------------------ matrix
def test_matrix_read(client):
    tc, _ = client
    _connect(tc)
    r = tc.get("/api/matrix").get_json()
    assert r["ok"] and len(r["coeffs"]) == 6 and r["auto_contrast"] is True
    assert len(r["swatches"]) == len(__import__("ov7670").MATRIX_REF_COLORS)


def test_matrix_coeff_sign_rmw(client):
    tc, fake = client
    _connect(tc)
    r = tc.post("/api/matrix/coeff", json={"index": 1, "value": -64}).get_json()
    assert r["ok"]
    assert fake["slave"].regs[0x50] == 64             # magnitude
    assert fake["slave"].regs[0x58] & 0x02            # MTXS sign bit for MTX2


def test_matrix_contrast_center(client):
    tc, fake = client
    _connect(tc)
    tc.post("/api/matrix/contrast_center", json={"on": False})
    assert not (fake["slave"].regs[0x58] & 0x80)


# ------------------------------------------------------------------ health
def test_health_status_supported(client):
    tc, _ = client
    _connect(tc)
    r = tc.get("/api/health").get_json()
    assert r["ok"] and r["alive"] and r["status_supported"]
    assert r["magic"] == 0xA5 and r["magic_ok"] and isinstance(r["uptime"], int)


def test_health_old_bitstream_degrades(client):
    tc, fake = client
    _connect(tc)
    fake["slave"].reg_count = 202                     # status regs now illegal addr
    r = tc.get("/api/health").get_json()
    assert r["ok"] and r["alive"] and r["status_supported"] is False


# ------------------------------------------------------------------ raw
def test_raw_read_write(client):
    tc, fake = client
    _connect(tc)
    assert tc.get("/api/raw?addr=0x0A&count=1").get_json()["registers"]["0x0A"] == 0x76
    tc.post("/api/raw", json={"addr": "0x55", "value": "0x12"})
    assert fake["slave"].regs[0x55] == 0x12


# ------------------------------------------------------------------ errors
def test_not_connected_is_400(client):
    tc, _ = client
    r = tc.get("/api/settings")
    assert r.status_code == 400 and r.get_json()["ok"] is False


def test_disconnect(client):
    tc, _ = client
    _connect(tc)
    assert tc.post("/api/disconnect").get_json()["ok"]
    assert tc.get("/api/state").get_json()["connected"] is False


def test_device_lost_returns_503_and_tears_down(client):
    tc, fake = client
    _connect(tc)
    fake["slave"].fail_on_io = OSError("device unplugged")
    r = tc.get("/api/health")
    assert r.status_code == 503                       # classified as disconnect
    assert tc.get("/api/state").get_json()["connected"] is False   # client torn down


def test_settings_io_error_returns_503(client):
    tc, fake = client
    _connect(tc)
    fake["slave"].fail_on_io = OSError(5, "Input/output error")
    r = tc.get("/api/settings")                       # multi-register read path
    assert r.status_code == 503                       # not a 500 crash
    assert tc.get("/api/state").get_json()["connected"] is False


# ----------------------------------------------------------------- frame grab
def test_grab_route(client):
    tc, _ = client
    _connect(tc)
    r = tc.post("/api/grab")
    assert r.status_code == 200
    assert r.headers["X-Frame-Width"] == "640"
    assert r.headers["X-Frame-Height"] == "480"
    assert len(r.data) == 640 * 480 * 4          # RGBA
    assert r.data[0:4] == bytes([0, 0, 0, 255])  # fake pixel 0 = 0x0000 -> black


def test_grab_route_not_connected(client):
    tc, _ = client
    assert tc.post("/api/grab").status_code == 400


def test_grab_status_idle(client):
    tc, _ = client
    r = tc.get("/api/grab/status").get_json()
    assert r["ok"] and r["active"] is False and r["total"] == 640 * 480


def test_grab_status_after_grab(client):
    tc, _ = client
    _connect(tc)
    tc.post("/api/grab")
    r = tc.get("/api/grab/status").get_json()
    assert r["active"] is False and r["done"] == r["total"] == 640 * 480


def test_grab_cancel_endpoint(client):
    tc, _ = client
    assert tc.post("/api/grab/cancel").get_json()["ok"] is True


def test_health_route_includes_watchdog(client):
    tc, fake = client
    _connect(tc)
    fake["slave"].health = 0x10 | 0x08 | 0x04   # monitoring + any-hang + camera
    r = tc.get("/api/health").get_json()
    assert r["ok"] and r["status_supported"]
    assert r["health"]["monitoring"] and r["health"]["any_hang"]
    assert r["health"]["camera_hang"] and not r["health"]["lcd_hang"]


def test_reset_defaults_route(client):
    tc, fake = client
    _connect(tc)
    assert tc.post("/api/reset_defaults").get_json()["ok"] is True
    assert fake["slave"].regs.get(0xFA) == 1


def test_dump_route(client):
    tc, _ = client
    _connect(tc)
    r = tc.get("/api/dump").get_json()
    assert r["ok"] and len(r["registers"]) == 0xCA
    assert r["registers"]["0x0A"] == 0x76


# ------------------------------------------------------------------ OSD overlay
def test_osd_get_default_disabled(client):
    tc, _ = client
    _connect(tc)
    r = tc.get("/api/osd").get_json()
    assert r["ok"] and r["enabled"] is False
    assert r["lines"] == []          # nothing written yet -> no text


def test_osd_get_reads_back_text(client):
    """GET /api/osd returns the overlay text the device is showing (for connect)."""
    tc, _ = client
    _connect(tc)
    tc.post("/api/osd", json={"lines": ["HELLO", "  world"]})
    r = tc.get("/api/osd").get_json()
    assert r["ok"]
    assert r["lines"] == ["HELLO", "  world"]   # trailing blank rows/cols trimmed


def test_osd_enable_and_write_text(client):
    tc, fake = client
    _connect(tc)
    r = tc.post("/api/osd", json={"text": "Hi", "row": 1, "col": 2,
                                  "enabled": True}).get_json()
    assert r["ok"] and r["enabled"] is True
    slave = fake["slave"]
    base = 1 * 60 + 2
    assert slave.osd_cells[base] == ord("H")
    assert slave.osd_cells[base + 1] == ord("i")
    assert slave.osd_enabled is True


def test_osd_lines_and_clear(client):
    tc, fake = client
    _connect(tc)
    tc.post("/api/osd", json={"lines": ["AB", "CD"]})
    slave = fake["slave"]
    assert slave.osd_cells[0] == ord("A") and slave.osd_cells[1] == ord("B")
    assert slave.osd_cells[60] == ord("C") and slave.osd_cells[61] == ord("D")
    tc.post("/api/osd", json={"clear": True})
    assert set(slave.osd_cells) == {0}


def test_osd_not_connected_is_400(client):
    tc, _ = client
    assert tc.get("/api/osd").status_code == 400
