# Testing guide

This document describes how the simulation testbenches are organized,
how to run them, and how to add a new one. For the build / hardware
flow, see [build.md](build.md). For the RTL the tests exercise, see
[architecture.md](architecture.md).

## Layout

Tests live under `sim/` in three folders that map directly onto how
the CMake build groups them:

```
sim/
├── common/                          shared infrastructure (no tests here)
│   ├── svlogger.sv                  the SVL_VERBOSE_* logger
│   ├── test_utils.sv                `TEST_PASS / `TEST_FAIL macros
│   ├── test_config.sv.in            CMake template — populated per build
│   ├── psram_model.sv               behavioural HyperRAM model
│   ├── i2c_slave_model.sv           OV7670 SCCB endpoint model
│   ├── run_simulator.sh.in          POSIX wrapper template
│   └── run_simulator.bat.in         Windows wrapper template
│
├── unit/                            one folder per DUT
│   ├── buffer_controller/
│   │   ├── read.sv                  read-pointer rotation
│   │   ├── write.sv                 write-pointer rotation
│   │   ├── read_write_1.sv          contention scenario 1
│   │   └── read_write_2.sv          contention scenario 2
│   ├── debug_pattern_generator/
│   │   └── version2.sv              DebugPatternGenerator2 colour bars
│   ├── download_row_cache/
│   │   └── prefetch.sv              ping-pong prefetch: multi-frame, both-banks-full, watchdog
│   ├── frame_downloader/
│   │   └── stream.sv                token+pixel stream over the cache: multi-frame, back-pressure, watchdog
│   ├── horizontal_resizer/
│   │   └── stream.sv                pillarbox border stream vs reference, under back-pressure
│   ├── lcd_controller/
│   │   └── timing.sv                VSYNC / HSYNC counts for a 23x17 frame
│   ├── position_scaler_vert/
│   │   └── scale_272_480.sv         LUT vs the generator's scaling algorithm
│   ├── position_scaler_horz/
│   │   └── characterization.sv      write_enable stream vs a reference model
│   ├── device_delay/
│   │   └── countdown.sv             cycle count to delay_done + syn_rst restart
│   ├── arbiter/
│   │   └── round_robin.sv           grant / hold / mask / round-robin (width 2)
│   └── cam_pixel_processor/
│       └── frame_sequence.sv        start / per-row / end command framing
│
└── integration/                     cross-module tests
    ├── frame_roundtrip/
    │   └── read_23x17.sv            PSRAM read → LCD queue round-trip
    └── pillarbox/
        └── borders{,_full,_vmap}.sv vertical resize + pillarbox pixel mapping
```

`unit/<dut>/<scenario>.sv` exercises a single RTL module in isolation
(its dependencies are usually models from `common/` or trivial
stubs). `integration/<topic>/<scenario>.sv` instantiates multiple
modules together — often `VideoController` plus a synthetic source on
one side and a memory stub on the other — and verifies behaviour at
the system boundary.

## Running tests

Configure the build with the simulation toolchain on PATH and the
Gowin install pointed at:

```sh
cmake -S . -B build \
    -D IVerilog_PATH=/usr/bin \
    -D Gowin_PATH=/opt/Gowin/IDE
```

Then:

```sh
ctest --test-dir build                       # every test in parallel
ctest --test-dir build -L unit               # only unit tests
ctest --test-dir build -L integration        # only integration tests
ctest --test-dir build -L buffer_controller  # filter by DUT name
ctest --test-dir build -R unit_buffer_controller_read_run -V   # one test, verbose
```

Each entry under `UNIT_TESTS` / `INTEGRATION_TESTS` in
`sim/CMakeLists.txt` expands into three Make targets:

| Target                            | What it does                          |
| --------------------------------- | ------------------------------------- |
| `<scope>_<flat_name>_BUILD`       | compile the testbench (only)          |
| `<scope>_<flat_name>_SIM`         | compile + run, no `output.txt` check  |
| `<scope>_<flat_name>_run` (ctest) | compile + run + check the exit code   |

`<scope>` is `unit` or `integration`. `<flat_name>` is the path under
the scope folder with `/` replaced by `_` (so
`buffer_controller/read` becomes `buffer_controller_read`, and the
full test name is `unit_buffer_controller_read`). Per-test artifacts
land under `build/sim/tests/<scope>/<path>/`:

