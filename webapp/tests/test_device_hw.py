"""Host-side, hardware-in-the-loop integration tests.

These open the *real* UART and exercise the live Tang Nano 9K's Modbus
capabilities end-to-end (identity, uptime, register R/W, health watchdog, OSD,
illegal-address handling, frame grab, re-init). They are skipped unless
OV7670_PORT points at a connected board:

    OV7670_PORT=/dev/ttyGowin .venv/bin/python -m pytest webapp/tests/test_device_hw.py -v

    # skip the slow ones (frame download, re-init) with:  -m "not slow"

Optional env: OV7670_BAUD (default 1000000), OV7670_SLAVE (default 7).

Each test restores any register it changes, so the running camera is left as it
was found (except the deliberately-disruptive re-init test, which is `slow`).
"""

import os
import pathlib
import time

import modbus_client as mc
import ov7670
import pytest

PORT = os.environ.get("OV7670_PORT")


def _serv_overlay(name):
    """Bytes of a built SERV overlay (build/serv_fw/<name>); skip if not built."""
    path = pathlib.Path(__file__).resolve().parents[2] / "build" / "serv_fw" / name
    if not path.exists():
        pytest.skip(f"overlay not built ({path}); build the SERV firmware first")
    return path.read_bytes()


def _run_motion_overlay(dev, binname):
    """Upload a motion-detector overlay (asm or C) and verify it: the heartbeat
    (0xE0 low byte) reports a plausible processing FPS -- which proves the whole
    pipeline ran (grab + bg-in-PSRAM + compare + the 1 Hz uptime time base) -- and
    the OSD shows the "FPS:" and "Movement:" lines (best-effort short reads, since
    the OSD readback races the MCU on the cursor). The overlay parks, so reset the
    MCU afterward so it stops driving the OSD/ch1 for later tests."""
    overlay = _serv_overlay(binname)
    try:
        assert dev.serv_boot_load(overlay) > 0       # reset -> bootloader -> run

        fps = 0
        deadline = time.monotonic() + 8.0            # need >1 s for the first tick
        while time.monotonic() < deadline:
            fps = dev.read_reg(mc.REG_HEARTBEAT) & 0xFF
            if 5 <= fps <= 120:
                break
            time.sleep(0.3)
        assert 5 <= fps <= 120, \
            f"{binname}: no plausible processing FPS reported (0xE0={fps})"

        line = ""
        for _ in range(30):
            line = "".join(mc.osd_char(c & 0xFF) for c in dev.osd_read_cells(9, 23, 8))
            if line.startswith("FPS:"):
                break
            time.sleep(0.1)
        assert line.startswith("FPS:"), f"{binname}: OSD FPS line not found ({line!r})"

        verdict = ""
        for _ in range(30):
            verdict = "".join(mc.osd_char(c & 0xFF) for c in dev.osd_read_cells(10, 23, 13))
            if verdict.startswith("Movement:"):
                break
            time.sleep(0.1)
        assert verdict.startswith("Movement:"), \
            f"{binname}: OSD verdict not found ({verdict!r})"
    finally:
        dev.serv_mcu_reset()                         # stop the parked monitor loop
        time.sleep(0.05)

pytestmark = [
    pytest.mark.hardware,
    pytest.mark.skipif(not PORT, reason="set OV7670_PORT to a connected board"),
]


@pytest.fixture(scope="module")
def dev():
    """One real Modbus connection shared by the module; skip if it isn't ours."""
    baud = int(os.environ.get("OV7670_BAUD", str(mc.DEFAULT_BAUD)))
    slave = int(os.environ.get("OV7670_SLAVE", str(mc.DEFAULT_SLAVE)))
    try:
        client = mc.ModbusRTU(PORT, baud=baud, slave=slave, timeout=1.0)
    except Exception as e:  # serial open failure
        pytest.skip(f"cannot open {PORT}: {e}")
    try:
        magic = client.read_reg(ov7670.STATUS_MAGIC_ADDR)
    except Exception as e:
        client.close()
        pytest.skip(f"no Modbus response on {PORT}: {e}")
    if magic != ov7670.STATUS_MAGIC:
        client.close()
        pytest.skip(f"unexpected firmware magic 0x{magic:02X} on {PORT}")
    yield client
    client.close()


