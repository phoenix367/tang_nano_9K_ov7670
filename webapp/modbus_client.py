"""Minimal Modbus RTU client for the Tang Nano 9K OV7670 bridge.

Speaks Modbus RTU over the FT2232H channel-B UART (1 Mbaud 8-E-1, slave id 7 by
default). The FPGA's modbus_rtu_slave maps each holding-register address 1:1 to
an OV7670 register (0x00..0xC9): a write uses the low byte of the value, a read
returns {0x00, reg_byte}. The RTU framing/CRC come from pymodbus
(ModbusSerialClient); this module is a thin device-specific wrapper that maps
pymodbus responses/exceptions to the small API the app and tests use.
"""

import os
import sys
import time

# repo root (parent of webapp/) on the path -> read the shared platform.json
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from osd_charset import osd_byte, osd_char
from pymodbus import FramerType
from pymodbus.client import ModbusSerialClient
from pymodbus.exceptions import ConnectionException, ModbusException

import platform_config as _platform

# UART/Modbus defaults come from platform.json (same source as the gateware).
DEFAULT_BAUD = _platform.UART_BAUD
DEFAULT_SLAVE = _platform.MODBUS_DEVICE_ID
# Address bound the FPGA slave enforces (FC03/06/10): the same 0x1100 span the
# gateware checks. MAX_READ_QTY is the device's FC03 ceiling; note read_holding()
# still clamps to the Modbus-spec 125 below, which is stricter.
MODBUS_ADDR_LIMIT = _platform.MODBUS_ADDR_LIMIT
MODBUS_MAX_READ_QTY = _platform.MODBUS_MAX_READ_QTY

# Reserved bridge registers above the OV7670 0x00..0xC9 range (see
# src/modbus/modbus_cam_backend.sv). The frame-grab feature captures a camera frame
# into PSRAM channel 1 and streams it back over FC03.
CAM_REG_MAX = 0x00C9   # highest OV7670 register (the 1:1-mapped camera range is 0x00..0xC9)
REG_GRAB    = 0x00F3   # write 1 = arm a grab, 2 = ch1 read, 3 = ch1 write;
                       # read bit0 = busy, bit1 = ch1 calibrated
REG_GRAB_ADDR_LO = 0x00F4   # write: ch1 read/write burst address [15:0]
REG_GRAB_ADDR_HI = 0x00F5   # write: ch1 read/write burst address [20:16]
REG_GRAB_DATA_HI = 0x00F6   # read: ch1 word [31:16]; write: ch1 write-data [31:16]
REG_GRAB_DATA_LO = 0x00F7   # read: ch1 word [15:0];  write: ch1 write-data [15:0]
REG_STREAM  = 0x00F8   # write = rewind the download stream to pixel 0
REG_HEARTBEAT = 0x00E0 # RW scratch; on a SERV_CONTROL build the SERV co-master
                       # increments it so the host can confirm the CPU is live
                       # on the bus. Reads 0 on a default (Modbus-only) build.
