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
cmake --build build --target serv_firmware   # build blinky.hex
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
- `src/modbus/be_arbiter.v` — 2-master arbiter (host priority, owner-locked for
  multi-cycle accesses) muxing the Modbus master and SERV onto
  `modbus_cam_backend`'s `be_*` port. SERV's byte-addressed ext bus maps to a
  be-style master: `be_addr = adr[15:0]`, word store → data in `dat[15:0]`.
- `wb_sysregs` gains the heartbeat register at 0x00E0 (host-RW scratch, reads 0
  on a default build); `wb_interconnect` routes 0x00E0 to it. Both are
  unconditional and covered by the unit + formal tests.
- `serv_soc/heartbeat.S` — the firmware (writes an incrementing counter to
  `0x400000E0`, whose low 16 bits select register 0xE0).
- `src/build_config.vh` (generated) carries the `SERV_CONTROL` define + firmware
  path; `camera_ov7670.gprj` is generated from `camera_ov7670.gprj.in` with the
  SERV files' `enable` tied to the flag, so a default build excludes them
  entirely (no extra logic, no phantom clocks).

Build + verify the SERV variant:

```sh
cmake -S . -B build -D IVerilog_PATH=/usr/bin -D Gowin_PATH=/opt/gowin/IDE \
      -D RISCV_PATH=/path/to/riscv/bin -D SERV_CONTROL=ON
cmake --build build --target hw_all          # camera bitstream with SERV co-master
cmake --build build --target hw_program
# then, on hardware:
OV7670_PORT=/dev/ttyGowin OV7670_SERV=1 .venv/bin/python -m pytest \
    webapp/tests/test_device_hw.py::test_serv_heartbeat_advances -v
```

Measured: the SERV variant fits at ~63% logic / 87% CLS / 77% BSRAM and closes
timing at 27 MHz (base Fmax ×1.51, all clocks OK); the default build is unchanged
on real paths (`setup<0 = 0`). Reconfigure with `-D SERV_CONTROL=OFF` (the
default) for the normal Modbus-only camera.

## Next steps (not yet implemented)

Full firmware Modbus stack (SERV as the host *interface*, not just a co-master) —
SERV would parse RTU frames over the UART and bridge to `wb_*`, replacing
`modbus_rtu_slave`. See [modbus_server.md](modbus_server.md).