# --------------------------------------------------------------- identity / link
def test_firmware_magic(dev):
    assert dev.read_reg(ov7670.STATUS_MAGIC_ADDR) == ov7670.STATUS_MAGIC


def test_camera_identity(dev):
    """Each live SCCB read of the OV7670 ID registers matches the datasheet."""
    for addr, name, expected in ov7670.IDENTITY:
        got = dev.read_reg(addr)
        assert got == expected, f"{name} @0x{addr:02X}: got 0x{got:02X}, want 0x{expected:02X}"


def test_multi_register_read(dev):
    """A burst FC03 returns the right count and matches single reads."""
    base = ov7670.IDENTITY[0][0]          # 0x0A, contiguous-ish ID block
    vals = dev.read_holding(base, 2)
    assert len(vals) == 2
    assert vals[0] == dev.read_reg(base)


def test_uptime_is_free_running(dev):
    """The 16-bit uptime counter (0xF1/0xF2) advances ~1 Hz."""
    hi, lo = dev.read_holding(ov7670.STATUS_UPTIME_ADDR, 2)
    first = ((hi & 0xFF) << 8) | (lo & 0xFF)
    time.sleep(1.3)
    hi, lo = dev.read_holding(ov7670.STATUS_UPTIME_ADDR, 2)
    second = ((hi & 0xFF) << 8) | (lo & 0xFF)
    assert second != first, "uptime did not advance — counter stuck?"
    assert ((second - first) & 0xFFFF) < 100, "uptime jumped — unexpected reset?"


# --------------------------------------------------------------- register access
def test_register_round_trip(dev):
    """Write/read-back a live camera register (brightness), then restore it."""
    addr = 0x55                            # BRIGHT — safe and fully reversible
    original = dev.read_reg(addr)
    try:
        for value in (0x20, 0x60):         # two distinct, clearly-different values
            dev.write_reg(addr, value)
            assert dev.read_reg(addr) == value
    finally:
        dev.write_reg(addr, original)
        assert dev.read_reg(addr) == original


def test_write_takes_low_byte_only(dev):
    """An OV7670 register is 8-bit: only the low byte of a write reaches it."""
    addr = 0x55
    original = dev.read_reg(addr)
    try:
        dev.write_single(addr, 0x1234)     # high byte must be ignored
        assert dev.read_reg(addr) == 0x34
    finally:
        dev.write_reg(addr, original)