REG_MCU_RESET   = 0x00E2   # write bit0 = reset the SERV MCU (-> bootloader); reads 0
# SERV bootloader mailbox (SERV_CONTROL build). The bootloader polls these as a
# bus master; the host pushes an overlay firmware word-by-word. See doc/serv.md.
REG_BOOT_LEN    = 0x00E4   # write overlay length (16-bit words) -> begins upload
REG_BOOT_DATA   = 0x00E8   # write next overlay word (host); SERV consumes it
REG_BOOT_STATUS = 0x00EC   # read: bit1 = upload started, bit0 = word pending
REG_HEALTH  = 0x00F9   # read = watchdog health bits (see read_health)
REG_REINIT  = 0x00FA   # write 1 = re-run camera init (reset all registers to defaults)
REG_OSD_CTRL = 0x00FB  # write bit0 = enable, bit1 = clear; read bit0 = enable
REG_OSD_ADDR = 0x00FC  # OSD char-cell cursor (row*OSD_COLS + col); read or write
REG_OSD_DATA = 0x00FD  # char at the cursor: write a code or read it back; either auto-increments
OSD_STREAM_BASE = 0x0800  # FC03 reads in [0x0800..0x0FFF] burst-read consecutive OSD cells
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

    def __init__(self, port, baud=DEFAULT_BAUD, slave=DEFAULT_SLAVE, timeout=1.0, retries=2):
        if not (0 <= slave <= 247):
            raise ValueError(f"slave id {slave} out of range 0..247")
        self.port = port
        self.slave = slave
        self.retries = retries
        self._client = ModbusSerialClient(
            port,
            framer=FramerType.RTU,
            baudrate=baud,
            bytesize=_platform.UART_DATA_BITS,
            parity=_platform.UART_PARITY,
            stopbits=_platform.UART_STOP_BITS,
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

    def serv_mcu_reset(self):
        """Reset the SERV soft core (write 0xE2 bit0). The MCU restarts into its
        bootloader regardless of what it was running -- so this recovers even an
        overlay that parks (loops forever), letting the host then load any
        firmware. Requires a SERV_CONTROL build; a no-op on a Modbus-only build
        (the register reads 0 and nothing is wired to it)."""
        self.write_single(REG_MCU_RESET, 0x0001)

    def serv_boot_load(self, blob, reset_first=True, poll_timeout=2.0):
        """Upload an overlay firmware to the SERV bootloader and hand it control.

        `blob` is the raw overlay image (a .bin linked at 0x1000). It is packed
        into little-endian 16-bit words and streamed through the mailbox; the
        bootloader copies them into RAM and jumps to the overlay once it has
        received all of them.

        With `reset_first` (default) the MCU is reset back into the bootloader
        before the upload, so loading works regardless of what the MCU was running
        -- including over an overlay that parks. Pass `reset_first=False` to rely
        on the bootloader re-arming itself (only works if the running overlay
        returned to the bootloader, e.g. osd_hello). Requires a SERV_CONTROL build
        running the bootloader (see doc/serv.md). Returns the number of words sent.
        """
        data = bytes(blob)
        if len(data) % 2:
            data += b"\x00"                       # pad to a whole 16-bit word
        words = [data[i] | (data[i + 1] << 8) for i in range(0, len(data), 2)]
        if reset_first:
            self.serv_mcu_reset()                 # -> bootloader, waiting for an overlay
            time.sleep(0.01)                      # let the CPU re-run its power-on hold
        self.write_single(REG_BOOT_LEN, len(words))   # length -> start the upload
        for w in words:
            deadline = time.monotonic() + poll_timeout
            while self.read_holding(REG_BOOT_STATUS, 1)[0] & 0x01:   # wait empty
                if time.monotonic() > deadline:
                    raise TimeoutError(
                        "SERV bootloader did not drain the mailbox -- the bootloader "
                        "isn't waiting for an overlay. An overlay that returns to the "
                        "bootloader (e.g. osd_hello) re-loads without a reset; one that "
                        "parks needs a device reset first (or this isn't a SERV build)")
            self.write_single(REG_BOOT_DATA, w)
        return len(words)

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

    def osd_read_cells(self, row, col, count):
        """Read back `count` glyph codes from the OSD grid starting at (row, col).

        Sets the cursor (0xFC), then reads 0xFD `count` times. Each 0xFD read
        returns the cell at the cursor and auto-increments it, so the reads walk a
        run of cells. (FC03 cannot burst this: the slave walks consecutive register
        *addresses*, not repeated 0xFD reads, so one single-register read per cell.)
        Returns a list of byte codes (0..255).
        """
        if not (0 <= row < OSD_ROWS and 0 <= col < OSD_COLS):
            raise ValueError(f"OSD cell ({row}, {col}) out of range")
        self.write_single(REG_OSD_ADDR, row * OSD_COLS + col)
        return [self.read_reg(REG_OSD_DATA) for _ in range(count)]

    def osd_read_text(self):
        """Read the whole OSD character buffer back and decode it to text.

        Returns a list of strings (each up to OSD_COLS wide), trailing blank cells
        and all-blank rows stripped, so it reflects what is shown on the LCD.

        Uses the burst-read band: set the cursor to 0, then FC03-burst consecutive
        cells from OSD_STREAM_BASE (each band read returns the cell at the cursor
        and auto-increments it, so the cursor walks across the burst). The full
        1020-cell buffer is ~9 transactions instead of 1020 single 0xFD reads.
        """
        self.write_single(REG_OSD_ADDR, 0)
        codes = []
        while len(codes) < OSD_CELLS:
            n = min(125, OSD_CELLS - len(codes))   # FC03 burst (device MAX_QTY = 127)
            codes.extend(self.read_holding(OSD_STREAM_BASE, n))
        rows = ["".join(osd_char(b & 0xFF) for b in codes[r * OSD_COLS:(r + 1) * OSD_COLS]).rstrip()
                for r in range(OSD_ROWS)]
        while rows and rows[-1] == "":
            rows.pop()
        return rows

    # ---- frame grab (capture into PSRAM ch1, then stream over FC03) ----------
    def grab_busy(self):
        """True while a grab is still capturing into ch1."""
        return bool(self.read_holding(REG_GRAB, 1)[0] & 0x01)

    def _grab_wait_idle(self, timeout=1.0):
        deadline = time.monotonic() + timeout
        while self.grab_busy():
            if time.monotonic() > deadline:
                raise TimeoutError("ch1 PSRAM op did not complete (busy stuck)")
            time.sleep(0.001)

    def psram_write(self, addr, value, timeout=1.0):
        """Write a 32-bit `value` to every word of the ch1 PSRAM burst at `addr`
        (burst-aligned, step 16). Loads the value (0xF6/0xF7) + address (0xF4/0xF5)
        then triggers the write (0xF3<=3) and waits for completion. SERV_CONTROL
        is not required -- the write port is unconditional gateware."""
        value &= 0xFFFFFFFF
        self.write_single(REG_GRAB_DATA_HI, (value >> 16) & 0xFFFF)
        self.write_single(REG_GRAB_DATA_LO, value & 0xFFFF)
        self.write_single(REG_GRAB_ADDR_LO, addr & 0xFFFF)
        self.write_single(REG_GRAB_ADDR_HI, (addr >> 16) & 0x1F)
        self.write_single(REG_GRAB, 3)              # write-trigger
        self._grab_wait_idle(timeout)

    def psram_read(self, addr, timeout=1.0):
        """Read word 0 of the ch1 PSRAM burst at `addr` and return it as a 32-bit
        int (0xF6 = high half, 0xF7 = low half). Pairs with psram_write."""
        self.write_single(REG_GRAB_ADDR_LO, addr & 0xFFFF)
        self.write_single(REG_GRAB_ADDR_HI, (addr >> 16) & 0x1F)
        self.write_single(REG_GRAB, 2)              # read-trigger
        self._grab_wait_idle(timeout)
        hi = self.read_holding(REG_GRAB_DATA_HI, 1)[0] & 0xFFFF
        lo = self.read_holding(REG_GRAB_DATA_LO, 1)[0] & 0xFFFF
        return (hi << 16) | lo

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
