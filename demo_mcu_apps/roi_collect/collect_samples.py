#!/usr/bin/env python3
"""Collect labelled face / no-face training samples from the fixed ROI.

Companion to the roi_collect overlay (which draws the alignment box on the LCD)
and to roi_presence (which will run the trained classifier). Skin-colour gating is
unreliable for this camera, so instead we harvest labelled ROI patches here and
train a real classifier offline.

Each sample is the SAME 22x14 grid of ROI cells that roi_presence scans -- read
straight out of channel-1 PSRAM after a host-armed frame grab -- so the data
matches the deployed input exactly. The MCU is not involved in the read: the
roi_collect overlay just draws the box and parks (no bus traffic), leaving the
wb_grab port free for this script.

Workflow:
    1. Align your face to the box on the LCD (or leave the frame empty for a
       no-face sample).
    2. The script grabs a frame, reads the ROI, shows an ASCII luma preview.
    3. You label it: [f]ace / [n]o-face. The labelled RGB565 patch is appended to
       a JSONL dataset (resumable -- re-run to keep adding).

Usage:
    .venv/bin/python demo_mcu_apps/roi_collect/collect_samples.py -p /dev/ttyGowin
    # already running the overlay (or a Modbus-only build, with --draw-box):
    .venv/bin/python demo_mcu_apps/roi_collect/collect_samples.py -p /dev/ttyGowin --no-load --draw-box

Dataset: demo_mcu_apps/roi_collect/samples.jsonl (override with -o). Each line:
    {"label": 0|1, "roi565": [<308 RGB565 ints, row-major over the ROI grid>]}
The ROI geometry is fixed below and must stay in sync with roi_collect.c /
roi_presence.c.
"""
import argparse
import json
import os
import sys
import time

# repo root is two dirs up (demo_mcu_apps/roi_collect/ -> repo); use the webapp's
# pymodbus-backed client (it has psram_read + the grab/OSD helpers we need).
_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(_REPO, "webapp"))
from modbus_client import (  # noqa: E402
    ModbusRTU, DEFAULT_BAUD, DEFAULT_SLAVE, REG_GRAB, REG_OSD_ADDR, REG_OSD_DATA,
)

# ---- fixed ROI geometry: MUST match roi_collect.c / roi_presence.c ----
COL_STEP = 16          # PSRAM burst-address step per grid column (cam_col = cc*16)
ROW_STEP = 19200       # per grid row (30 source rows * 640; cam_row = rr*30)
ROI_C0, ROI_C1 = 9, 30
ROI_R0, ROI_R1 = 1, 14
ROI_COLS = ROI_C1 - ROI_C0 + 1     # 22
ROI_ROWS = ROI_R1 - ROI_R0 + 1     # 14
ROI_CELLS = ROI_COLS * ROI_ROWS    # 308

# pillarbox-correct OSD mapping (grid col/row -> OSD cell), matching roi_collect.c
COL_LUT = [7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 19, 20, 21, 22, 23, 24, 25, 27, 28, 29,
           30, 31, 32, 33, 34, 36, 37, 38, 39, 40, 41, 42, 44, 45, 46, 47, 48, 49, 50, 51]
ROW_LUT = [0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16]
OSD_COLS = 60
# OSD box-drawing glyph codes (match roi_collect.c)
BX_H, BX_V, BX_TL, BX_TR, BX_BL, BX_BR = 0x80, 0x81, 0x82, 0x83, 0x84, 0x85

DEFAULT_BIN = os.path.join(_REPO, "build", "serv_fw", "roi_collect.bin")
DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples.jsonl")
RAMP = " .:-=+*#%@"   # luma -> char, 0..125 brightness


def luma(p):
    """RGB565 -> 0..125 brightness (R5 + G6 + B5), matching the MCU's brightness()."""
    return ((p >> 11) & 0x1F) + ((p >> 5) & 0x3F) + (p & 0x1F)


def is_skin(p):
    """The roi_presence skin rule, for a sanity readout alongside each capture."""
    r = (p >> 11) & 0x1F
    g5 = (p >> 6) & 0x1F
    b = p & 0x1F
    return r > g5 and g5 >= b and (r - b) >= 4 and 11 <= r <= 26


def grab_roi(mb, grab_timeout=3.0):
    """Arm a fresh frame grab into ch1, then read the ROI grid out of PSRAM.

    Returns a flat list of ROI_CELLS RGB565 ints, row-major (top ROI row first).
    Only the capture is host-triggered; the parked overlay never touches the bus.
    """
    mb.write_single(REG_GRAB, 1)                 # arm a capture into ch1
    deadline = time.monotonic() + grab_timeout
    while mb.grab_busy():
        if time.monotonic() > deadline:
            raise TimeoutError("frame grab did not complete")
        time.sleep(0.002)

    roi = []
    for rr in range(ROI_R0, ROI_R1 + 1):
        base = rr * ROW_STEP
        for cc in range(ROI_C0, ROI_C1 + 1):
            word = mb.psram_read(base + cc * COL_STEP)
            roi.append((word >> 16) & 0xFFFF)     # high-half pixel (== MCU psram_read16)
    return roi


