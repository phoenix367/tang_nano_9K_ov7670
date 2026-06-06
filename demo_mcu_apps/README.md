# demo_mcu_apps

Example firmware **overlays** for the SERV soft core. On a SERV-enabled bitstream
(`serv_mcu.enable`, see [`../doc/serv.md`](../doc/serv.md)) the MCU boots a
bootloader that loads an overlay from the host at runtime and jumps to it — so
these run without re-synthesizing the FPGA.

Each overlay is RISC-V (RV32I) assembly linked at the overlay base (`0x400`, from `platform.json`)
(`../serv_soc/overlay.ld`). It runs on SERV as a Wishbone master: it reaches the
device registers through the `0x40000000` window (low 16 bits = register number).
SERV presents word-aligned accesses + byte-enables; `serv_wb_cdc` resolves the
exact register (`word_addr + lane_offset(sel)`) and the value, so any register —
word-aligned or not — is reachable with normal loads/stores.

CMake builds each overlay to `build/serv_fw/<name>.bin` (part of the
`serv_firmware` target). Upload one with the CLI
[`scripts/serv_upload.py`](../scripts/serv_upload.py) (e.g.
`scripts/serv_upload.py -p /dev/ttyGowin <name>`; `--list` shows what's built), the
web app's **Firmware** tab, or `modbus_client.serv_boot_load(open(path,'rb').read())`.
An overlay that **jumps
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
| [`roi_presence`](roi_presence/roi_presence.c) | (C) **Fixed-ROI face-presence gate**: draws a fixed ROI box on the OSD (align your face to it) and classifies just that region as face-present/empty each frame (baseline: skin coverage in the ROI; classifier is swappable for a trained lightweight model e.g. a Tsetlin Machine). Lights a "FACE" label + reports count|present on 0xE0. |
| [`roi_collect`](roi_collect/roi_collect.c) | (C) **Sample-collection alignment guide**: draws the *same* fixed ROI box as `roi_presence` on the LCD, then **parks** (no bus traffic) so the host can drive the grab port. Pair with [`collect_samples.py`](roi_collect/collect_samples.py): it arms a frame grab, reads the 22×14 ROI grid out of ch1 PSRAM, shows an ASCII luma preview, and you label each capture **f**ace / **n**o-face into a resumable JSONL dataset — labelled training data for a real classifier, since the skin rule is unreliable for this camera. |
| [`roi_tm`](roi_tm/roi_tm.c) | (C) **Fixed-ROI face presence via a Tsetlin Machine** — the trained deployment of the `roi_collect` data. Featurizes the ROI with an 8-neighbour **Local Binary Pattern** (2×2-downsampled 11×7 grid → 360 boolean LBP bits) and classifies with a TM whose clause masks are baked in from `tm_model.h`; featurization + inference are pure integer-compare + bitwise AND/vote (no multiply, divide, or float — libgcc-free). Train + export the model offline with [`train_tm.py`](roi_tm/train_tm.py); see [`roi_tm/README.md`](roi_tm/README.md) for the collect → train → deploy loop. Lights a "FACE" label; heartbeat 0xE0 = `bit7 present | (vote+64)`. |
| [`lbph_bench`](lbph_bench/lbph_bench.c) | (C) **LBPH feature benchmark** — measures how fast the soft core computes an LBPH (Local Binary Patterns Histogram) feature, the core of OpenCV's face recogniser. On a 32×32 downscaled face (4×4 cells): **~7–8 features/sec (~133 ms each)** — ~42 ms downscaled PSRAM read + ~91 ms LBP+histogram. Shows on-MCU LBPH *recognition* is viable (~5–7/s), unlike Viola-Jones *detection*. |
| [`gpio_blink`](gpio_blink/gpio_blink.c) | (C) Drives the **4 `wb_gpio` pins** (Tang Nano 9K 48/49/76/30) from the MCU: sets them to outputs (`GPIO_DIR`) and walks a 4-bit counter on `GPIO_DATA`, mirroring the value to the heartbeat. The host can watch the pins change over Modbus (`gpio_read`) — proving both masters share the GPIO slave. Needs a bitstream with `wb_gpio` (rebuild + flash). |
| [`calc`](calc/calc.c) | (C + libgcc) Host-driven **floating-point calculator**: the host sends `op, a, b` over the mailbox, the MCU computes in IEEE-754 single precision (`+ - * /`, `sqrt`, `1/x`, integer `pow`) and returns the result on the OSD + as raw bytes. SERV has no FPU → **libgcc soft-float**, so this needs the 16 KB MCU RAM build. Demonstrates host↔MCU comms. Drive it from a console with [`demo_mcu_apps/calc/calc_host_client.py`](../demo_mcu_apps/calc/calc_host_client.py). |

## [`common/`](common) — shared C runtime

C overlays share one module:

- [`common/crt0.S`](common/crt0.S) — startup: sets `sp` to the top of the 16 KB RAM
  (`0x4000`), zeroes `.bss`, calls `main()`, and returns to the bootloader
  (`0x0000`) so the overlay is re-loadable without a reset.
- [`common/serv_io.h`](common/serv_io.h) — the device registers (EXT-window
  `volatile` pointers) plus `static inline` helpers (`osd_*`, `psram_*`, `delay`).
  A `uint8`/`uint16` store emits the `sb`/`sh` the byte-lane CDC expects.

Both link at the overlay base with [`../serv_soc/overlay_c.ld`](../serv_soc/overlay_c.ld)
(adds `.rodata` and the `__bss_*` symbols).

## Adding an app

**In C (preferred):** add `demo_mcu_apps/<name>/<name>.c` with a `void main(void)`,
`#include "serv_io.h"`, and use the helpers. Add an overlay build to the
`serv_firmware` block in `CMakeLists.txt` mirroring `c_hello` (reuses `SERV_C_BUILD`
= crt0 + flags + `overlay_c.ld`), producing `build/serv_fw/<name>.bin`. Upload it
via the Firmware tab / `serv_boot_load`.

**In assembly:** write `demo_mcu_apps/<name>/<name>.S` (link-at-overlay-base; set `sp` in
`_start` only if you need a stack — the asm OSD demo doesn't) and add a build
mirroring `osd_hello` (uses `overlay.ld`).
