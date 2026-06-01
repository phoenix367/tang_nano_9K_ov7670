# Build, test, and program

This guide covers the three things you can do with this repo:

1. **Build the bitstream** for the Tang Nano 9K (synthesis +
   place-and-route + bitstream generation).
2. **Run the simulation testbenches** (Icarus Verilog through CTest).
3. **Program the board** (load the bitstream into FPGA SRAM or
   embedded flash).

Everything is driven from a single top-level `CMakeLists.txt` that
discovers the Gowin and Icarus toolchains at configure time and
exposes a small set of `make` targets.

## Prerequisites

| Component                       | Linux                                                   | Windows                                            |
| ------------------------------- | ------------------------------------------------------- | -------------------------------------------------- |
| Gowin EDA (IDE + Programmer)    | `Gowin_V1.9.12.x_linux` (or newer 1.9.9 Beta-4+)        | `Gowin_V1.9.9 Beta-4` or newer                     |
| Icarus Verilog 12-20220611+     | `apt install iverilog` (or distro equivalent)           | [installer](https://bleyer.org/icarus/)            |
| CMake 3.17 or newer             | `apt install cmake`                                     | bundled with most IDEs                             |
| Python 3 (for scaler scripts)   | `apt install python3`                                   | python.org installer                               |

The Gowin install is required even on Linux for simulation, because
CMake locates `simlib/gw1n/prim_tsim.v` and the `GowinSynthesis`
binary under the IDE install root.

Clone the repo with submodules — `FPGADesignElements` is a submodule
that supplies the CDC and pipeline primitives:

```sh
git clone --recurse-submodules https://github.com/phoenix367/tang_nano_9K_ov7670.git
cd tang_nano_9K_ov7670
```

## Configure the build

```sh
# Linux / macOS
cmake -S . -B build \
    -D IVerilog_PATH=/usr/bin \
    -D Gowin_PATH=/opt/Gowin_V1.9.12.02_SP2_linux/IDE

# Windows
cmake -S . -B build ^
    -D IVerilog_PATH=C:\iverilog\bin ^
    -D Gowin_PATH=C:\Gowin\Gowin_V1.9.9Beta-4
```

`Gowin_PATH` must point at the IDE directory (the one that contains
`bin/GowinSynthesis` and `simlib/gw1n/`). The Programmer is located
automatically as a sibling of that path.

Optional configure-time variables:

| Variable             | Default | Meaning                                                |
| -------------------- | ------- | ------------------------------------------------------ |
| `DUMP_SIM_VARIABLES` | `OFF`   | Emit `dump.vcd` per test for GtkWave                   |
| `SimLogLevel`        | `Info`  | One of `Fatal Error Info Debug None`; sets `SVL_VERBOSE_*` in `test_config.sv` |

## Platform configuration

The frame geometry is defined once in [`platform.json`](../platform.json)
at the repo root:

```json
{
  "input_frame_width": 640,
  "input_frame_height": 480,
  "screen_width": 480,
  "screen_height": 272,
  "emit_row_size": 640
}
```

At configure time CMake parses it and generates the SystemVerilog header
`src/platform_config.vh` (a set of `` `define `` macros) that
[`src/VGA_timing.v`](../src/VGA_timing.v) includes and feeds to
`VideoController` (input/screen size and `EMIT_ROW_SIZE`). `emit_row_size`
is the number of source columns read per row and fed to the horizontal
resizer — `640` downscales the whole row (full field of view); a smaller
value reads/crops fewer columns.

Editing `platform.json` re-triggers CMake (it is a configure dependency),
so just re-run the build:

```sh
cmake -S . -B build -D IVerilog_PATH=... -D Gowin_PATH=...   # regenerates the header
```

The generated `src/platform_config.vh` is committed and listed in the
`.gprj` so the Gowin GUI flow and a fresh checkout resolve the include
without a configure step; CMake overwrites it from the JSON on every
configure. Edit `platform.json`, not the generated header.

## Build the bitstream

The hardware targets shell out to Gowin's `gw_sh` Tcl console (no GUI
required). On Linux the wrapper at `scripts/gw_run.sh` sets the
`LD_LIBRARY_PATH` and `LD_PRELOAD` env that the IDE launcher needs.

```sh
cmake --build build --target hw_synth   # synthesis only          (~5  s)
cmake --build build --target hw_impl    # PnR + bitstream         (~30 s)
cmake --build build --target hw_all     # both, in sequence
```

Outputs land in `impl/` next to the `.gprj`:

- `impl/pnr/camera_ov7670.fs` — bitstream (the file you flash).
- `impl/pnr/camera_ov7670.rpt.html` — timing / resource report.
- `impl/pnr/camera_ov7670.pin.html` — final pin assignment.
- `impl/pnr/camera_ov7670.power.html` — power estimate.

If you'd rather use the GUI, open `camera_ov7670.gprj` in Gowin IDE
and use the **Process** panel. The `.gprj` is the authoritative source
list — any new top-level synthesizable RTL must be registered there.

## Run the simulation tests

CTest drives Icarus Verilog through per-test wrappers
(`sim/common/run_simulator.sh.in` on POSIX,
`sim/common/run_simulator.bat.in` on Windows). Tests are grouped into
`sim/unit/<dut>/` and `sim/integration/<topic>/` folders and
registered in `UNIT_TESTS` / `INTEGRATION_TESTS` in
`sim/CMakeLists.txt`. The full reference — layout, conventions, how
to add a new test, the NBA-race trap — lives in
[testing.md](testing.md).

```sh
cmake --build build              # builds every per-test binary
cd build && ctest                # runs all tests
ctest -R frame_buffer_test_init0_run -V   # one test, verbose
```

Per-test artifacts go under `build/sim/tests/<test_name>/`:

- `output.txt` — stdout / stderr from the simulator.
- `dump.vcd` — waveform dump (only when `DUMP_SIM_VARIABLES=ON`).

If you only want to build (not run) a specific test, use the
per-test `_BUILD` or `_SIM` custom targets, e.g.
`make frame_buffer_test_init0_BUILD`.

Adding a new testbench: see [testing.md](testing.md) — drop the `.sv`
under `sim/unit/<dut>/` or `sim/integration/<topic>/`, then append
its path (without `.sv`) to `UNIT_TESTS` or `INTEGRATION_TESTS` in
`sim/CMakeLists.txt`.

## Program the board

Programming uses `programmer_cli` (located under
`<Gowin>/Programmer/bin/`). The targets only get registered if CMake
found the binary at configure time.

```sh
cmake --build build --target hw_program        # SRAM (volatile, fast iteration)
cmake --build build --target hw_program_flash  # embFlash (survives power cycle)
```

Both pass `--device GW1NR-9C` and the bitstream produced by `hw_impl`.
The operation index is `2` (SRAM Program) and `6` (embFlash Erase,
Program, Verify) respectively — see `programmer_cli --help` for the
full list.

### Linux: FTDI kernel driver conflict

On Linux the kernel's `ftdi_sio` driver auto-binds to the Tang Nano's
FT2232H (`0403:6010`) and exposes both of its interfaces as
`/dev/ttyUSB0` and `/dev/ttyUSB1`. The Gowin Programmer can't open
the device while that happens, and you'll see:

```
Error: Cable failed to open via the channel.
```

The chip exposes two channels:

| `bInterfaceNumber` | Function       | Linux side                                     |
| ------------------ | -------------- | ---------------------------------------------- |
| `0`                | JTAG Debugger  | needs raw libftd2xx access — must NOT be on `ftdi_sio` |
| `1`                | UART (RX/TX)   | should stay on `ftdi_sio` so it appears as a `/dev/ttyUSB*` for `picocom`/`minicom`/etc. |

The vendor rules at `<Gowin>/Programmer/bin/50-programmer_usb.rules`
only cover the single-channel FT232H (`0403:6014`). This repo ships a
companion rule at [`udev/99-gowin-ft2232h.rules`](../udev/99-gowin-ft2232h.rules)
that makes the raw device node read/write (so the programmer can open the
cable), detaches `ftdi_sio` from interface 0 (JTAG), and exposes interface 1
as the `/dev/ttyGowin` UART. It is numbered 99 so it runs after the system's
`60-serial.rules` (which sets the `ID_USB_INTERFACE_NUM` the UART rule keys on).
Install it (and remove any earlier `51-` copy):

```sh
sudo rm -f /etc/udev/rules.d/51-gowin-ft2232h.rules
sudo install -m 644 udev/99-gowin-ft2232h.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

Then either replug the cable or trigger the rules manually:

```sh
# Detach interface 0 (JTAG) from ftdi_sio for the already-plugged cable.
# The interface number suffix (:1.0) is constant; the bus-port prefix
# (1-3 below) depends on which USB port you're using — adapt as needed:
sudo sh -c 'for i in /sys/bus/usb/drivers/ftdi_sio/*:1.0; do \
    [ -e "$i" ] && echo -n "$(basename "$i")" > /sys/bus/usb/drivers/ftdi_sio/unbind; done'

# Re-trigger udev so the SYMLINK+= and MODE for interface 1 apply now:
sudo udevadm trigger --action=add --attr-match=idVendor=0403 --attr-match=idProduct=6010
```

After this:

- `make hw_program` programs the SRAM in ~3 seconds.
- `/dev/ttyGowin` is a stable symlink to the FPGA's UART (kernel-side
  name `/dev/ttyUSB0` or `/dev/ttyUSB1` depending on enumeration
  order). Connect with `picocom -b 1000000 /dev/ttyGowin` (or any baud
  your design uses).

The rule sets the UART node `MODE=0666` (plus `TAG+="uaccess"`), so
`/dev/ttyGowin` is usable by any user without sudo and without `dialout`
membership. If `/dev/ttyGowin` doesn't appear after installing the rule,
replug the cable (or `sudo udevadm trigger`) so a fresh `add` event applies
the `SYMLINK`/`MODE`. If you prefer group-based access instead of `0666`,
drop the `MODE=0666` from the rule and add yourself to `dialout`
(`sudo usermod -aG dialout "$USER"`, then re-login).

### Wiring the UART into your design

The FT2232H's channel B TXD/RXD pins are routed to two FPGA balls on
the Tang Nano 9K (commonly **17 = UART_TX**, FPGA → host, and
**18 = UART_RX**, host → FPGA — check the
[Sipeed Tang Nano 9K schematic](https://dl.sipeed.com/shareURL/TANG/Nano%209K/2_Schematic)
for your board revision). `CameraControl_TOP` already exposes
`uart_tx` / `uart_rx` ports, constrained in
[`src/camera_ov7670.cst`](../src/camera_ov7670.cst):

```
IO_LOC "uart_tx" 17;
IO_PORT "uart_tx" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "uart_rx" 18;
IO_PORT "uart_rx" IO_TYPE=LVCMOS33 PULL_MODE=UP BANK_VCCIO=3.3;
```

Note `DRIVE` is an output-only attribute — leave it off the `uart_rx`
input or place-and-route rejects the constraint (`CT1108`).

`CameraControl_TOP` instantiates [`src/modbus/uart.sv`](../src/modbus/uart.sv) (1 Mbaud,
8-E-1) feeding a [`src/modbus/modbus_rtu_slave.sv`](../src/modbus/modbus_rtu_slave.sv)
**Modbus RTU slave** (slave id 7). The slave maps **1:1 to the live OV7670
registers** — the holding-register address is the camera register number
(`0x00`–`0xC9`) — so a Modbus master reads/writes the camera over SCCB in real
time. Point any RTU master at `/dev/ttyGowin` (1 Mbaud 8-E-1, slave id 7), or use
the bundled client [`scripts/modbus_test.py`](../scripts/modbus_test.py) (needs
`pyserial`):

```sh
scripts/modbus_test.py --port /dev/ttyGowin --reg-count 202 --read 0x0A 2   # PID/VER -> 76 73
scripts/modbus_test.py --port /dev/ttyGowin --reg-count 202 --write 0x55 0x60  # brightness
```

Full host-side reference — register map, status registers, LEDs, the web app,
and the CLI — is in [host_control.md](host_control.md).

## Make-target cheat-sheet

| Target              | What it does                                           |
| ------------------- | ------------------------------------------------------ |
| `hw_synth`          | Synthesis only (netlist + report)                      |
| `hw_impl`           | Place-and-route + bitstream                            |
| `hw_all`            | Synthesis + PnR + bitstream                            |
| `hw_program`        | Load bitstream into SRAM (volatile)                    |
| `hw_program_flash`  | Program embedded flash (persistent)                    |
| `ctest` (from build)| Run every simulation test                              |
| `<name>_BUILD`      | Compile a single testbench                             |
| `<name>_SIM`        | Compile + run a single testbench                       |