def preview(roi):
    """Return an ASCII luma preview (ROI_ROWS lines of ROI_COLS chars)."""
    lines = []
    for r in range(ROI_ROWS):
        row = roi[r * ROI_COLS:(r + 1) * ROI_COLS]
        lines.append("".join(RAMP[min(len(RAMP) - 1, luma(p) * len(RAMP) // 126)] for p in row))
    return lines


def draw_box(mb):
    """Draw the ROI box on the OSD from the host (for --no-load / Modbus-only builds)."""
    top, bot = ROW_LUT[ROI_R0], ROW_LUT[ROI_R1]
    left, right = COL_LUT[ROI_C0], COL_LUT[ROI_C1]

    def go(row, col):
        mb.write_single(REG_OSD_ADDR, row * OSD_COLS + col)

    def put(code):
        mb.write_single(REG_OSD_DATA, code)

    go(top, left); put(BX_TL)
    for _ in range(left + 1, right):
        put(BX_H)
    put(BX_TR)
    go(bot, left); put(BX_BL)
    for _ in range(left + 1, right):
        put(BX_H)
    put(BX_BR)
    for r in range(top + 1, bot):
        go(r, left); put(BX_V)
        go(r, right); put(BX_V)


def load_dataset(path):
    """Read an existing JSONL dataset into a list of records (empty if absent)."""
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def rewrite_dataset(path, records):
    with open(path, "w") as f:
        for rec in records:
            f.write(json.dumps(rec) + "\n")


def main():
    ap = argparse.ArgumentParser(description="Collect labelled ROI face/no-face samples")
    ap.add_argument("-p", "--port", required=True, help="serial port (e.g. /dev/ttyGowin)")
    ap.add_argument("-b", "--baud", type=int, default=DEFAULT_BAUD)
    ap.add_argument("-s", "--slave", type=int, default=DEFAULT_SLAVE)
    ap.add_argument("-o", "--out", default=DEFAULT_OUT, help="JSONL dataset (appended/resumed)")
    ap.add_argument("--bin", default=DEFAULT_BIN, help="roi_collect overlay .bin")
    ap.add_argument("--no-load", action="store_true",
                    help="don't upload the overlay (assume the box is already on screen)")
    ap.add_argument("--draw-box", action="store_true",
                    help="draw the ROI box from the host (use with --no-load / Modbus-only)")
    args = ap.parse_args()

    mb = ModbusRTU(args.port, baud=args.baud, slave=args.slave, timeout=1.0)
    try:
        if not args.no_load:
            if not os.path.exists(args.bin):
                sys.exit(f"error: {args.bin} not found -- build it with:\n"
                         f"  cmake --build build --target serv_firmware\n"
                         f"(or pass --no-load --draw-box if you can't run a SERV overlay)")
            with open(args.bin, "rb") as f:
                n = mb.serv_boot_load(f.read())
            print(f"loaded roi_collect overlay ({n} words); box drawn on the LCD")
            time.sleep(0.3)
        if args.draw_box:
            draw_box(mb)
            print("drew ROI box from host")

        records = load_dataset(args.out)
        n_face = sum(1 for r in records if r["label"] == 1)
        n_none = sum(1 for r in records if r["label"] == 0)
        print(f"dataset {args.out}: {len(records)} samples ({n_face} face, {n_none} no-face)")
        print("\nAlign your face to the box on the LCD, then label each capture.")
        print("keys:  f = face   n = no-face   <enter> = recapture   u = undo last   q = quit\n")

        while True:
            roi = grab_roi(mb)
            skin = sum(1 for p in roi if is_skin(p))
            print("\n".join("    " + ln for ln in preview(roi)))
            print(f"  skin cells: {skin}/{ROI_CELLS}   (have {n_face} face / {n_none} no-face)")
            try:
                key = input("  label [f/n/<enter>/u/q]: ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                print()
                break

            if key == "q":
                break
            if key == "u":
                if records:
                    dropped = records.pop()
                    if dropped["label"] == 1:
                        n_face -= 1
                    else:
                        n_none -= 1
                    rewrite_dataset(args.out, records)
                    print(f"  undid last sample (label={dropped['label']})")
                else:
                    print("  nothing to undo")
                continue
            if key in ("f", "n"):
                label = 1 if key == "f" else 0
                rec = {"label": label, "roi565": roi}
                records.append(rec)
                with open(args.out, "a") as f:
                    f.write(json.dumps(rec) + "\n")
                if label == 1:
                    n_face += 1
                else:
                    n_none += 1
                print(f"  saved ({'face' if label else 'no-face'}); total {len(records)}")
            # any other key (incl. empty) -> recapture

        print(f"\ndone: {len(records)} samples in {args.out} "
              f"({n_face} face, {n_none} no-face)")
    finally:
        mb.close()


if __name__ == "__main__":
    main()
