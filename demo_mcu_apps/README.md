# demo_mcu_apps

Example firmware **overlays** for the SERV soft core. On a SERV-enabled bitstream
(`serv_mcu.enable`, see [`../doc/serv.md`](../doc/serv.md)) the MCU boots a
bootloader that loads an overlay from the host at runtime and jumps to it — so
these run without re-synthesizing the FPGA.

Each overlay is RISC-V (RV32I) assembly linked at `0x1000`
(`../serv_soc/overlay.ld`). It runs on SERV as a Wishbone master: it reaches the
device registers through the `0x40000000` window (low 16 bits = register number).
SERV presents word-aligned accesses + byte-enables; `serv_wb_cdc` resolves the
exact register (`word_addr + lane_offset(sel)`) and the value, so any register —
word-aligned or not — is reachable with normal loads/stores.

CMake builds each overlay to `build/serv_fw/<name>.bin` (part of the
`serv_firmware` target). Upload one with the web app's **Firmware** tab or
`modbus_client.serv_boot_load(open(path,'rb').read())`. An overlay that **jumps
back to `0x0000`** when finished returns control to the bootloader, so the host
can load another via the bootloader's re-arm (`osd_hello` does this). An overlay
that **parks** (loops forever) can't re-arm — but `serv_boot_load` resets the MCU
into the bootloader before every upload (Modbus reg `0xE2`, or the **Reset MCU**
button), so the host can always load any firmware over any running overlay.

## Apps

| App | What it does |
| --- | ------------ |
| [`osd_hello`](osd_hello/osd_hello.S) | (assembly) After boot, writes **"Hello from MCU!!!"** centered on the OSD overlay (enable 0xFB, cursor 0xFC, chars 0xFD). |
| [`c_hello`](c_hello/c_hello.c) | (C) The `osd_hello` greeting in **C** — writes **"Hello from C!"** to the OSD. The smallest C overlay. |
| [`psram_test`](psram_test/psram_test.c) | (C) Writes a pseudo-random sequence into channel-1 PSRAM (write port 0xF3/0xF4-0xF7), reads it back, compares, and prints **"PSRAM test: PASS/FAIL"** on the OSD with live progress bars. |
| [`motion`](motion/motion.S) | (assembly) Background-subtraction **motion detector**: grabs a frame, saves a sampled background model in *free* PSRAM, then loops grabbing + comparing and reports **"Movement: YES/NO"** on the OSD, periodically refreshing the background. Also measures its own **processing FPS** (loop iterations per second, timed off the 1 Hz uptime counter — no RTC) and shows **"FPS: NN"**. Parks — reset the MCU to stop it. |
| [`motion_c`](motion_c/motion_c.c) | (C) The same motion detector in C, as an asm-vs-C comparison. Runs at the **same ~17 FPS** as the asm version — the loop is grab-bound (each frame waits on the camera), so compiler overhead is hidden. Bigger binary (~1.2 KB vs ~0.8 KB), same speed. |

## [`common/`](common) — shared C runtime

C overlays share one module:

- [`common/crt0.S`](common/crt0.S) — startup: sets `sp` to the top of the 8 KB RAM
  (`0x2000`), zeroes `.bss`, calls `main()`, and returns to the bootloader
  (`0x0000`) so the overlay is re-loadable without a reset.
- [`common/serv_io.h`](common/serv_io.h) — the device registers (EXT-window
  `volatile` pointers) plus `static inline` helpers (`osd_*`, `psram_*`, `delay`).
  A `uint8`/`uint16` store emits the `sb`/`sh` the byte-lane CDC expects.

Both link at 0x1000 with [`../serv_soc/overlay_c.ld`](../serv_soc/overlay_c.ld)
(adds `.rodata` and the `__bss_*` symbols).

## Adding an app

**In C (preferred):** add `demo_mcu_apps/<name>/<name>.c` with a `void main(void)`,
`#include "serv_io.h"`, and use the helpers. Add an overlay build to the
`serv_firmware` block in `CMakeLists.txt` mirroring `c_hello` (reuses `SERV_C_BUILD`
= crt0 + flags + `overlay_c.ld`), producing `build/serv_fw/<name>.bin`. Upload it
via the Firmware tab / `serv_boot_load`.

**In assembly:** write `demo_mcu_apps/<name>/<name>.S` (link-at-0x1000; set `sp` in
`_start` only if you need a stack — the asm OSD demo doesn't) and add a build
mirroring `osd_hello` (uses `overlay.ld`).
