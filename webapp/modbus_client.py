"""Minimal Modbus RTU client for the Tang Nano 9K OV7670 bridge.

Speaks Modbus RTU over the FT2232H channel-B UART (1 Mbaud 8-E-1, slave id 7 by
default). The FPGA's modbus_rtu_slave maps each holding-register address 1:1 to
an OV7670 register (0x00..0xC9): a write uses the low byte of the value, a read
returns {0x00, reg_byte}. The RTU framing/CRC come from pymodbus
(ModbusSerialClient); this module is a thin device-specific wrapper that maps
pymodbus responses/exceptions to the small API the app and tests use.
"""

import time

from osd_charset import osd_byte
from pymodbus import FramerType
from pymodbus.client import ModbusSerialClient
from pymodbus.exceptions import ConnectionException, ModbusException

# Reserved bridge registers above the OV7670 0x00..0xC9 range (see
# src/modbus/modbus_cam_backend.sv). The frame-grab feature captures a camera frame
# into PSRAM channel 1 and streams it back over FC03.
CAM_REG_MAX = 0x00C9   # highest OV7670 register (the 1:1-mapped camera range is 0x00..0xC9)
REG_GRAB    = 0x00F3   # write 1 = arm a grab; read bit0 = busy, bit1 = ch1 calibrated
REG_STREAM  = 0x00F8   # write = rewind the download stream to pixel 0
REG_HEALTH  = 0x00F9   # read = watchdog health bits (see read_health)
REG_REINIT  = 0x00FA   # write 1 = re-run camera init (reset all registers to defaults)
REG_OSD_CTRL = 0x00FB  # write bit0 = enable, bit1 = clear; read bit0 = enable
REG_OSD_ADDR = 0x00FC  # write = OSD char-cell write cursor (row*OSD_COLS + col)
REG_OSD_DATA = 0x00FD  # write = char code at the cursor (cursor auto-increments)
STREAM_BASE = 0x1000   # any FC03 read >= here returns the next frame pixel(s)
FRAME_W, FRAME_H = 640, 480
FRAME_PIXELS = FRAME_W * FRAME_H

# OSD text overlay grid (480x272 screen, 8x16 glyphs); matches OSDOverlay/backend.
OSD_COLS, OSD_ROWS = 60, 17
OSD_CELLS = OSD_COLS * OSD_ROWS

def crc16(data: bytes) -> int:
    """CRC-16/Modbus (poly 0xA001, init 0xFFFF). Appended little-endian.

    Kept for the test harness (the fake slave builds RTU frames with it); the
    live client's framing/CRC are handled by pymodbus."""
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if (crc & 1) else (crc >> 1)
    return crc


class GrabCancelled(Exception):
    """A frame grab was aborted via its should_cancel callback."""


class ModbusError(Exception):
    """A Modbus exception response (function code | 0x80)."""

    _NAMES = {
        1: "illegal function",
        2: "illegal data address",
        3: "illegal data value",
        4: "slave device failure",
    }

    def __init__(self, code):
        self.code = code
        super().__init__(
            f"Modbus exception 0x{code:02X} ({self._NAMES.get(code, '?')})"
        )