def test_illegal_address_raises(dev):
    """A read past the address space returns a Modbus illegal-address exception."""
    with pytest.raises(mc.ModbusError) as ei:
        dev.read_holding(0xFFFF, 1)
    assert ei.value.code == 2              # illegal data address


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_bootloader_runs_osd_hello(dev):
    """Bootloader + first demo (demo_mcu_apps/osd_hello) end to end: a SERV_CONTROL
    build boots a bootloader; upload the osd_hello overlay over the mailbox; the
    bootloader copies it into RAM and jumps to it, and it writes 'Hello from MCU!!!'
    onto the OSD -- which the host then reads back. Proves the host loaded firmware
    into the soft CPU, it ran, and it drove a real peripheral. A freshly flashed
    (reset) device is in the bootloader."""
    overlay = _serv_overlay("osd_hello.bin")

    n = dev.serv_boot_load(overlay)                  # upload + hand over control
    assert n > 0
    time.sleep(0.3)                                  # overlay clears+paints, then returns
    assert dev.osd_enabled(), "the demo did not enable the OSD"
    text = "\n".join(dev.osd_read_text())
    assert "Hello from MCU!!!" in text, \
        f"banner not on the OSD after load; read: {text!r}"


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_bootloader_reuploads_without_reset(dev):
    """Re-upload an overlay WITHOUT resetting the device, and prove the second load
    actually RAN (not a false pass off the first load's residue).

    osd_hello returns control to the bootloader when done, and the bootloader
    re-arms (it clears `start` when it reads BOOT_LEN). So after a first load we
    can load again with no reset. The trap this test avoids: the OSD buffer keeps
    the first load's text, so re-reading the banner proves nothing on its own. To
    make the second load observable we first DISRUPT the OSD from the host --
    disable it and blank the buffer -- confirm it's really off/blank, THEN
    re-upload. Only a re-load that actually executes will re-enable the OSD and
    repaint the banner; a silent no-op (bootloader didn't re-arm, overlay didn't
    re-run) leaves it disabled+blank and fails here."""
    overlay = _serv_overlay("osd_hello.bin")

    # ---- first load: get the banner up ----
    assert dev.serv_boot_load(overlay) > 0
    time.sleep(0.3)
    assert dev.osd_enabled(), "first load: OSD not enabled"
    assert "Hello from MCU!!!" in "\n".join(dev.osd_read_text()), \
        "first load: banner missing"

    # ---- disrupt from the host so a no-op re-load would be visibly wrong ----
    dev.osd_set_enabled(False)
    dev.osd_clear()
    time.sleep(0.05)                                 # hardware blank sweep is ~tens of us
    assert not dev.osd_enabled(), "OSD did not disable before re-load"
    assert "Hello from MCU!!!" not in "\n".join(dev.osd_read_text()), \
        "OSD buffer not actually cleared before re-load"

    # ---- re-load (no reset): the overlay must run again and undo the disruption ----
    # reset_first=False so this exercises the bootloader RE-ARM path specifically
    # (osd_hello returned to the bootloader), not the host MCU-reset.
    assert dev.serv_boot_load(overlay, reset_first=False) > 0, "re-load upload was rejected"
    time.sleep(0.3)
    assert dev.osd_enabled(), \
        "re-load did not re-enable the OSD -- the overlay did not re-run " \
        "(bootloader re-arm / overlay-return-to-bootloader broken?)"
    assert "Hello from MCU!!!" in "\n".join(dev.osd_read_text()), \
        "re-load did not repaint the banner -- the overlay did not re-run"


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_c_hello(dev):
    """demo_mcu_apps/c_hello -- the osd_hello demo written in C (crt0 + C source,
    linked at 0x1000). Proves the C toolchain path works on the soft core: upload
    it, and it writes 'Hello from C!' onto the OSD, which the host reads back."""
    overlay = _serv_overlay("c_hello.bin")
    dev.osd_clear()                              # so stale text can't fool us
    time.sleep(0.05)
    assert dev.serv_boot_load(overlay) > 0       # reset -> bootloader -> run
    time.sleep(0.3)
    assert dev.osd_enabled(), "c_hello did not enable the OSD"
    text = "\n".join(dev.osd_read_text())
    assert "Hello from C!" in text, \
        f"c_hello banner not on the OSD; read: {text!r}"


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_calc(dev):
    """demo_mcu_apps/calc -- host-driven IEEE-754 float calculator on the soft core
    (libgcc soft-float, 16 KB RAM build). Load it, send arithmetic / sqrt / 1-over-x
    / integer-power ops over the mailbox, and check each float result (returned as
    raw IEEE-754 bytes via the OSD) matches -- verifying the soft-float math end to
    end."""
    import math
    overlay = _serv_overlay("calc.bin")
    cases = [
        (mc.CALC_ADD,   2.5,  4.0, 6.5),
        (mc.CALC_SUB,  10.0,  3.5, 6.5),
        (mc.CALC_MUL,   3.0,  7.0, 21.0),
        (mc.CALC_DIV,   1.0,  3.0, 1.0 / 3.0),
        (mc.CALC_SQRT,  2.0,  0.0, math.sqrt(2.0)),
        (mc.CALC_RECIP, 8.0,  0.0, 0.125),
        (mc.CALC_POW,   2.0, 10.0, 1024.0),
        (mc.CALC_POW,   3.0, -2.0, 1.0 / 9.0),
    ]
    try:
        assert dev.serv_boot_load(overlay) > 0       # reset -> bootloader -> run calc
        time.sleep(0.3)
        for op, a, b, want in cases:
            got = dev.serv_calc(op, a, b)
            tol = 1e-3 * max(1.0, abs(want))         # single-precision soft-float
            assert abs(got - want) <= tol, \
                f"calc op={op} a={a} b={b}: got {got!r}, want {want!r}"
    finally:
        dev.serv_mcu_reset()                         # stop the parked calc loop
        time.sleep(0.05)


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_motion_detect(dev):
    """demo_mcu_apps/motion (assembly): grabs a frame, builds a background model in
    FREE PSRAM, then loops grabbing + comparing and reports Movement: YES/NO on the
    OSD, periodically refreshing the background. It measures its own processing FPS
    (loop iterations between 1 Hz uptime ticks) and publishes it to the heartbeat
    reg (0xE0, low byte) -- read race-free (reading the OSD races the MCU cursor).

    We assert the heartbeat reports a plausible processing FPS (proves the whole
    pipeline -- grab + bg-in-PSRAM + compare + the uptime time base -- ran), and
    best-effort confirm the OSD shows "FPS:" and a "Movement:" verdict. The overlay
    parks, so reset the MCU afterward so it stops driving the OSD/ch1 for later
    tests."""
    _run_motion_overlay(dev, "motion.bin")


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_motion_detect_c(dev):
    """demo_mcu_apps/motion_c -- the motion detector in C (vs the asm `motion`).
    Functionally identical; runs at the same FPS since the loop is grab-bound. Same
    checks as the asm version (heartbeat FPS + OSD lines)."""
    _run_motion_overlay(dev, "motion_c.bin")


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_skin_detect(dev):
    """demo_mcu_apps/skin_detect -- grabs a frame, samples a grid, classifies skin
    pixels and draws a bounding box on the OSD with box-drawing glyphs. We can't put
    a face in front of the camera, so we assert the pipeline RUNS (heartbeat frame
    counter advances -> grab + scan + classify all ran) and the static OSD header is
    present. The box itself (rows 1..16) is verified visually on the LCD; reading it
    back races the MCU's cursor, so it's not asserted here."""
    overlay = _serv_overlay("skin_detect.bin")
    try:
        assert dev.serv_boot_load(overlay) > 0       # reset -> bootloader -> run
        first = dev.read_reg(mc.REG_HEARTBEAT) & 0xFF
        advanced = False
        deadline = time.monotonic() + 6.0
        while time.monotonic() < deadline and not advanced:
            time.sleep(0.3)
            if (dev.read_reg(mc.REG_HEARTBEAT) & 0xFF) != first:
                advanced = True
        assert advanced, "skin_detect loop not advancing (grab/scan stuck)"

        header = ""
        for _ in range(30):                          # the "SKIN" label sits in the
            header = "".join(mc.osd_char(c & 0xFF) for c in dev.osd_read_cells(0, 0, 7))
            if "SKIN" in header:                     # left border, never under the box
                break
            time.sleep(0.1)
        assert "SKIN" in header, f"skin_detect OSD label missing ({header!r})"
    finally:
        dev.serv_mcu_reset()
        time.sleep(0.05)


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_roi_presence(dev):
    """demo_mcu_apps/roi_presence -- fixed-ROI face-presence gate: draws a fixed ROI
    box on the OSD and reports (skin_count << 1) | present on the heartbeat. We
    can't control whether a face is in the box, so we assert the pipeline runs (the
    ROI skin count is in range 0..150) and the fixed ROI box is drawn on the OSD."""
    overlay = _serv_overlay("roi_presence.bin")
    try:
        assert dev.serv_boot_load(overlay) > 0
        time.sleep(0.5)
        count = (dev.read_reg(mc.REG_HEARTBEAT) & 0xFF) >> 1
        assert 0 <= count <= 127, f"ROI skin count out of range ({count})"  # clamped to 127 on 0xE0
        # the fixed ROI box top-left corner is at OSD (row 1, col 17); it's drawn
        # once and static -> readable. Expect a box-drawing glyph (0x80..0x85).
        glyph = 0
        for _ in range(20):
            glyph = dev.osd_read_cells(1, 17, 1)[0] & 0xFF
            if 0x80 <= glyph <= 0x85:
                break
            time.sleep(0.1)
        assert 0x80 <= glyph <= 0x85, f"ROI box not drawn on the OSD (cell=0x{glyph:02X})"
    finally:
        dev.serv_mcu_reset()
        time.sleep(0.05)


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_roi_collect(dev):
    """demo_mcu_apps/roi_collect -- the sample-collection alignment guide. It draws
    the same fixed ROI box as roi_presence, sets heartbeat 0x42, then PARKS without
    touching the bus so the host can drive the grab port (collect_samples.py reads
    the ROI out of ch1 PSRAM). We assert: the liveness marker (0xE0 == 0x42), the
    box is drawn (a box glyph at OSD (3,22)), and -- the demo's whole point -- the
    host can still arm a grab + read a ROI cell while the overlay is parked."""
    overlay = _serv_overlay("roi_collect.bin")
    try:
        assert dev.serv_boot_load(overlay) > 0
        time.sleep(0.5)
        assert (dev.read_reg(mc.REG_HEARTBEAT) & 0xFF) == 0x42, "roi_collect liveness marker missing"
        glyph = 0
        for _ in range(20):
            glyph = dev.osd_read_cells(1, 17, 1)[0] & 0xFF
            if 0x80 <= glyph <= 0x85:
                break
            time.sleep(0.1)
        assert 0x80 <= glyph <= 0x85, f"ROI box not drawn on the OSD (cell=0x{glyph:02X})"
        # the parked overlay makes no bus accesses -> the host owns the grab port:
        # arm a capture and read a ROI cell out of ch1 PSRAM (the collect path).
        dev.write_single(mc.REG_GRAB, 1)
        for _ in range(500):
            if not dev.grab_busy():
                break
            time.sleep(0.002)
        assert not dev.grab_busy(), "host grab did not complete (overlay contending for the bus?)"
        addr = 1 * 19200 + 9 * 16             # ROI top-left cell (rr=1, cc=9)
        word = dev.psram_read(addr)           # must not hang -> grab port is free
        assert 0 <= ((word >> 16) & 0xFFFF) <= 0xFFFF
    finally:
        dev.serv_mcu_reset()
        time.sleep(0.05)


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_roi_tm(dev):
    """demo_mcu_apps/roi_tm -- fixed-ROI face presence via a Tsetlin Machine. Reads
    the ROI, featurizes it, and runs bitwise TM inference (model baked in from
    tm_model.h). We can't control whether a face is in the box, so we assert the
    pipeline runs: the box is drawn, and the heartbeat decodes to a valid signed
    vote (bit7=present, bits[6:0]=vote+64) -- proving grab + featurize + clause
    voting all executed on the soft core."""
    overlay = _serv_overlay("roi_tm.bin")
    try:
        assert dev.serv_boot_load(overlay) > 0
        time.sleep(0.5)
        glyph = 0
        for _ in range(20):
            glyph = dev.osd_read_cells(1, 17, 1)[0] & 0xFF
            if 0x80 <= glyph <= 0x85:
                break
            time.sleep(0.1)
        assert 0x80 <= glyph <= 0x85, f"ROI box not drawn on the OSD (cell=0x{glyph:02X})"
        hb = dev.read_reg(mc.REG_HEARTBEAT) & 0xFF
        present = hb >> 7
        vote = (hb & 0x7F) - 64
        assert present in (0, 1)
        assert -64 <= vote <= 63, f"implausible TM vote ({vote})"
    finally:
        dev.serv_mcu_reset()
        time.sleep(0.05)


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_lbph_bench(dev):
    """demo_mcu_apps/lbph_bench -- benchmark of LBPH feature computation on the soft
    core (the heart of OpenCV's LBPH face recogniser). It loops computing the LBPH
    feature of a 32x32 downscaled face and reports features/second on the heartbeat
    (0xE0). We assert it reports a plausible rate (proves the read + LBP + histogram
    pipeline runs); measured ~7-8/s on hardware."""
    overlay = _serv_overlay("lbph_bench.bin")
    try:
        assert dev.serv_boot_load(overlay) > 0
        rate = 0
        deadline = time.monotonic() + 8.0           # need >1 s for the first tick
        while time.monotonic() < deadline:
            rate = dev.read_reg(mc.REG_HEARTBEAT) & 0xFF
            if 2 <= rate <= 40:
                break
            time.sleep(0.4)
        assert 2 <= rate <= 40, f"lbph_bench did not report a plausible rate (0xE0={rate})"
    finally:
        dev.serv_mcu_reset()
        time.sleep(0.05)


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_mcu_reset_recovers_parked_overlay(dev):
    """The host MCU-reset register (0xE2) returns the soft core to the bootloader
    from ANY state -- including an overlay that parks (loops forever) and so could
    never re-arm the bootloader on its own. This is what makes 'load any firmware'
    work unconditionally.

    Load overlay_heartbeat, which parks incrementing 0xE0; confirm it's running
    (0xE0 advances). Reset the MCU and confirm 0xE0 freezes (the overlay stopped --
    the CPU is back in the bootloader). Then load osd_hello over the now-parked MCU
    and confirm it runs -- proving recovery + load-anything."""
    def hb_advances(dwell=0.25):
        a = dev.read_reg(mc.REG_HEARTBEAT)
        time.sleep(dwell)
        return a != dev.read_reg(mc.REG_HEARTBEAT)

    # overlay_heartbeat parks (infinite loop), so it can't re-arm the bootloader
    dev.serv_boot_load(_serv_overlay("overlay_heartbeat.bin"))   # reset_first -> clean boot
    time.sleep(0.2)
    assert hb_advances(), "heartbeat overlay isn't running (0xE0 not advancing)"

    # host reset -> bootloader; the parked overlay stops, so 0xE0 must freeze
    dev.serv_mcu_reset()
    time.sleep(0.1)
    assert not hb_advances(), \
        "0xE0 still advancing after MCU reset -- the overlay was not stopped"

    # recovered: we can now load any firmware over the formerly-parked MCU
    assert dev.serv_boot_load(_serv_overlay("osd_hello.bin")) > 0
    time.sleep(0.3)
    assert dev.osd_enabled(), "post-reset load: OSD not enabled"
    assert "Hello from MCU!!!" in "\n".join(dev.osd_read_text()), \
        "post-reset load: osd_hello did not run after recovering a parked MCU"


