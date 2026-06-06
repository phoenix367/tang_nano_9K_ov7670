#!/usr/bin/env python3
"""Upload an overlay firmware to the Tang Nano 9K's SERV soft core.

Streams a `.bin` overlay (linked at the overlay base) into the SERV bootloader's
mailbox and hands it control -- the same thing the web app's Firmware tab does, on
the command line. Requires a SERV-enabled bitstream on the board
(platform.json serv_mcu.enable=true; see doc/serv.md). Host-side only: no reflash.

Examples:
    # by overlay name (resolves to build/serv_fw/roi_tm.bin):
    scripts/serv_upload.py -p /dev/ttyGowin roi_tm
    # by explicit path:
    scripts/serv_upload.py -p /dev/ttyGowin build/serv_fw/motion.bin
    # upload then watch the heartbeat (0xE0) for a few seconds:
    scripts/serv_upload.py -p /dev/ttyGowin roi_tm --verify
    # list what's built, or just reset the MCU back into the bootloader:
    scripts/serv_upload.py --list
    scripts/serv_upload.py -p /dev/ttyGowin --reset-only

Build overlays first with:  cmake --build build --target serv_firmware
"""
import argparse
import glob
import os
import sys
import time

# reuse the pyserial-only Modbus client from scripts/ (no pymodbus dependency)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from modbus_test import DEFAULT_BAUD, DEFAULT_SLAVE, ModbusRTU  # noqa: E402

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FW_DIR = os.path.join(_REPO, "build", "serv_fw")

# SERV bootloader mailbox + control registers (see doc/serv.md, doc/modbus_server.md)
REG_HEARTBEAT, REG_MCU_RESET = 0x00E0, 0x00E2
REG_BOOT_LEN, REG_BOOT_DATA, REG_BOOT_STATUS = 0x00E4, 0x00E8, 0x00EC


def resolve(firmware):
    """Accept a path or a bare overlay name (-> build/serv_fw/<name>.bin)."""
    if os.path.isfile(firmware):
        return firmware
    cand = os.path.join(FW_DIR, firmware if firmware.endswith(".bin") else firmware + ".bin")
    if os.path.isfile(cand):
        return cand
    sys.exit(f"error: firmware {firmware!r} not found (also tried {cand}).\n"
             f"Build overlays with: cmake --build build --target serv_firmware\n"
             f"Or list them with: {os.path.basename(sys.argv[0])} --list")


def list_overlays():
    bins = sorted(glob.glob(os.path.join(FW_DIR, "*.bin")))
    if not bins:
        print(f"no overlays in {FW_DIR} -- build them: cmake --build build --target serv_firmware")
        return
    print(f"overlays in {os.path.relpath(FW_DIR)}:")
    for b in bins:
        print(f"  {os.path.basename(b)[:-4]:16s} {os.path.getsize(b):6d} B")


def boot_load(mb, blob, reset_first=True, poll_timeout=2.0):
    """Reset into the bootloader (optional) and stream the overlay through the mailbox.

    Returns the number of 16-bit words sent. The bootloader copies them into RAM and
    jumps to the overlay once it has received all of them.
    """
    data = bytes(blob) + (b"\x00" if len(blob) % 2 else b"")
    words = [data[i] | (data[i + 1] << 8) for i in range(0, len(data), 2)]
    if reset_first:
        mb.write_single(REG_MCU_RESET, 1)        # -> bootloader, waiting for an overlay
        time.sleep(0.01)
    mb.write_single(REG_BOOT_LEN, len(words))     # length -> start the upload
    for w in words:
        deadline = time.monotonic() + poll_timeout
        while mb.read_holding(REG_BOOT_STATUS, 1)[0] & 0x01:   # wait for the slot to drain
            if time.monotonic() > deadline:
                raise TimeoutError(
                    "bootloader did not drain the mailbox -- is this a SERV build, and is "
                    "the MCU in the bootloader? (try without --no-reset)")
        mb.write_single(REG_BOOT_DATA, w)
    return len(words)


def main():
    ap = argparse.ArgumentParser(description="Upload an overlay firmware to the SERV soft core",
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    ap.add_argument("firmware", nargs="?", help="overlay name (e.g. roi_tm) or path to a .bin")
    ap.add_argument("-p", "--port", help="serial port (e.g. /dev/ttyGowin)")
    ap.add_argument("-b", "--baud", type=int, default=DEFAULT_BAUD)
    ap.add_argument("-s", "--slave", type=int, default=DEFAULT_SLAVE)
    ap.add_argument("--no-reset", action="store_true",
                    help="don't reset the MCU first (only works if it returned to the bootloader)")
    ap.add_argument("--reset-only", action="store_true",
                    help="just reset the MCU into the bootloader (no upload)")
    ap.add_argument("--verify", action="store_true",
                    help="after upload, print the heartbeat (0xE0) for ~3 s")
    ap.add_argument("--list", action="store_true", help="list built overlays and exit")
    args = ap.parse_args()

    if args.list:
        list_overlays()
        return
    if not args.port:
        ap.error("-p/--port is required (or use --list)")
    if not args.reset_only and not args.firmware:
        ap.error("firmware is required (a name or .bin path), or use --reset-only / --list")

    mb = ModbusRTU(args.port, baud=args.baud, slave=args.slave, timeout=1.0)
    try:
        if args.reset_only:
            mb.write_single(REG_MCU_RESET, 1)
            print("MCU reset into the bootloader")
            return
        path = resolve(args.firmware)
        blob = open(path, "rb").read()
        t = time.monotonic()
        n = boot_load(mb, blob, reset_first=not args.no_reset)
        print(f"uploaded {os.path.relpath(path)} ({len(blob)} B, {n} words) "
              f"in {time.monotonic()-t:.1f}s")
        if args.verify:
            time.sleep(0.5)
            print("heartbeat (0xE0) for ~3 s:")
            for _ in range(8):
                hb = mb.read_holding(REG_HEARTBEAT, 1)[0] & 0xFF
                print(f"  0x{hb:02X}")
                time.sleep(0.4)
    finally:
        mb.close()


if __name__ == "__main__":
    main()
