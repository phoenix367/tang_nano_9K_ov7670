"""An in-memory Modbus RTU slave that mimics the FPGA bridge, used as a fake
serial backend so the real ModbusRTU client and the Flask app can be tested
end-to-end without hardware.

It implements the pyserial Serial surface the client uses (write/read/
reset_input_buffer/close) plus FC03/FC06/FC10, the reserved status registers
(0xF0 magic, 0xF1/0xF2 uptime), illegal-address/-value exceptions, and knobs to
simulate faults (silence -> timeout, bad CRC, vanished port).
"""

import struct

import modbus_client  # for crc16 + (optional) termios

REG_COUNT = 0x1100                    # matches the FPGA: camera + status/grab + stream band
STATUS_MAGIC = 0xA5
STREAM_BASE = 0x1000                  # FC03 reads >= here stream the captured frame
FRAME_PIXELS = modbus_client.FRAME_PIXELS


def fake_pixel(i):
    """Deterministic stand-in frame: pixel i = i & 0xFFFF, so a download can be
    checked for correct order and completeness without hardware."""
    return i & 0xFFFF


def default_registers():
    """A snapshot resembling the camera after init (so decode/matrix make sense)."""
    regs = {a: 0 for a in range(256)}
    regs.update({
        0x0A: 0x76, 0x0B: 0x73, 0x1C: 0x7F, 0x1D: 0xA2,   # identity (PID/VER/MIDH/MIDL)
        0x00: 0x07,                                        # GAIN
        0x10: 0x50,                                        # AECH (exposure)
        0x13: 0xE7,                                        # COM8: AGC+AWB+AEC on
        0x1E: 0x00,                                        # MVFP: no mirror/flip
        0x3A: 0x0C,                                        # TSLB
        0x3B: 0x00,                                        # COM11
        0x3D: 0x00,                                        # COM13: gamma off
        0x55: 0x80, 0x56: 0x40,                            # brightness / contrast
        0x70: 0x3A, 0x71: 0x35,                            # SCALING_XSC/YSC: pattern none
        0x4F: 0x80, 0x50: 0x80, 0x51: 0x00,                # MTX1..3
        0x52: 0x22, 0x53: 0x5E, 0x54: 0x80,                # MTX4..6
        0x58: 0x9E,                                        # MTXS
        0x82: 0x60,                                        # a mid gamma breakpoint
    })
    return regs


class FakeModbusSlave:
    def __init__(self, port=None, baudrate=9600, bytesize=8, parity="E",
                 stopbits=1, timeout=1.0, slave=7, reg_count=REG_COUNT):
        self.port = port
        self.slave_addr = slave
        self.reg_count = reg_count
        self.regs = default_registers()
        self.uptime = 0x1234
        self.stream_ptr = 0           # frame-download pixel cursor (rewound by 0xF8)
        self._rx = bytearray()        # bytes the client will read back
        self.is_open = True
        # fault injection
        self.silent = False           # produce no response -> client times out
        self.bad_crc = False          # corrupt the response CRC
        self.fail_on_reset = None      # exception raised by reset_input_buffer
        self.fail_on_io = None         # exception raised by write/read

    # ---- pyserial Serial surface ----
    def reset_input_buffer(self):
        if self.fail_on_reset is not None:
            raise self.fail_on_reset
        self._rx.clear()

    def write(self, data):
        if self.fail_on_io is not None:
            raise self.fail_on_io
        self._handle(bytes(data))
        return len(data)

    def read(self, n):
        if self.fail_on_io is not None:
            raise self.fail_on_io
        out = bytes(self._rx[:n])
        del self._rx[:n]
        return out                     # may be < n -> client raises TimeoutError

    def close(self):
        self.is_open = False

    # ---- slave behaviour ----
    def _read_reg(self, addr):
        if addr == 0xF0:
            return STATUS_MAGIC
        if addr == 0xF1:
            return (self.uptime >> 8) & 0xFF
        if addr == 0xF2:
            return self.uptime & 0xFF
        if addr == 0xF3:
            return 0x02              # bit1 = ch1 calibrated, bit0 = busy (grab instant)
        return self.regs.get(addr, 0) & 0xFF

    def _reply(self, func, payload):
        if self.silent:
            return
        frame = bytes([self.slave_addr, func]) + payload
        crc = modbus_client.crc16(frame)
        if self.bad_crc:
            crc ^= 0xFFFF
        self._rx += frame + struct.pack("<H", crc)

    def _exception(self, func, code):
        self._reply(func | 0x80, bytes([code]))

    def _handle(self, req):
        if len(req) < 4 or modbus_client.crc16(req) != 0:
            return                      # malformed / bad CRC -> no reply (like the FPGA)
        addr, func = req[0], req[1]
        if addr != self.slave_addr:
            return
        body = req[2:-2]
        if func == 0x03:
            saddr, qty = struct.unpack(">HH", body[:4])
            if qty == 0:
                return self._exception(func, 0x03)
            if saddr + qty > self.reg_count:
                return self._exception(func, 0x02)
            if saddr >= STREAM_BASE:
                # frame download: serve the next qty pixels, advance the cursor
                data = b"".join(struct.pack(">H", fake_pixel(self.stream_ptr + i))
                                for i in range(qty))
                self.stream_ptr += qty
                return self._reply(func, bytes([2 * qty]) + data)
            data = b"".join(struct.pack(">H", self._read_reg(saddr + i)) for i in range(qty))
            self._reply(func, bytes([2 * qty]) + data)
        elif func == 0x06:
            saddr, val = struct.unpack(">HH", body[:4])
            if saddr == 0xF8:                   # rewind the download stream
                self.stream_ptr = 0
                return self._reply(func, body[:4])
            if saddr == 0xF3:                   # arm grab (instant in the fake)
                return self._reply(func, body[:4])
            if saddr >= self.reg_count:
                return self._exception(func, 0x02)
            self.regs[saddr] = val & 0xFF
            self._reply(func, body[:4])         # echo address + value
        elif func == 0x10:
            saddr, qty = struct.unpack(">HH", body[:4])
            bc = body[4]
            if qty == 0:
                return self._exception(func, 0x03)
            if saddr + qty > self.reg_count or bc != 2 * qty:
                return self._exception(func, 0x02)
            vals = struct.unpack(">" + "H" * qty, body[5:5 + 2 * qty])
            for i, v in enumerate(vals):
                self.regs[saddr + i] = v & 0xFF
            self._reply(func, struct.pack(">HH", saddr, qty))
        else:
            self._exception(func, 0x01)