def test_psram_write_read_roundtrip(dev):
    """The arbitrary ch1 PSRAM write port (wb_grab 0xF3<=3 + 0xF4-0xF7): write a
    pseudo-random 32-bit sequence into a run of bursts and read each back. This
    validates the RTL write path directly from the host (no SERV needed)."""
    if not (dev.read_holding(mc.REG_GRAB, 1)[0] & 0x02):
        pytest.skip("ch1 PSRAM not calibrated (0xF3 bit1) on this bitstream")

    def seq(i):
        return ((i * 0x9E3779B1) ^ 0x5A5A1234) & 0xFFFFFFFF

    N = 32
    for i in range(N):
        dev.psram_write(i * 16, seq(i))          # all 8 words of burst i <- seq(i)
    for i in range(N):
        got = dev.psram_read(i * 16)             # word 0 of burst i
        assert got == seq(i), \
            f"PSRAM[{i * 16}] read 0x{got:08X}, wrote 0x{seq(i):08X}"


@pytest.mark.skipif(not os.environ.get("OV7670_SERV"),
                    reason="set OV7670_SERV=1 for a SERV_CONTROL (co-master) bitstream")
def test_serv_psram_demo(dev):
    """demo_mcu_apps/psram_test on the soft core: it writes a pseudo-random
    sequence into ch1 PSRAM, reads it back, compares, and prints progress + the
    verdict on the OSD. Upload it and poll the OSD -- a healthy PSRAM path ends in
    'PSRAM test: PASS' (and never 'FAIL')."""
    overlay = _serv_overlay("psram_test.bin")
    dev.osd_clear()                              # so a stale PASS can't fool us
    time.sleep(0.05)
    assert dev.serv_boot_load(overlay) > 0       # reset -> bootloader -> run

    deadline = time.monotonic() + 5.0            # bit-serial write+read of 512 bursts
    text = ""
    while time.monotonic() < deadline:
        text = "\n".join(dev.osd_read_text())
        if "PSRAM test: PASS" in text or "PSRAM test: FAIL" in text:
            break
        time.sleep(0.1)
    assert "PSRAM test: FAIL" not in text, f"MCU PSRAM demo reported FAIL; OSD: {text!r}"
    assert "PSRAM test: PASS" in text, \
        f"MCU PSRAM demo did not finish with PASS; OSD read: {text!r}"