- `output.txt` — captured stdout / stderr from the simulator.
- `dump.vcd` — waveform dump (only if you configured with
  `-D DUMP_SIM_VARIABLES=ON`).
- `<test_name>.bin` — the compiled iverilog binary.

To debug a failing test: re-configure with `-D DUMP_SIM_VARIABLES=ON`,
rerun it, then open the resulting `dump.vcd` in GtkWave.

## CTest labels

`register_test()` attaches two labels to every test: the scope
(`unit` / `integration`) and the DUT or topic name (the first path
component). They show up under `ctest -L <label>` and are listed in
the per-test summary at the end of a run. The current labels are
`unit`, `integration`, `buffer_controller`, `debug_pattern_generator`,
`lcd_controller`, `frame_roundtrip`.

## Adding a new test

1. **Pick a scope.**
   - Touches one RTL module + trivial harness → `unit/<dut>/`.
   - Wires multiple modules together → `integration/<topic>/`.
2. **Pick a file name.** Short, descriptive, no `_test` suffix — the
   `unit/` / `integration/` prefix already says "test." Example:
   `unit/buffer_controller/reset_recovery.sv`.
3. **Write the testbench** using the template below and the
   conventions further down.
4. **Register it** in `sim/CMakeLists.txt` by appending its path
   (without the `.sv`) to `UNIT_TESTS` or `INTEGRATION_TESTS`:

   ```cmake
   set(UNIT_TESTS
       buffer_controller/read
       buffer_controller/reset_recovery   # ← new entry
       ...
   )
   ```

