#!/usr/bin/env python3
"""Modbus RTU test client for the Tang Nano 9K modbus_rtu_slave.

Talks to the FPGA's Modbus RTU slave over the UART (1 Mbaud 8-E-1, slave id 7 by
default) and exercises the holding registers (FC03/06/16) plus the illegal-
address exception. Holding register 0's low 3 bits drive the board's status
LEDs, so the self-test ends by lighting a pattern you can see.

Only depends on pyserial (`pip install pyserial`); the RTU framing and CRC-16
are implemented here, so no pymodbus is needed.

Examples:
    scripts/modbus_test.py --port /dev/ttyGowin            # run the self-test
    scripts/modbus_test.py -p /dev/ttyUSB1 --read 0 8       # read 8 registers
    scripts/modbus_test.py -p /dev/ttyGowin --write 0 5     # reg0=5 -> LEDs 0,2
    scripts/modbus_test.py -p /dev/ttyGowin --write-multi 0 0x1111 0x2222
"""

import argparse
import os
import struct
import sys

try:
    import serial  # pyserial
except ImportError:
    sys.exit("error: pyserial not installed -- run: pip install pyserial")

# UART/Modbus defaults from the shared platform.json (same source as the
# gateware). Fall back to the historical 8-E-1 @ 1 Mbaud / id 7 if this script
# is run as a standalone copy without the repo's platform.json alongside it.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
try:
    import platform_config as _platform
    DEFAULT_BAUD, DEFAULT_SLAVE = _platform.UART_BAUD, _platform.MODBUS_DEVICE_ID
    DEFAULT_BYTESIZE = _platform.UART_DATA_BITS
    DEFAULT_PARITY = _platform.UART_PARITY
    DEFAULT_STOP = _platform.UART_STOP_BITS
except Exception:
    DEFAULT_BAUD, DEFAULT_SLAVE = 1000000, 7
    DEFAULT_BYTESIZE, DEFAULT_PARITY, DEFAULT_STOP = 8, "E", 1


def crc16(data: bytes) -> int:
    """CRC-16/Modbus (poly 0xA001, init 0xFFFF). Appended little-endian."""
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if (crc & 1) else (crc >> 1)
    return crc


def _u16(name, v):
    """Validate a 16-bit Modbus quantity (address or register value)."""
    if not isinstance(v, int) or not (0 <= v <= 0xFFFF):
        raise ValueError(f"{name} {v!r} out of range 0..65535 (0x0000..0xFFFF)")
    return v


class ModbusError(Exception):
    def __init__(self, code):
        self.code = code
        names = {1: "illegal function", 2: "illegal data address",
                 3: "illegal data value", 4: "slave device failure"}
        super().__init__(f"Modbus exception 0x{code:02X} ({names.get(code, '?')})")


class ModbusRTU:
    def __init__(self, port, baud=DEFAULT_BAUD, slave=DEFAULT_SLAVE, timeout=1.0):
        if not (0 <= slave <= 247):
            raise ValueError(f"slave id {slave} out of range 0..247")
        self.slave = slave
        self.ser = serial.Serial(
            port=port, baudrate=baud, bytesize=DEFAULT_BYTESIZE,
            parity=DEFAULT_PARITY, stopbits=DEFAULT_STOP,
            timeout=timeout)

    def close(self):
        self.ser.close()

    def _read_exact(self, n):
        buf = self.ser.read(n)
        if len(buf) != n:
            raise TimeoutError(f"timeout: wanted {n} bytes, got {len(buf)}")
        return buf

    def _txn(self, func, payload):
        """Send a request and return the response PDU bytes after the function."""
        req = bytes([self.slave, func]) + payload
        req += struct.pack("<H", crc16(req))
        self.ser.reset_input_buffer()
        self.ser.write(req)

        head = self._read_exact(2)          # addr, func
        rfunc = head[1]
        if rfunc & 0x80:                    # exception response
            rest = self._read_exact(3)      # code + CRC
            self._check_crc(head + rest)
            raise ModbusError(rest[0])
        if rfunc == 0x03:
            bc = self._read_exact(1)
            rest = bc + self._read_exact(bc[0] + 2)
        elif rfunc in (0x06, 0x10):
            rest = self._read_exact(4 + 2)  # echo/ack (4) + CRC
        else:
            raise ValueError(f"unexpected function 0x{rfunc:02X} in response")
        self._check_crc(head + rest)
        if head[0] != self.slave:
            raise ValueError(f"response from slave {head[0]}, expected {self.slave}")
        return rest

    @staticmethod
    def _check_crc(frame):
        if crc16(frame) != 0:
            raise ValueError("response CRC mismatch")

    def read_holding(self, addr, count):
        _u16("address", addr)
        if not (1 <= count <= 125):
            raise ValueError(f"read count {count} out of range 1..125")
        if addr + count > 0x10000:
            raise ValueError(f"address+count {addr + count} exceeds 0x10000")
        rest = self._txn(0x03, struct.pack(">HH", addr, count))
        bc = rest[0]
        if bc != 2 * count:
            raise ValueError(f"byte count {bc} != expected {2 * count}")
        data = rest[1:1 + bc]
        return list(struct.unpack(">" + "H" * count, data))

    def write_single(self, addr, value):
        _u16("address", addr)
        _u16("value", value)
        self._txn(0x06, struct.pack(">HH", addr, value))

    def write_multiple(self, addr, values):
        _u16("address", addr)
        if not (1 <= len(values) <= 123):
            raise ValueError(f"register count {len(values)} out of range 1..123")
        if addr + len(values) > 0x10000:
            raise ValueError(f"address+count {addr + len(values)} exceeds 0x10000")
        for i, v in enumerate(values):
            _u16(f"value[{i}]", v)
        payload = struct.pack(">HHB", addr, len(values), 2 * len(values))
        payload += b"".join(struct.pack(">H", v) for v in values)
        self._txn(0x10, payload)


