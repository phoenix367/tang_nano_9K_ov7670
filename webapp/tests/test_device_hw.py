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
import time

import modbus_client as mc
import ov7670
import pytest

PORT = os.environ.get("OV7670_PORT")

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
    into the soft CPU, it ran, and it drove a real peripheral. One-shot: a freshly
    flashed (reset) device is in the bootloader. (Loading is one-shot per boot, so
    this is the single overlay-load test per session.)"""
    import pathlib
    overlay = (pathlib.Path(__file__).resolve().parents[2]
               / "build" / "serv_fw" / "osd_hello.bin")
    if not overlay.exists():
        pytest.skip(f"overlay not built ({overlay}); build the SERV firmware first")

    def load_and_check(label):
        n = dev.serv_boot_load(overlay.read_bytes())    # upload + hand over control
        assert n > 0
        time.sleep(0.3)                                 # overlay clears+paints, then returns
        assert dev.read_holding(mc.REG_OSD_CTRL, 1)[0] & 0x01, \
            f"{label}: the demo did not enable the OSD"
        text = "\n".join(dev.osd_read_text())
        assert "Hello from MCU!!!" in text, \
            f"{label}: banner not on the OSD after load; read: {text!r}"

    load_and_check("first load")
    # The overlay hands control back to the bootloader, so a second upload works
    # WITHOUT resetting the device -- prove it re-loads.
    load_and_check("re-load (no reset)")


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
