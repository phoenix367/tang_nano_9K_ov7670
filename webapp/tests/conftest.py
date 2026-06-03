"""Shared pytest fixtures. Adds webapp/ to sys.path so the app modules import,
and points pymodbus's serial transport (serial.serial_for_url) at the in-memory
FakeModbusSlave so the real pymodbus-backed ModbusRTU client + Flask routes run
end-to-end (real RTU framing/CRC) without hardware.
"""

import logging
import os
import sys

# webapp/ (parent of tests/) on the path -> import app / ov7670 / modbus_client
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import app as flask_app
import modbus_client
import pytest
import serial
from fake_modbus import FakeModbusSlave
from pymodbus.client import ModbusSerialClient

# pymodbus logs every transaction at DEBUG; quiet it so the fake-backed tests
# (esp. the full-frame downloads) don't pay per-transaction logging overhead.
logging.getLogger("pymodbus").setLevel(logging.CRITICAL)


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "hardware: host-side test that talks to a real connected board "
                   "(needs OV7670_PORT); skipped otherwise")
    config.addinivalue_line(
        "markers", "slow: hardware test that takes seconds (frame grab, re-init)")


@pytest.fixture
def fake(monkeypatch):
    """Point pymodbus's serial transport at a fresh FakeModbusSlave; expose it.

    pymodbus's ModbusSerialClient.connect() calls serial.serial_for_url(host,...),
    so patching that returns our fake as the socket. The fake emits real RTU
    frames (CRC included), so pymodbus parses them exactly as it would a board.
    """
    created = {}

    def factory(host, **kwargs):
        slave = FakeModbusSlave(port=host, **kwargs)
        created["slave"] = slave
        return slave

    monkeypatch.setattr(serial, "serial_for_url", factory)
    # the fake answers synchronously; don't poll-sleep waiting for "more" bytes
    monkeypatch.setattr(ModbusSerialClient, "_recv_interval", 0, raising=False)
    return created


@pytest.fixture
def rtu(fake):
    """A real ModbusRTU client wired to a fresh fake slave. Short timeout so the
    no-response / bad-CRC fault tests don't wait whole seconds per retry."""
    c = modbus_client.ModbusRTU("fake", slave=7, timeout=0.1)
    yield c, fake["slave"]
    c.close()


@pytest.fixture
def small_frame(monkeypatch):
    """Shrink FRAME_PIXELS so the client grab tests exercise the chunk/rewind
    loop in a few transactions rather than downloading a full 640x480 frame
    (the full-frame download is covered by the hardware tests)."""
    monkeypatch.setattr(modbus_client, "FRAME_PIXELS", 375)   # 3 x 125-reg chunks
    return 375


@pytest.fixture
def client(fake):
    """Flask test client with a clean (disconnected) app between tests."""
    flask_app._client = None
    yield flask_app.app.test_client(), fake
    if flask_app._client is not None:
        flask_app._client.close()
        flask_app._client = None


def connect(client_tuple, port="fake"):
    """Helper: drive /api/connect and return the parsed JSON."""
    test_client, _ = client_tuple
    return test_client.post("/api/connect", json={"port": port}).get_json()