# --------------------------------------------------------------- board health
def test_board_health(dev):
    """The watchdog reports a healthy, monitoring board with no stuck subsystems."""
    h = dev.read_health()
    assert h["monitoring"], "watchdog not monitoring (old bitstream or startup grace?)"
    assert not h["any_hang"], f"a subsystem hang is latched: {h}"
    assert not (h["lcd_hang"] or h["memory_hang"] or h["camera_hang"])


# --------------------------------------------------------------- OSD text overlay
def test_osd_enable_round_trip(dev):
    """The OSD show/hide bit (0xFB) round-trips; restore the original state."""
    original = dev.osd_enabled()
    try:
        dev.osd_set_enabled(True)
        assert dev.osd_enabled() is True
        dev.osd_set_enabled(False)
        assert dev.osd_enabled() is False
    finally:
        dev.osd_set_enabled(original)


def test_osd_cursor_and_autoincrement(dev):
    """The write cursor (0xFC) is settable and auto-increments per character."""
    dev.write_single(mc.REG_OSD_ADDR, 123)
    assert dev.read_reg(mc.REG_OSD_ADDR) == 123
    dev.write_single(mc.REG_OSD_ADDR, 0)
    dev.write_single(mc.REG_OSD_DATA, ord("A"))
    dev.write_single(mc.REG_OSD_DATA, ord("B"))
    assert dev.read_reg(mc.REG_OSD_ADDR) == 2, "cursor did not auto-increment"


