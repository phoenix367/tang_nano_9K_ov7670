#!/usr/bin/env python3
"""Grab a camera frame into PSRAM channel 1 and download it over Modbus.

The FPGA captures a fresh 640x480 RGB565 frame into ch1 (register 0xF3 = 1),
then the host streams it back with back-to-back FC03 reads over the stream band
(>= 0x1000) after rewinding the pointer (register 0xF8). See
src/modbus/modbus_cam_backend.sv and the project memory for the register map.

Saves a binary PPM always; also a PNG if Pillow is installed.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from modbus_test import ModbusRTU  # noqa: E402

FRAME_W, FRAME_H = 640, 480
FRAME_PIXELS = FRAME_W * FRAME_H
REG_GRAB, REG_STREAM, STREAM_BASE = 0xF3, 0xF8, 0x1000


def grab_frame(mb, timeout=3.0, quiet=False):
    mb.write_single(REG_GRAB, 1)                       # arm
    deadline = time.monotonic() + timeout
    while mb.read_holding(REG_GRAB, 1)[0] & 1:
        if time.monotonic() > deadline:
            raise TimeoutError("frame grab did not complete")
        time.sleep(0.002)

    mb.write_single(REG_STREAM, 1)                     # rewind to pixel 0
    pix = []
    t0 = time.monotonic()
    while len(pix) < FRAME_PIXELS:
        n = min(125, FRAME_PIXELS - len(pix))
        pix.extend(mb.read_holding(STREAM_BASE, n))
        if not quiet and len(pix) % 12500 < 125:
            pct = 100 * len(pix) // FRAME_PIXELS
            print(f"\r  downloading... {pct:3d}%", end="", flush=True)
    if not quiet:
        dt = time.monotonic() - t0
        print(f"\r  downloaded {len(pix)} pixels in {dt:.2f}s "
              f"({FRAME_PIXELS * 2 / 1024 / dt:.1f} KiB/s)")
    return pix


def rgb565_to_rgb888(pixels):
    out = bytearray(len(pixels) * 3)
    for i, p in enumerate(pixels):
        r, g, b = (p >> 11) & 0x1F, (p >> 5) & 0x3F, p & 0x1F
        out[3 * i]     = (r * 527 + 23) >> 6
        out[3 * i + 1] = (g * 259 + 33) >> 6
        out[3 * i + 2] = (b * 527 + 23) >> 6
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description="Grab a frame from the Tang Nano 9K and save it")
    ap.add_argument("-p", "--port", default="/dev/ttyGowin", help="serial port")
    ap.add_argument("-b", "--baud", type=int, default=1000000, help="baud (default 1000000)")
    ap.add_argument("-s", "--slave", type=int, default=7, help="slave id (default 7)")
    ap.add_argument("--timeout", type=float, default=1.0, help="response timeout s")
    ap.add_argument("-o", "--out", default="frame.ppm",
                    help="output path (.ppm; .png too if Pillow)")
    args = ap.parse_args()

    mb = ModbusRTU(args.port, baud=args.baud, slave=args.slave, timeout=args.timeout)
    print(f"grabbing a frame from {args.port} @ {args.baud} baud ...")
    pix = grab_frame(mb)

    ppm = args.out if args.out.endswith(".ppm") else args.out + ".ppm"
    with open(ppm, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (FRAME_W, FRAME_H))
        f.write(rgb565_to_rgb888(pix[:FRAME_PIXELS]))
    print(f"wrote {ppm}")
    try:
        from PIL import Image
        png = ppm[:-4] + ".png"
        Image.open(ppm).save(png)
        print(f"wrote {png}")
    except ImportError:
        print("(install Pillow for a PNG too)")


if __name__ == "__main__":
    main()
