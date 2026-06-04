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

## Next steps (not yet implemented)

Wire SERV into the camera design as an alternative Wishbone master behind a build
flag — replacing the `modbus_rtu_slave` `be_*` master — with firmware that drives
the real `wb_*` peripherals (sysregs/OSD). See the bus description in
[modbus_server.md](modbus_server.md); the interconnect already has the right shape
for a CPU master.
