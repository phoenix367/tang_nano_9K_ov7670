# SERV soft-core bring-up

A standalone proof that a minimal RISC-V soft core fits and runs on this board's
27 MHz domain, as the first step toward optionally moving the control plane
(Modbus/SCCB/OSD) from hardwired FSMs into firmware on a CPU sitting on the
[Wishbone bus](modbus_server.md).

[SERV](https://github.com/olofk/serv) — the world's smallest RISC-V CPU
(bit-serial RV32I) — is vendored as the `serv/` git submodule. This bring-up
instantiates SERV's own reference SoC `servant` (CPU + RAM + timer + 1-bit GPIO)
running a `blinky` firmware out of BSRAM, and wires the GPIO to an on-board LED.

**It is a completely separate Gowin project** (`serv_soc/serv_blink.gprj`, its own
isolated `serv_soc/impl/`). The camera design (`camera_ov7670.gprj`, `src/`) and
all simulation tests are untouched.

## What it proves

- SERV synthesizes on the GW1NR-9C and closes timing at 27 MHz. Measured:
  **442 logic cells (6%), 300 CLS (7%), 5 BSRAM, Fmax 71.3 MHz (×2.64), 0 setup /
  0 hold violations.** A full CPU SoC in well under 10% of the fabric.
- The RISC-V firmware toolchain works end-to-end (compile → link → hex).
- Gowin preloads BSRAM from a `$readmemh` hex (the firmware image).

## Layout

- `serv/` — the SERV submodule (clone with `--recurse-submodules`).
- `serv_soc/serv_blink.v.in` — the standalone top: a power-on reset, a `servant`
  instance, and `assign led = ~q` (LEDs are active-low). CMake generates
  `serv_soc/serv_blink.v` from it with the firmware hex path baked in.
- `serv_soc/serv_blink.{cst,sdc}` — pin (clk 52, rst_n 4, LED 10) and 27 MHz
  clock constraints.
- `serv_soc/serv_blink.gprj` — the Gowin project (the ~25 SERV `.v` files +
  the top + constraints).
- `serv_soc/bin2hex.py` — bin → 32-bit-word hex for `servant_ram` (same format as
  SERV's `sw/makehex.py`, but writes to an explicit output path).

## Memory map

| Region | Address | Backed by |
| ------ | ------- | --------- |
| Program / data RAM | `0x0000_0000`+ | `servant_ram` (BSRAM, preloaded) |
| LED GPIO (1 bit) | `0x4000_0000` | `servant_gpio` → `led` pin |

The firmware (`serv/sw/blinky.S`) stores an alternating 0/1 byte to the GPIO with
a busy-loop delay, so the LED blinks. `-D SERV_BLINK_DELAY` (default `0x40000`,
~1.5 s/toggle at 27 MHz) tunes the rate.

## Build & run

Requires a RISC-V ELF toolchain (`riscv64-unknown-elf-gcc`; pass `-D RISCV_PATH=`
if it isn't on `PATH`). The `hw_serv_*` targets are skipped if it (or the `serv/`
submodule) is absent.

```sh
cmake -S . -B build -D IVerilog_PATH=/usr/bin -D Gowin_PATH=/opt/gowin/IDE \
      -D RISCV_PATH=/path/to/riscv/bin
cmake --build build --target serv_blink_firmware   # build blinky.hex
cmake --build build --target hw_serv_all      # synth + PnR + bitstream
cmake --build build --target hw_serv_program  # load to SRAM (volatile) -> LED blinks
```

The bitstream lands at `serv_soc/impl/pnr/serv_blink.fs`; the timing report is
`serv_soc/impl/pnr/serv_blink_tr_content.html` (parse with the `hw-check` skill's
`parse_timing.py --report ...`).

## Phase 2 — SERV as a 2nd Wishbone master in the camera design

Behind the `SERV_CONTROL` build flag, SERV joins the camera's 27 MHz Wishbone bus
as a **second master** alongside the Modbus host path, and runs firmware that
increments a **heartbeat register (0x00E0)**. The host reads that register over
Modbus to confirm the CPU is alive on the bus — while normal host control keeps
working. This is host-verifiable proof that a soft CPU can drive the real `wb_*`
peripherals on the live bus.

How it fits together:
- `src/serv/serv_cpu.v` — `servile` + the 32-bit `servant_ram` (firmware) +
  `serv_rf_ram`, exposing the Wishbone "ext" master bus.
- **SERV runs on its own 30 MHz clock domain** (`mcu_rpll`, `src/gowin_rpll/mcu_rpll.v`),
  decoupled from the 27 MHz camera bus. Its master crosses into the bus domain
  through `src/serv/serv_wb_cdc.v` — an async 4-phase handshake CDC (2-FF
  synchronizers on the req/done qualifiers; the held-stable addr/data are sampled
  gated by the synced qualifier). The mcu↔sys crossing is declared async in the
  SDC (`set_clock_groups`), so it isn't timed. Putting SERV on its own clock keeps
  it off the 27 MHz critical path (base Fmax ~50 MHz vs ~41 when SERV shared
  sys_clk).
- `src/modbus/be_arbiter.v` — 2-master arbiter (host priority, owner-locked for
  multi-cycle accesses) muxing the Modbus master and the CDC's bus-side port onto
  `modbus_cam_backend`'s `be_*` port. SERV's byte-addressed ext bus maps to a
  be-style master: `be_addr = adr[15:0]`, word store → data in `dat[15:0]`.
- `wb_sysregs` gains the heartbeat register at 0x00E0 (host-RW scratch, reads 0
  on a default build); `wb_interconnect` routes 0x00E0 to it. Both are
  unconditional and covered by the unit + formal tests.

### Bootloader (load an overlay from the host at runtime)

SERV's baked-in firmware is a **bootloader** (`serv_soc/bootloader.S`), not a
fixed program: it receives an **overlay firmware from the host over the bus**,
copies it into RAM, and jumps to it — so the MCU program can change without
re-synthesizing. Since SERV has no host link of its own, the host writes the
overlay through a **mailbox** in `wb_sysregs` that the bootloader polls as a bus
master:

| Reg | Name | Host | SERV |
| --- | ---- | ---- | ---- |
| `0xE4` | `BOOT_LEN`    | write overlay length (16-bit words) → sets `start` | read length |
| `0xE8` | `BOOT_DATA`   | write next overlay word → sets `pending` | read → clears `pending` |
| `0xEC` | `BOOT_STATUS` | poll: bit1=`start`, bit0=`pending` | same |

(Word-aligned register numbers so SERV's RV32I `lw`/`sw` are aligned.) Memory
map within the 16 KB RAM: bootloader at `0x0000`, overlay loaded/run at `0x400`
(overlays are linked there — `serv_soc/overlay.ld`).

Host side: `modbus_client.serv_boot_load(blob)` packs the overlay `.bin` into
little-endian words and streams them with the per-word `pending` handshake; the
bootloader jumps once it has received `BOOT_LEN` words. The bootloader **re-arms**
(the `start` flag clears when SERV reads `BOOT_LEN`), so an overlay that jumps back
to `0x0000` when done returns control to the bootloader and the host can load
another overlay **without resetting the device**.

#### Host-commanded MCU reset (load any firmware)

An overlay that **parks** (infinite loop) never returns to the bootloader, so the
re-arm path alone can't recover it. For that, the host has a **hardware reset** of
the soft core: a write of bit0 to **`0x00E2`** (`wb_sysregs`) pulses `mcu_reset`.
That pulse is on `sys_clk`; it crosses into SERV's `mcu_clk` domain through a
`CDC_Pulse_Synchronizer_2phase` (in `camera_control.v`) and **re-arms the CPU's
power-on reset hold** — so the core restarts from `0x0000` into the bootloader
from *any* state. `modbus_client.serv_mcu_reset()` issues it; `serv_boot_load()`
does it automatically before every upload (`reset_first=True` by default), which
makes "load any firmware" work unconditionally — even over a parked overlay. The
webapp's **Firmware** tab also exposes a standalone **Reset MCU** button.
(`serv_boot_load(..., reset_first=False)` skips it to exercise the bootloader's
own re-arm.)

`serv_soc/heartbeat.S` is built as a minimal **demo overlay**
(`build/serv_fw/overlay_heartbeat.bin`, linked at the overlay base) — uploaded at runtime,
not baked in. It writes the incrementing counter to `0x400000E0` (reg 0xE0).

Richer demos live in [`demo_mcu_apps/`](../demo_mcu_apps):
[`osd_hello`](../demo_mcu_apps/osd_hello/osd_hello.S) writes **"Hello from
MCU!!!"** onto the OSD after boot, and
[`psram_test`](../demo_mcu_apps/psram_test/psram_test.c) writes a pseudo-random
sequence into channel-1 PSRAM (via the `wb_grab` write port), reads it back,
compares, and prints **"PSRAM test: PASS/FAIL"** with live progress bars; and
[`c_hello`](../demo_mcu_apps/c_hello/c_hello.c) is the OSD greeting in **C**; and
[`motion`](../demo_mcu_apps/motion/motion.S) is a background-subtraction **motion
detector** (assembly) — it grabs a frame, saves a sampled background model in
*free* PSRAM, then loops grabbing + comparing and reports **"Movement: YES/NO"**
on the OSD, periodically refreshing the background. It also measures its own
**processing FPS** (monitor-loop iterations between 1 Hz uptime ticks — no RTC
needed) and shows **"FPS: NN"**, publishing it on heartbeat 0xE0 (low byte; note
0xE0 only round-trips its low byte). A C twin
[`motion_c`](../demo_mcu_apps/motion_c/motion_c.c) is functionally identical and
runs at the **same FPS** — the loop is grab-bound (each frame waits on the
camera), so hand-asm vs compiler overhead is hidden. The C demos share
[`demo_mcu_apps/common/`](../demo_mcu_apps/common) (a `crt0.S` startup + a
`serv_io.h` register/helper header) and link with the C-aware
`serv_soc/overlay_c.ld` — proving the C toolchain path, not just hand asm.
[`calc`](../demo_mcu_apps/calc/calc.c) is a host-driven **floating-point
calculator**: the host streams `op, a, b` over the bootloader mailbox, the MCU
computes in IEEE-754 single precision (`+ - * /`, `sqrt`, `1/x`, integer `pow`)
and returns the result on the OSD + as raw bytes the host reads back. SERV has no
FPU, so the math is **libgcc soft-float** (`-lgcc`) — ~6 KB, which is why the MCU
RAM was grown from 8 KB to **16 KB** (`serv_cpu memsize`; ~24/26 BSRAM). A
standalone console front-end, [`demo_mcu_apps/calc/calc_host_client.py`](../demo_mcu_apps/calc/calc_host_client.py), uploads the
overlay and gives a REPL (`calc> 2 ^ 10` → `= 1024`). Finally
[`roi_tm`](../demo_mcu_apps/roi_tm/) classifies face presence in a *fixed* ROI with a
Tsetlin Machine (bitwise inference on LBP + colour features) and draws a **bounding
box** on the OSD — true face *detection* is far too heavy for the bit-serial core,
but a fixed-ROI presence *gate* fits (the large PSRAM solves the memory problem, not
the compute one). All demos
have hardware tests that upload them and check the result. The OSD/grab control registers (0xF3..0xFD) aren't word-aligned, but
`serv_wb_cdc` resolves the register from SERV's word address + byte-enables
(`word_addr + lane_offset(sel)`) and extracts/places the value at that lane, so
SERV can drive **any** register with ordinary RV32I loads/stores.
- `src/build_config.vh` (generated) carries the `SERV_CONTROL` define + firmware
  path; `camera_ov7670.gprj` is generated from `camera_ov7670.gprj.in` with the
  SERV files' `enable` tied to the flag, so a default build excludes them
  entirely (no extra logic, no phantom clocks).

Whether the SERV co-master is in the camera build is controlled by
**`platform.json`'s `serv_mcu.enable`** (default `true`) — the single source of
truth, like the rest of the platform config. It needs the RISC-V toolchain + the
`serv/` submodule; if those are missing CMake **warns and builds without SERV**
(so a toolchain-less checkout still works) rather than failing.

```sh
cmake -S . -B build -D IVerilog_PATH=/usr/bin -D Gowin_PATH=/opt/gowin/IDE \
      -D RISCV_PATH=/path/to/riscv/bin       # serv_mcu.enable=true -> SERV included
cmake --build build --target hw_all          # camera bitstream with SERV co-master
cmake --build build --target hw_program
# then, on hardware:
OV7670_PORT=/dev/ttyGowin OV7670_SERV=1 .venv/bin/python -m pytest \
    webapp/tests/test_device_hw.py::test_serv_bootloader_loads_overlay -v
```

To build the plain Modbus-only camera, set `"serv_mcu": { "enable": false }` in
`platform.json` and reconfigure.

Measured: the SERV build fits at ~63% logic / 87% CLS / 77% BSRAM; `mcu_clk`
closes 30 MHz (×2.09) and the mcu↔sys crossings are false-pathed (`setup<0 = 0`);
with SERV on its own clock the 27 MHz base Fmax sits ~50 MHz (vs ~41 when SERV
shared sys_clk). With `serv_mcu.enable=false` the camera is unchanged on real
paths.