def test_osd_clear_homes_cursor(dev):
    """Clearing the OSD buffer (0xFB bit1) blanks it and homes the cursor."""
    dev.osd_write_text(0, 0, "HELLO")      # advance the cursor
    assert dev.read_reg(mc.REG_OSD_ADDR) > 0
    dev.osd_clear()
    time.sleep(0.05)                       # the hardware sweep is ~tens of us
    assert dev.read_reg(mc.REG_OSD_ADDR) == 0


def test_osd_read_back(dev):
    """0xFD reads back the glyph stored at the cursor; reads auto-increment."""
    dev.osd_clear()
    time.sleep(0.05)
    codes = [0x48, 0x49, 0x21, 0x2A, 0x7E]   # 'H' 'I' '!' '*' '~'
    base = 2 * mc.OSD_COLS + 5               # row 2, col 5
    dev.write_single(mc.REG_OSD_ADDR, base)
    for c in codes:
        dev.write_single(mc.REG_OSD_DATA, c)

    # read the run back; each 0xFD read returns the cell at the cursor and advances
    assert dev.osd_read_cells(2, 5, len(codes)) == codes
    assert dev.read_reg(mc.REG_OSD_ADDR) == base + len(codes), \
        "0xFD reads did not auto-increment the cursor"

    # cells past the written run are still blank from the clear above
    assert dev.osd_read_cells(2, 5 + len(codes), 2) == [0x00, 0x00]


