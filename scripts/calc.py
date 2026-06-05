#!/usr/bin/env python3
"""Console front-end for the SERV floating-point calculator overlay.

Uploads demo_mcu_apps/calc to the Tang Nano 9K's SERV soft core (a SERV-enabled,
16 KB-RAM bitstream) and uses it as a floating-point coprocessor over Modbus: each
operation is streamed to the MCU, computed there in IEEE-754 single precision
(libgcc soft-float -- SERV has no FPU), and the 32-bit result is read back.

Interactive (a REPL):
    scripts/calc.py -p /dev/ttyGowin
    calc> 2.5 + 4.0
    = 6.5
    calc> sqrt 2
    = 1.4142135
    calc> 2 ^ 10
    = 1024.0
    calc> 1/x 8
    = 0.125

One-shot (quote * and ^ for the shell):
    scripts/calc.py -p /dev/ttyGowin '3 * 7'
    scripts/calc.py -p /dev/ttyGowin sqrt 2

Operators: + - * /  and  ^ (integer power).  Functions: sqrt <x>, 1/x <x>
(aliases recip/inv). Requires the calc overlay built (cmake --build build --target
serv_firmware -> build/serv_fw/calc.bin); pass --no-load if it's already running.
"""
import argparse
import math
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from modbus_test import DEFAULT_BAUD, DEFAULT_SLAVE, ModbusRTU  # noqa: E402

# --- register map (see doc/modbus_server.md) ---
REG_HEARTBEAT, REG_MCU_RESET = 0xE0, 0xE2
REG_BOOT_LEN, REG_BOOT_DATA, REG_BOOT_STATUS = 0xE4, 0xE8, 0xEC
REG_OSD_ADDR, REG_OSD_DATA = 0xFC, 0xFD
OSD_COLS = 60
RESULT_CELL = 16 * OSD_COLS + 0          # calc writes 4 raw result bytes here

# opcodes (must match demo_mcu_apps/calc/calc.c)
OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_SQRT, OP_RECIP, OP_POW = range(7)
BINARY = {"+": OP_ADD, "-": OP_SUB, "*": OP_MUL, "/": OP_DIV, "^": OP_POW}
UNARY = {"sqrt": OP_SQRT, "1/x": OP_RECIP, "recip": OP_RECIP, "inv": OP_RECIP}
DEFAULT_BIN = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "build", "serv_fw", "calc.bin")


def reset_mcu(mb):
    mb.write_single(REG_MCU_RESET, 1)                # -> bootloader
    time.sleep(0.02)


def boot_load(mb, blob, timeout=2.0):
    """Reset the MCU and stream an overlay into it via the bootloader mailbox."""
    reset_mcu(mb)
    data = blob + (b"\x00" if len(blob) % 2 else b"")
    words = [data[i] | (data[i + 1] << 8) for i in range(0, len(data), 2)]
    mb.write_single(REG_BOOT_LEN, len(words))
    for w in words:
        deadline = time.monotonic() + timeout
        while mb.read_holding(REG_BOOT_STATUS, 1)[0] & 1:
            if time.monotonic() > deadline:
                raise TimeoutError("bootloader did not drain the mailbox")
        mb.write_single(REG_BOOT_DATA, w)
    time.sleep(0.3)                                  # let calc start + paint the OSD
    return len(words)


def calc(mb, op, a, b=0.0, timeout=2.0):
    """Send one operation to the calc overlay and return the device's float result."""
    mb.write_single(REG_HEARTBEAT, 0xFF)             # done-sentinel
    pa = struct.unpack("<HH", struct.pack("<f", float(a)))
    pb = struct.unpack("<HH", struct.pack("<f", float(b)))
    for w in (op, pa[0], pa[1], pb[0], pb[1]):
        deadline = time.monotonic() + timeout
        while mb.read_holding(REG_BOOT_STATUS, 1)[0] & 1:
            if time.monotonic() > deadline:
                raise TimeoutError("calc mailbox not drained -- is the calc overlay running?")
        mb.write_single(REG_BOOT_DATA, w)
    deadline = time.monotonic() + timeout
    while (mb.read_holding(REG_HEARTBEAT, 1)[0] & 0xFF) == 0xFF:
        if time.monotonic() > deadline:
            raise TimeoutError("calc did not return a result")
    mb.write_single(REG_OSD_ADDR, RESULT_CELL)
    cells = bytes(mb.read_holding(REG_OSD_DATA, 1)[0] & 0xFF for _ in range(4))
    return struct.unpack("<f", cells)[0]


