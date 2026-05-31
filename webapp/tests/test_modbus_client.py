"""Tests for the Modbus RTU client: CRC, framing, exceptions, retries, and the
termios.error -> OSError normalization."""

import pytest

import modbus_client
from modbus_client import CRCError, ModbusError


def test_crc16_known_vector():
    # canonical Modbus vector: 01 03 00 00 00 01 -> 0x0A84
    assert modbus_client.crc16(b"\x01\x03\x00\x00\x00\x01") == 0x0A84


def test_crc16_full_frame_is_zero():
    body = b"\x07\x03\x00\x0a\x00\x01"
    crc = modbus_client.crc16(body)
    frame = body + bytes([crc & 0xFF, crc >> 8])
    assert modbus_client.crc16(frame) == 0      # appended low-first -> whole frame CRCs to 0


def test_read_reg(rtu):
    c, slave = rtu
    assert c.read_reg(0x0A) == 0x76             # PID from the fake's defaults


def test_read_holding_multiple(rtu):
    c, _ = rtu
    assert c.read_holding(0x0A, 3) == [0x76, 0x73, 0x00]


def test_write_then_read_back(rtu):
    c, slave = rtu
    c.write_reg(0x55, 0xAB)
    assert slave.regs[0x55] == 0xAB             # only the low byte reaches the slave
    assert c.read_reg(0x55) == 0xAB


def test_write_takes_low_byte_only(rtu):
    c, slave = rtu
    c.write_single(0x55, 0x12AB)
    assert slave.regs[0x55] == 0xAB


def test_illegal_address_raises_modbus_exception(rtu):
    c, _ = rtu
    with pytest.raises(ModbusError) as ei:
        c.read_holding(0x1100, 1)               # past REG_COUNT (above the stream band)
    assert ei.value.code == 0x02


def test_timeout_raises(rtu):
    c, slave = rtu
    slave.silent = True
    with pytest.raises(TimeoutError):
        c.read_reg(0x0A)


def test_bad_crc_retried_then_raises(rtu):
    c, slave = rtu
    slave.bad_crc = True
    with pytest.raises(CRCError):
        c.read_reg(0x0A)


def test_bad_crc_recovers_within_retries(rtu):
    c, slave = rtu

    calls = {"n": 0}
    orig_write = slave.write

    def flaky_write(data):
        calls["n"] += 1
        slave.bad_crc = (calls["n"] == 1)       # first attempt bad, then good
        return orig_write(data)

    slave.write = flaky_write
    assert c.read_reg(0x0A) == 0x76             # retry succeeds


def test_termios_error_normalized_to_oserror(rtu):
    c, slave = rtu
    termios = pytest.importorskip("termios")
    slave.fail_on_reset = termios.error(5, "Input/output error")
    with pytest.raises(OSError):                # NOT termios.error escaping as a 500
        c.read_reg(0x0A)


def test_serial_oserror_propagates(rtu):
    c, slave = rtu
    slave.fail_on_io = OSError("device gone")
    with pytest.raises(OSError):
        c.read_reg(0x0A)


# ----------------------------------------------------- frame grab + conversion
def test_grab_frame_pattern(rtu):
    c, _ = rtu
    pix = c.grab_frame()
    assert len(pix) == modbus_client.FRAME_PIXELS
    # the fake serves pixel i = i & 0xFFFF, in raster order
    assert pix[0] == 0 and pix[1] == 1 and pix[125] == 125
    assert pix[-1] == (modbus_client.FRAME_PIXELS - 1) & 0xFFFF


def test_grab_frame_rewinds_each_time(rtu):
    c, _ = rtu
    assert c.grab_frame() == c.grab_frame()      # 0xF8 rewind -> identical frames


def test_rgb565_to_rgba_primaries():
    assert modbus_client.rgb565_to_rgba([0xFFFF]) == bytes([255, 255, 255, 255])
    assert modbus_client.rgb565_to_rgba([0x0000]) == bytes([0, 0, 0, 255])
    assert modbus_client.rgb565_to_rgba([0xF800]) == bytes([255, 0, 0, 255])
    assert modbus_client.rgb565_to_rgba([0x07E0]) == bytes([0, 255, 0, 255])
    assert modbus_client.rgb565_to_rgba([0x001F]) == bytes([0, 0, 255, 255])


def test_rgb565_to_rgb888_length():
    assert len(modbus_client.rgb565_to_rgb888([0, 1, 2])) == 9