def self_test(mb, reg_count):
    """Mirror the HDL testbench against the live slave. Returns failure count."""
    fails = 0

    def check(label, ok, detail=""):
        nonlocal fails
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}{(': ' + detail) if detail else ''}")
        if not ok:
            fails += 1

    # FC06 write + FC03 read-back
    mb.write_single(5, 0xBEEF)
    v = mb.read_holding(5, 1)[0]
    check("FC06 write reg5=0xBEEF, FC03 read-back", v == 0xBEEF, f"got 0x{v:04X}")

    # FC16 write multiple + read-back
    vals = [0x1111, 0x2222, 0x3333]
    mb.write_multiple(0, vals)
    rb = mb.read_holding(0, 3)
    check("FC16 write regs0-2, FC03 read-back", rb == vals,
          f"got {[hex(x) for x in rb]}")

    # illegal data address -> exception 0x02
    try:
        mb.read_holding(reg_count, 1)
        check("FC03 illegal address raises exception", False, "no exception")
    except ModbusError as e:
        check("FC03 illegal address raises exception", e.code == 2, str(e))

    # LED demo: reg0 low 3 bits -> status LEDs
    mb.write_single(0, 0b101)
    print("  [demo] wrote reg0=0b101 -- board status LEDs 0 and 2 should be lit")

    return fails


def parse_int(s):
    return int(s, 0)


def main():
    ap = argparse.ArgumentParser(description="Modbus RTU test client for the Tang Nano 9K slave")
    ap.add_argument("-p", "--port", default="/dev/ttyGowin",
                    help="serial port (default: /dev/ttyGowin)")
    ap.add_argument("-b", "--baud", type=int, default=DEFAULT_BAUD,
                    help=f"baud rate (default {DEFAULT_BAUD})")
    ap.add_argument("-s", "--slave", type=int, default=DEFAULT_SLAVE,
                    help=f"slave/unit id (default {DEFAULT_SLAVE})")
    ap.add_argument("--timeout", type=float, default=1.0, help="response timeout s (default 1.0)")
    ap.add_argument("--reg-count", type=int, default=8,
                    help="holding registers on the slave (default 8)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--read", nargs=2, metavar=("ADDR", "COUNT"), type=parse_int,
                   help="read COUNT holding registers from ADDR")
    g.add_argument("--write", nargs=2, metavar=("ADDR", "VALUE"), type=parse_int,
                   help="write VALUE to a single holding register ADDR")
    g.add_argument("--write-multi", nargs="+", metavar="ADDR V...", type=parse_int,
                   help="write values V... to consecutive registers starting at ADDR")
    args = ap.parse_args()

    try:
        mb = ModbusRTU(args.port, args.baud, args.slave, args.timeout)
    except serial.SerialException as e:
        sys.exit(f"error: cannot open {args.port}: {e}")

    try:
        if args.read:
            addr, count = args.read
            regs = mb.read_holding(addr, count)
            for i, v in enumerate(regs):
                print(f"  reg[{addr + i}] = 0x{v:04X} ({v})")
        elif args.write:
            addr, value = args.write
            mb.write_single(addr, value)
            print(f"  wrote reg[{addr}] = 0x{value & 0xFFFF:04X}")
        elif args.write_multi:
            addr, values = args.write_multi[0], args.write_multi[1:]
            if not values:
                sys.exit("--write-multi needs ADDR and at least one value")
            mb.write_multiple(addr, values)
            print(f"  wrote {len(values)} regs from {addr}: {[hex(v) for v in values]}")
        else:
            print(f"Modbus RTU self-test on {args.port} (slave {args.slave}, {args.baud} 8-E-1)")
            fails = self_test(mb, args.reg_count)
            print("RESULT:", "PASS" if fails == 0 else f"FAIL ({fails})")
            sys.exit(0 if fails == 0 else 1)
    except (TimeoutError, ModbusError, ValueError) as e:
        sys.exit(f"error: {e}")
    finally:
        mb.close()


if __name__ == "__main__":
    main()