def parse(line):
    """Parse 'a op b' / 'fn x' into (opcode, a, b). Raises ValueError on bad input."""
    t = line.replace(",", " ").split()
    if not t:
        raise ValueError("empty")
    if t[0].lower() in UNARY:
        if len(t) != 2:
            raise ValueError(f"{t[0]} takes one argument: {t[0]} <x>")
        return UNARY[t[0].lower()], float(t[1]), 0.0
    if len(t) == 3 and t[1] in BINARY:
        return BINARY[t[1]], float(t[0]), float(t[2])
    raise ValueError("expected '<a> <op> <b>' (op + - * / ^) or 'sqrt <x>' / '1/x <x>'")


def host_reference(op, a, b):
    """What the host's own float math gives, for an optional cross-check."""
    try:
        return {OP_ADD: a + b, OP_SUB: a - b, OP_MUL: a * b,
                OP_DIV: a / b if b else math.inf,
                OP_SQRT: math.sqrt(a) if a >= 0 else 0.0,
                OP_RECIP: 1.0 / a if a else math.inf,
                OP_POW: a ** int(b)}[op]
    except Exception:
        return None


def evaluate(mb, line, verify=False):
    op, a, b = parse(line)
    r = calc(mb, op, a, b)
    out = f"= {r:.7g}"
    if verify:
        ref = host_reference(op, a, b)
        if ref is not None and abs(r - ref) > 1e-3 * max(1.0, abs(ref)):
            out += f"   (host: {ref:.7g}  DIFF!)"
        elif ref is not None:
            out += f"   (host: {ref:.7g})"
    return out


def main():
    ap = argparse.ArgumentParser(description="SERV floating-point calculator console")
    ap.add_argument("-p", "--port", required=True, help="serial port (e.g. /dev/ttyGowin)")
    ap.add_argument("-b", "--baud", type=int, default=DEFAULT_BAUD)
    ap.add_argument("-s", "--slave", type=int, default=DEFAULT_SLAVE)
    ap.add_argument("--bin", default=DEFAULT_BIN,
                    help="calc overlay (default: build/serv_fw/calc.bin)")
    ap.add_argument("--no-load", action="store_true",
                    help="don't upload the overlay (assume already running)")
    ap.add_argument("--verify", action="store_true", help="also show the host's own float result")
    ap.add_argument("expr", nargs="*", help="one-shot expression, e.g. '3 * 7' or sqrt 2")
    args = ap.parse_args()

    mb = ModbusRTU(args.port, baud=args.baud, slave=args.slave, timeout=1.0)
    try:
        if not args.no_load:
            if not os.path.exists(args.bin):
                sys.exit(f"error: {args.bin} not found -- build it with:\n"
                         f"  cmake --build build --target serv_firmware\n"
                         f"(or pass --no-load if the calc overlay is already running)")
            with open(args.bin, "rb") as f:
                n = boot_load(mb, f.read())
            print(f"loaded calc overlay ({n} words) on {args.port}")

        if args.expr:                                # one-shot
            print(evaluate(mb, " ".join(args.expr), args.verify))
            return

        print("SERV float calculator. Examples: '2.5 + 4.0', 'sqrt 2', '2 ^ 10', '1/x 8'.")
        print("Type 'q' to quit.")
        while True:
            try:
                line = input("calc> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not line:
                continue
            if line.lower() in ("q", "quit", "exit"):
                break
            try:
                print(evaluate(mb, line, args.verify))
            except ValueError as e:
                print(f"?  {e}")
            except (TimeoutError, OSError) as e:
                print(f"device error: {e}")
    finally:
        mb.close()


if __name__ == "__main__":
    main()