def test_osd_read_text_round_trip(dev):
    """osd_read_text() decodes the buffer back to the lines we wrote (the webapp
    uses this to populate the OSD editor on connect)."""
    dev.osd_clear()
    time.sleep(0.05)
    dev.osd_write_text(0, 0, "HELLO  device")
    dev.osd_write_text(1, 0, "line two")
    assert dev.osd_read_text() == ["HELLO  device", "line two"]


# --------------------------------------------------------------- slow capabilities
@pytest.mark.slow
def test_frame_grab(dev):
    """Capture a frame into PSRAM ch1 and stream it back over Modbus (~10 s)."""
    seen = {}

    def progress(done, total):
        seen["done"], seen["total"] = done, total

    pixels = dev.grab_frame(progress=progress, timeout=5.0)
    assert len(pixels) == mc.FRAME_PIXELS
    assert all(0 <= p <= 0xFFFF for p in pixels[:1000])
    assert seen.get("done") == mc.FRAME_PIXELS == seen.get("total")


@pytest.mark.slow
def test_reset_to_defaults(dev):
    """Re-init (0xFA) reloads the ROM defaults, reverting a changed register."""
    addr = 0x55                            # brightness
    dev.write_reg(addr, 0x37)              # an unlikely-default value
    assert dev.read_reg(addr) == 0x37
    dev.reset_to_defaults()
    time.sleep(0.5)                        # device re-walks the init ROM
    assert dev.read_reg(addr) != 0x37, "re-init did not restore the default"