class ModbusRTU:
    """RTU master backed by pymodbus (ModbusSerialClient), 1 Mbaud 8-E-1.

    A thin device-specific wrapper: it forwards FC03/FC06 to pymodbus and maps
    its responses/exceptions to this project's small API and error model
    (ModbusError for protocol exceptions, OSError for a lost port, TimeoutError
    for no/garbled response after retries)."""

    def __init__(self, port, baud=1000000, slave=7, timeout=1.0, retries=2):
        if not (0 <= slave <= 247):
            raise ValueError(f"slave id {slave} out of range 0..247")
        self.port = port
        self.slave = slave
        self.retries = retries
        self._client = ModbusSerialClient(
            port,
            framer=FramerType.RTU,
            baudrate=baud,
            bytesize=8,
            parity="E",
            stopbits=1,
            timeout=timeout,
            retries=retries + 1,        # pymodbus re-sends transient failures
        )
        if not self._client.connect():
            raise OSError(f"cannot open serial port {port!r}")

    def close(self):
        try:
            self._client.close()
        except Exception:
            pass

    # -- pymodbus response/error mapping -----------------------------------
    def _resolve(self, rr):
        """Turn a pymodbus reply into success, or raise this project's errors."""
        if rr is None:
            raise TimeoutError("no Modbus response")
        if rr.isError():
            code = getattr(rr, "exception_code", None)
            if code is not None:                 # a real Modbus exception response
                raise ModbusError(code)
            raise TimeoutError(f"no/garbled Modbus response: {rr}")
        return rr

    @staticmethod
    def _comms_error(exc):
        """Map a pymodbus transport exception to OSError (port gone, ->disconnect)
        or TimeoutError (transient no-response). Returns the exception to raise."""
        if isinstance(exc, ConnectionException):
            return OSError(f"serial port I/O error: {exc}")
        return TimeoutError(str(exc))

    # -- public API --------------------------------------------------------
    def read_holding(self, addr, count=1):
        if not (1 <= count <= 125):
            raise ValueError(f"read count {count} out of range 1..125")
        try:
            rr = self._client.read_holding_registers(addr, count=count, device_id=self.slave)
        except ConnectionException as e:
            raise self._comms_error(e) from e
        except ModbusException as e:
            raise self._comms_error(e) from e
        regs = self._resolve(rr).registers
        if len(regs) != count:
            raise ValueError(f"got {len(regs)} registers, expected {count}")
        return list(regs)

    def read_reg(self, addr):
        """Read a single OV7670 register; returns the low byte (0..255)."""
        return self.read_holding(addr, 1)[0] & 0xFF

    def write_single(self, addr, value):
        try:
            rr = self._client.write_register(addr, value & 0xFFFF, device_id=self.slave)
        except ConnectionException as e:
            raise self._comms_error(e) from e
        except ModbusException as e:
            raise self._comms_error(e) from e
        self._resolve(rr)

    def write_reg(self, addr, value):
        """Write a single OV7670 register (low byte is what reaches SCCB)."""
        self.write_single(addr, value & 0xFF)

    def read_health(self):
        """Read the watchdog board-health register (0xF9) and decode the bits.

        Returns a dict of booleans. `monitoring` is False on firmware without the
        watchdog (the register reads 0) or during the watchdog's startup grace;
        the per-subsystem flags are sticky (latched until the board is reset).
        """
        v = self.read_holding(REG_HEALTH, 1)[0]
        return {
            "monitoring":  bool(v & 0x10),   # watchdog armed (past startup grace)
            "any_hang":    bool(v & 0x08),
            "camera_hang": bool(v & 0x04),
            "memory_hang": bool(v & 0x02),
            "lcd_hang":    bool(v & 0x01),
        }

    def dump_registers(self):
        """Read every OV7670 register (0x00..0xC9) and return {addr: value}.

        Each read is a live SCCB transaction on the device, issued in FC03 bursts
        of up to 125 registers, so a full dump is a couple of Modbus requests.
        """
        regs = {}
        addr = 0
        while addr <= CAM_REG_MAX:
            n = min(125, CAM_REG_MAX + 1 - addr)
            for i, v in enumerate(self.read_holding(addr, n)):
                regs[addr + i] = v & 0xFF
            addr += n
        return regs

    def reset_to_defaults(self):
        """Re-run the camera's power-on init sequence (reset every OV7670 register
        to its ROM default). The device reloads its config over the next tens of
        ms; re-read the settings afterwards to reflect the reverted state."""
        self.write_single(REG_REINIT, 1)

    # ---- OSD text overlay (8x16 font, 60x17 char grid on the LCD) ------------
    def osd_enabled(self):
        """True if the OSD text overlay is currently shown on the LCD."""
        return bool(self.read_holding(REG_OSD_CTRL, 1)[0] & 0x01)

    def osd_set_enabled(self, on):
        """Show (True) or hide (False) the OSD text overlay on the LCD."""
        self.write_single(REG_OSD_CTRL, 0x01 if on else 0x00)

    def osd_clear(self):
        """Blank the whole OSD character buffer (the firmware sweeps all cells)."""
        self.write_single(REG_OSD_CTRL, 0x02)

    def osd_write_text(self, row, col, text):
        """Write `text` into the OSD grid starting at (row, col).

        Sets the write cursor to row*OSD_COLS+col, then streams one ROM byte per
        character (osd_byte: Latin-1 code, or the C1 byte of a box-drawing/block
        pseudographic); the device auto-increments the cursor per character.
        Characters past the end of the row continue onto the next row (the cursor
        wraps the whole buffer). Raises ValueError if (row, col) is off-grid.
        """
        if not (0 <= row < OSD_ROWS and 0 <= col < OSD_COLS):
            raise ValueError(f"OSD cell ({row}, {col}) out of range")
        self.write_single(REG_OSD_ADDR, row * OSD_COLS + col)
        for ch in text:
            self.write_single(REG_OSD_DATA, osd_byte(ch))

    # ---- frame grab (capture into PSRAM ch1, then stream over FC03) ----------
    def grab_busy(self):
        """True while a grab is still capturing into ch1."""
        return bool(self.read_holding(REG_GRAB, 1)[0] & 0x01)

    def grab_frame(self, progress=None, timeout=3.0, should_cancel=None):
        """Capture a fresh camera frame into ch1 and stream it to the host.

        Arms the grab, waits for it to finish, rewinds the stream pointer, then
        pulls all FRAME_PIXELS pixels with back-to-back 125-register FC03 reads.
        Returns a list of FRAME_PIXELS RGB565 ints in raster order. `progress`,
        if given, is called as progress(done, total) after each chunk.
        `should_cancel`, if given, is polled before each step; when it returns
        true the grab raises GrabCancelled (the partial read is discarded).
        """
        def cancelled():
            return should_cancel is not None and should_cancel()

        self.write_single(REG_GRAB, 1)              # arm
        deadline = time.monotonic() + timeout
        while self.grab_busy():
            if cancelled():
                raise GrabCancelled()
            if time.monotonic() > deadline:
                raise TimeoutError("frame grab did not complete")
            time.sleep(0.002)

        self.write_single(REG_STREAM, 1)            # rewind to pixel 0
        pix = []
        while len(pix) < FRAME_PIXELS:
            if cancelled():
                raise GrabCancelled()
            n = min(125, FRAME_PIXELS - len(pix))
            pix.extend(self.read_holding(STREAM_BASE, n))
            if progress:
                progress(len(pix), FRAME_PIXELS)
        return pix