5. **Re-run cmake configure** (CMake picks up the new entry on
   reconfigure; it doesn't auto-watch the list). Then
   `ctest -R unit_buffer_controller_reset_recovery_run -V`.

## Testbench template

```systemverilog
`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;

reg clk;
reg reset_n;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

// --- DUT instantiation ---
// MyModule dut(.clk(clk), .rst_n(reset_n), ...);

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");

    clk = 0;

    reset_n = 1'b1;
    #2;
    reset_n = 1'b0;
    repeat(2) @(posedge clk);
    reset_n = 1'b1;

    // ... drive stimulus, observe responses ...

    `TEST_PASS
end

always #18.519 clk = ~clk;   // 27 MHz

// Wall-clock guard. Time units come from `timescale 1ns/10ps in
// timescale.v, so this is 1 ms of simulated time.
always #1_000_000 begin
    logger.error(module_name, "Test hung");
    `TEST_FAIL
end

endmodule
```

`main` is the required top module name — CMake passes `-s main` to
iverilog. `GSR` is also pulled in (`-s GSR`) for the Gowin global
reset network used inside the IP cores.

## Conventions

### Test outcome

Always exit through the `` `TEST_PASS `` or `` `TEST_FAIL `` macro
from [`sim/common/test_utils.sv`](../sim/common/test_utils.sv) — they
print a recognisable banner and call `$finish_and_return(0|1)`. The
per-test wrapper script greps for the non-zero exit code; raw
`$finish` won't trip CTest's PASS/FAIL.

### Logging

Use `svlogger.sv`'s `DataLogger` instance rather than raw `$display`:

```systemverilog
logger.info(module_name, "queue drained");
logger.error(module_name, "unexpected pixel value");
logger.debug(module_name, "received frame start");
```

The verbosity is controlled at configure time via
`-D SimLogLevel=Fatal|Error|Info|Debug|None` (default `Info`). All
levels above the configured threshold are compiled out, so debug
strings are free at the default level.

### Clocks

Most tests need three clocks: the 27 MHz `clk` (system / camera),
the 67.5 MHz `fb_clk` (frame-buffer arbiter), and the 13.5 MHz
`lcd_clock` (LCD pixel clock). The same Gowin rPLL primitive
(`SDRAM_rPLL`) the synthesizable design uses works in simulation —
clone the pattern from any existing test that needs the full triple:

```systemverilog
SDRAM_rPLL sdram_clock(
    .reset(~reset_n),
    .clkin(clk),
    .clkout(memory_clk),     // 135 MHz
    .clkoutd(lcd_clock),     // 13.5 MHz
    .lock(pll_lock)
);

always @(posedge memory_clk or negedge reset_n) begin
    if (!reset_n)        fb_clk <= #1 1'b0;
    else if (pll_lock)   fb_clk <= #1 ~fb_clk;
end
```

### NBA races

When the DUT updates a signal with a non-blocking assignment on
`@(posedge clk)` and the testbench reads it on the same edge, the
testbench wins the race and sees the *previous* value. Add a `#2;`
settle after the wait before sampling:

```systemverilog
repeat(1) @(posedge lcd_clock); #2;
if (queue_data_out_d !== expected) `TEST_FAIL
```

The 1 time unit covers `assign #1 mirror = original` delays the
existing tests use; the second time unit is slack so additional
combinational delays don't bite.

If the wait sits in a loop body, put the `#2;` *inside* the braces —
without `begin / end`, the settle only fires once after the loop
exits:

```systemverilog
// WRONG — #2 is outside the while body
while (queue_data_out_d !== TOKEN)
    repeat(1) @(posedge lcd_clock); #2;

// RIGHT
while (queue_data_out_d !== TOKEN) begin
    repeat(1) @(posedge lcd_clock); #2;
end
```

### Memory stubs

For tests that only need one side of `VideoController`:

- **Read-only stubs** (you exercise the download / LCD path):
  watch `mem_cmd_en && mem_cmd === 1'b0`, wait a few `fb_clk` cycles,
  drive `mem_r_data_valid` high for the burst length (8 word burst
  for `MEMORY_BURST=32`), feed `mem_r_data` from a memory you
  pre-filled in an `initial` block. See
  [`sim/integration/frame_roundtrip/read_23x17.sv`](../sim/integration/frame_roundtrip/read_23x17.sv).
- **Write-only stubs** (you exercise the upload path): capture
  `(mem_addr, mem_w_data)` on every `mem_cmd_en && mem_cmd === 1'b1`
  edge. Note that if FrameDownloader is also running it will issue
  read requests; stub both directions or `start_downloading` will
  hold the arbiter and starve FrameUploader.

For a full HyperRAM round-trip use
[`sim/common/psram_model.sv`](../sim/common/psram_model.sv) — it
implements the W955D8MKY bus protocol. None of the current
integration tests use it because the inline stubs are faster to
write and easier to debug, but it's there when you need a behavioural
PSRAM rather than a hand-rolled stub.

### Don't update lazily

The first thing to check when a new test "hangs" is whether you
provided a path for back-pressure to clear. A FIFO whose reader
never advances will fill; a `command_data_valid` source that waits
on `mem_controller_rdy` won't emit until the consumer asserts ready.
If the DUT log says "Start frame …" but no further state transitions
fire, that's almost always a missing handshake on the testbench side.

## Why some tests aren't here

The pre-restructure tree had 23 ctest cases; the baseline keeps 7
because:

- 14 tests referenced `VideoController` ports that no longer exist
  (`load_rd_en`, `load_queue_empty`, `load_queue_data`,
  `frame_uploader.frame_addr_inc`). Most were variations on the same
  FIFO-drain scenario and had been superseded by the integration
  tests anyway. They were deleted in the restructure commit; the
  history is still in git if you want to look.
- One test (`frame_buffer_test_read_frame_23x17_2`, renamed to
  `read_23x17_alt` during the move) depends on the horizontal
  scaler, which only works on the `img_resize` branch.
- One (`frame_buffer_test_read_write_frame_23x17`) used the
  pre-refactor port list and would have needed a full rewrite to
  cover the same write+read scenario; deferred.

The remaining gap is the camera **write** path *through PSRAM* —
`unit/cam_pixel_processor/frame_sequence.sv` now covers the camera
front end (it drives an OV7670-like byte stream and checks the
start / per-row / end command framing across the clk_cam→clk_mem
CDC), but there's still no green test that carries those pixels all
the way into PSRAM through `FrameUploader`. Adding one is on the menu
but blocked on a `DPG2 ↔ FrameUploader` handshake question (DPG2
doesn't emit until its consumer asserts ready, but `FrameUploader`
only asserts ready after seeing `command_data_valid`).

The `cam_pixel_processor` test deliberately stops at the command
framing and does **not** assert the packed RGB565 bytes: the IP
writes `input_pixel` to the row buffer combinationally while the word
address advances, so the stored word depends on byte-level write
timing that smoothly-varying image data tolerates but that no simple
golden model captures.
