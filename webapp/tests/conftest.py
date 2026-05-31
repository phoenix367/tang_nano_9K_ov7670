"""Shared pytest fixtures. Adds webapp/ to sys.path so the app modules import,
and patches pyserial's Serial with the in-memory FakeModbusSlave so the real
ModbusRTU client + Flask routes run without hardware.
"""

import os
import sys

# webapp/ (parent of tests/) on the path -> import app / ov7670 / modbus_client
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest

import app as flask_app
import modbus_client
from fake_modbus import FakeModbusSlave


@pytest.fixture
def fake(monkeypatch):
    """Patch ModbusRTU's serial backend; expose the most-recently created slave."""
    created = {}

    def factory(*args, **kwargs):
        slave = FakeModbusSlave(*args, **kwargs)
        created["slave"] = slave
        return slave

    monkeypatch.setattr(modbus_client.serial, "Serial", factory)
    return created


@pytest.fixture
def rtu(fake):
    """A real ModbusRTU client wired to a fresh fake slave."""
    c = modbus_client.ModbusRTU("fake", slave=7)
    yield c, fake["slave"]
    c.close()


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
