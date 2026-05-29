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
(`sim/run_simulator.sh.in` on POSIX, `sim/run_simulator.bat.in` on
Windows). The list of tests lives in `TESTS_LIST` in
`sim/CMakeLists.txt`.

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

Adding a new testbench: drop the `.sv` into `sim/`, then append its
base name to `TESTS_LIST` in `sim/CMakeLists.txt`. The testbench must
include the generated `test_config.sv` (it inherits the log level and
optional `ENABLE_DUMPVARS` macros) and should use `svlogger.sv`
rather than raw `$display`.

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
FT2232H (`0403:6010`) and exposes it as `/dev/ttyUSB0` / `1`. The
programmer can't open the device while that happens, and you'll see:

```
Error: Cable failed to open via the channel.
```

The vendor rules at `<Gowin>/Programmer/bin/50-programmer_usb.rules`
only cover the single-channel FT232H (`0403:6014`). Install a
companion rule for the dual-channel variant:

```sh
sudo tee /etc/udev/rules.d/51-gowin-ft2232h.rules <<'RULES'
ACTION=="add", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="0666"
ACTION=="add", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", \
    PROGRAM="/bin/sh -c 'echo -n %k > /sys/bus/usb/drivers/ftdi_sio/unbind 2>/dev/null; true'"
RULES

sudo udevadm control --reload-rules
# Detach the currently-bound device (or just replug):
sudo sh -c 'for i in /sys/bus/usb/drivers/ftdi_sio/1-*; do \
    echo -n "$(basename "$i")" > /sys/bus/usb/drivers/ftdi_sio/unbind; done'
```

After this, `/dev/ttyUSB*` should disappear for the cable and
`make hw_program` should program the SRAM in ~3 seconds.

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