def rgb565_to_rgb888(pixels):
    """Convert an iterable of RGB565 ints to a flat bytes() of RGB888 triples."""
    out = bytearray(len(pixels) * 3)
    for i, p in enumerate(pixels):
        r = (p >> 11) & 0x1F
        g = (p >> 5) & 0x3F
        b = p & 0x1F
        out[3 * i]     = (r * 527 + 23) >> 6     # 5-bit -> 8-bit
        out[3 * i + 1] = (g * 259 + 33) >> 6     # 6-bit -> 8-bit
        out[3 * i + 2] = (b * 527 + 23) >> 6
    return bytes(out)


def rgb565_to_rgba(pixels):
    """Convert RGB565 ints to a flat bytes() of RGBA quads (alpha = 255), ready
    for a browser ImageData/putImageData draw."""
    out = bytearray(len(pixels) * 4)
    for i, p in enumerate(pixels):
        r = (p >> 11) & 0x1F
        g = (p >> 5) & 0x3F
        b = p & 0x1F
        out[4 * i]     = (r * 527 + 23) >> 6
        out[4 * i + 1] = (g * 259 + 33) >> 6
        out[4 * i + 2] = (b * 527 + 23) >> 6
        out[4 * i + 3] = 0xFF
    return bytes(out)


def write_ppm(path, pixels, width=FRAME_W, height=FRAME_H):
    """Write RGB565 `pixels` to a binary PPM (P6) file."""
    with open(path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (width, height))
        f.write(rgb565_to_rgb888(pixels[:width * height]))
