"""Modbus spec-conformance tests against a real board, using a *vanilla*
pymodbus client directly (no project wrapper). Where test_device_hw.py exercises
our `modbus_client.ModbusRTU` API, this proves the FPGA slave interoperates with
a reference-grade RTU master at the protocol level: FC03/FC06, register values,
exception codes, multi-register bursts, and address checking.

Skipped unless OV7670_PORT names a connected board (see test_device_hw.py):

    OV7670_PORT=/dev/ttyGowin .venv/bin/python -m pytest \\
        webapp/tests/test_device_conformance.py -v
"""

import os

import ov7670
import pytest
from pymodbus import FramerType
from pymodbus.client import ModbusSerialClient
from pymodbus.exceptions import ModbusIOException

PORT = os.environ.get("OV7670_PORT")
SLAVE = int(os.environ.get("OV7670_SLAVE", "7"))

pytestmark = [
    pytest.mark.hardware,
    pytest.mark.skipif(not PORT, reason="set OV7670_PORT to a connected board"),
]


@pytest.fixture(scope="module")
def mb():
    """A plain pymodbus ModbusSerialClient — the reference master."""
    client = ModbusSerialClient(
        PORT, framer=FramerType.RTU,
        baudrate=int(os.environ.get("OV7670_BAUD", "1000000")),
        bytesize=8, parity="E", stopbits=1, timeout=1.0,
    )
    if not client.connect():
        pytest.skip(f"cannot open {PORT}")
    rr = client.read_holding_registers(ov7670.STATUS_MAGIC_ADDR, count=1, device_id=SLAVE)
    if rr.isError() or rr.registers[0] != ov7670.STATUS_MAGIC:
        client.close()
        pytest.skip(f"not the OV7670 bridge on {PORT}")
    yield client
    client.close()


def test_fc03_read_single(mb):
    """FC03 read holding registers: firmware magic comes back as 0xA5."""
    rr = mb.read_holding_registers(ov7670.STATUS_MAGIC_ADDR, count=1, device_id=SLAVE)
    assert not rr.isError()
    assert rr.registers == [ov7670.STATUS_MAGIC]


def test_fc03_identity(mb):
    """The OV7670 identity registers read back their datasheet values."""
    for addr, _name, expected in ov7670.IDENTITY:
        rr = mb.read_holding_registers(addr, count=1, device_id=SLAVE)
        assert not rr.isError()
        assert rr.registers[0] & 0xFF == expected


def test_fc03_burst(mb):
    """A multi-register FC03 returns exactly the requested quantity."""
    for qty in (2, 16, 125):              # 125 = spec max for read holding registers
        rr = mb.read_holding_registers(0x00, count=qty, device_id=SLAVE)
        assert not rr.isError()
        assert len(rr.registers) == qty


def test_fc06_write_single_round_trip(mb):
    """FC06 write single register, read back, then restore."""
    addr = 0x55                            # brightness (reversible)
    original = mb.read_holding_registers(addr, count=1, device_id=SLAVE).registers[0]
    try:
        wr = mb.write_register(addr, 0x42, device_id=SLAVE)
        assert not wr.isError()
        rr = mb.read_holding_registers(addr, count=1, device_id=SLAVE)
        assert rr.registers[0] & 0xFF == 0x42
    finally:
        mb.write_register(addr, original, device_id=SLAVE)


def test_illegal_address_exception(mb):
    """Reading past the address space returns illegal-data-address (code 2)."""
    rr = mb.read_holding_registers(0xFFFF, count=1, device_id=SLAVE)
    assert rr.isError()
    assert getattr(rr, "exception_code", None) == 2


def test_wrong_slave_is_ignored(mb):
    """The slave answers only its own address; another id gets no reply at all,
    which a spec master surfaces as an I/O timeout (not an exception response)."""
    with pytest.raises(ModbusIOException):
        mb.read_holding_registers(ov7670.STATUS_MAGIC_ADDR, count=1,
                                  device_id=(SLAVE + 1) & 0xFF)
