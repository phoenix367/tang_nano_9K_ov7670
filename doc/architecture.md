# Architecture

This document describes the FPGA design at a level of detail useful
when you need to change it. For a high-level pitch see the
[README](../README.md); for build / test / program mechanics see
[build.md](build.md).

## Target and constraints

- **FPGA:** Gowin GW1NR-9C, part `GW1NR-LV9QN88PC6/I5` (Tang Nano 9K).
- **Top-level module:** `CameraControl_TOP` in
  [`src/camera_control.v`](../src/camera_control.v).
- **Physical constraints:** [`src/camera_ov7670.cst`](../src/camera_ov7670.cst).
- **Timing constraints:** [`src/camera_control.sdc`](../src/camera_control.sdc).

The top is plain `.v`; most of the newer state machines and
controllers are SystemVerilog 2012 (`iverilog -g2012`). New
synthesizable modules can be either, but should match the convention
of the file they sit in. Don't rewrite working `.v` modules as `.sv`
for cosmetic reasons.

## Clock plan

A single Gowin rPLL ([`src/gowin_rpll/memory_rpll.v`](../src/gowin_rpll/memory_rpll.v))
fans the 27 MHz crystal out into the four clocks the design needs:

| Clock           | Frequency | Driven by         | Used for                                      |
| --------------- | --------- | ----------------- | --------------------------------------------- |
| `sys_clk`       | 27 MHz    | Crystal           | System logic, I2C, OV7670 XCLK                |
| `memory_clk`    | 135 MHz   | rPLL ×5           | PSRAM HyperRAM PHY                            |
| `fb_clk`        | 67.5 MHz  | `memory_clk` ÷ 2  | Frame buffer arbiter, FrameDownloader/Uploader|
| `lcd_clock`     | 13.5 MHz  | `sys_clk` ÷ 2     | LCD pixel clock                               |
| `video_clk_i`   | 27 MHz    | Camera PCLK input | OV7670 capture side                           |

```mermaid
flowchart LR
    XTAL["27 MHz crystal"] --> SYS["sys_clk<br/>27 MHz"]
    XTAL --> RPLL["rPLL<br/>memory_rpll"]
    RPLL -->|"×5"| MEM["memory_clk<br/>135 MHz"]
    MEM -->|"÷2"| FB["fb_clk<br/>67.5 MHz"]
    SYS -->|"÷2"| LCDK["lcd_clock<br/>13.5 MHz"]
    PCLK["OV7670 PCLK"] --> VID["video_clk_i<br/>27 MHz"]
```

`memory_clk` and `sys_clk` are declared as **exclusive** clock groups
in the `.sdc`; `lcd_clock`→`video_clock` and
`video_clock`→`memory_clock` paths are marked `false_path` since
buffer crossings rely on CDC primitives, not single-cycle paths.

Crossings between domains use the `CDC_*` and `Pulse_*` / `Pipeline_*`
primitives from the [`FPGADesignElements/`](../FPGADesignElements)
submodule. Re-use those rather than rolling new synchronizers.

## High-level data flow

```mermaid
flowchart LR
    OV["OV7670 camera"]
    CPP["cam_pixel_processor<br/>bytes → RGB565"]
    CFIFO["fifo_cam_data<br/>async FIFO"]
    FU["FrameUploader<br/>camera → PSRAM"]
    PSRAM[("PSRAM<br/>3-frame ring")]
    DRC["DownloadRowCache<br/>ping-pong prefetch<br/>+ vertical resize"]
    FD["FrameDownloader<br/>sequencer + drain"]
    HR["HorizontalResizer<br/>pillarbox borders"]
    SFIFO["store FIFO<br/>async FIFO"]
    LCDC["lcd_controller<br/>VGA_timing"]
    LCD["480×272 LCD"]

    OV -->|"video_clk_i"| CPP --> CFIFO
    CFIFO -->|"CDC → fb_clk"| FU -->|"write"| PSRAM
    PSRAM -->|"read"| DRC --> FD --> HR --> SFIFO
    SFIFO -->|"CDC → lcd_clock"| LCDC --> LCD

    BC["BufferController<br/>rd / wr pointers"] -.->|"grant slot"| FU
    BC -.->|"grant slot"| FD
    ARB["arbiter"] -.->|"PSRAM bus"| FU
    ARB -.->|"PSRAM bus"| DRC
```

Two FSMs sit on either side of PSRAM (the direction names are from the
*memory's* perspective — easy to flip mentally, so check the port list
before wiring anything):

- **`FrameUploader`** ([`src/fsms/FrameUploader.sv`](../src/fsms/FrameUploader.sv))
  drains the camera FIFO and **writes** 640×480 RGB565 pixels *into* a
  free frame slot (uploads pixels into memory).
- **`FrameDownloader`** ([`src/fsms/FrameDownloader.sv`](../src/fsms/FrameDownloader.sv))
  **reads** pixels back *out* of the active display frame (downloads
  pixels from memory) and feeds them to the LCD path. It is a thin
  sequencer + drain over **`DownloadRowCache`**
  ([`src/DownloadRowCache.sv`](../src/DownloadRowCache.sv)), a ping-pong
  row-prefetch cache that owns the PSRAM reads and the **vertical resize**;
  **`HorizontalResizer`** then adds the pillarbox borders downstream. See
  [state_machines.md](state_machines.md).

`FrameUploader`, `FrameDownloader`, `BufferController` and the
`arbiter` all live inside
[`src/video_controller.sv`](../src/video_controller.sv), which is in
turn wrapped by [`src/VGA_timing.v`](../src/VGA_timing.v) together with
the PSRAM IP, `cam_pixel_processor`, `lcd_controller`, and the channel-1
frame-grab engine. The module layout inside `VGA_timing`, the four-way
arbiter, the camera-write DMA, and the frame-download path are documented
in [video_datapath.md](video_datapath.md).

`BufferController` ([`src/BufferController.sv`](../src/BufferController.sv))
owns the write / read pointers and decides when each FSM is allowed
to advance to the next slot. The PSRAM bus is shared between them by
[`src/arbiter.v`](../src/arbiter.v).

For the per-state behaviour of the two FSMs (state diagrams, command-token
handshakes, the resize / pillarbox states), see
[state_machines.md](state_machines.md).

## Camera initialization (I2C / SCCB)

OV7670 register values come from a ROM
([`src/ov7670_default.sv`](../src/ov7670_default.sv) — the table is
defined via [`src/ov7670_regs.vh`](../src/ov7670_regs.vh)).

At power-on, `i2c_control_fsm` walks the ROM and pushes each
`(addr, value)` pair to the camera over SCCB through `i2c_master`
([`src/i2c_master/`](../src/i2c_master/)). Status LEDs reflect
completion / errors. After initialization the camera streams pixels
on its own clock domain (`video_clk_i`).

## Runtime register access over Modbus (Direct 1:1)

After the power-on load finishes, the same `i2c_control_fsm` is reused
to let a host read and write **live OV7670 registers** over the
FT2232H channel-B UART (1 Mbaud 8-E-1). A Modbus RTU slave
([`src/modbus_rtu_slave.sv`](../src/modbus_rtu_slave.sv), slave id 7)
runs with `EXTERNAL_BACKEND=1`: instead of an internal register file,
every holding-register access is handed to
[`src/modbus_cam_backend.sv`](../src/modbus_cam_backend.sv) over a small
request/ready handshake, and the bridge turns it into one SCCB
transaction. The mapping is **Direct 1:1** — the Modbus holding-register
address *is* the OV7670 register number (`0x00..0xC9`); a write uses the
low byte of the value, a read returns `{8'h00, reg_byte}`.

`camera_control.v` multiplexes the SCCB controller's command inputs by
ownership: the init FSM owns it until the ROM load reaches
`TRANSMIT_COMPLETE`, which latches `cam_init_complete`; from then on the
bridge owns it. The bridge stays idle until `cam_init_complete`, so the
default configuration is loaded undisturbed ("block until init done").
The bridge also answers reserved addresses directly (no SCCB): `0xF0`
firmware magic `0xA5`, `0xF1`/`0xF2` a free-running 16-bit uptime so a
host can detect a hard reset, and `0xF3`/`0xF8` plus the stream band
`≥ 0x1000` that drive the frame grab (see below).

The FC03 *response* payload lives in inferred BSRAM (`MAX_QTY = 127`), so
a single read can carry the protocol-max 127 registers — this is what
makes the frame download practical. The slave's `MAX_FRAME` (32) now only
bounds the *request* buffer (FC10 camera writes). The bridge runs
entirely on the 27 MHz `sys_clk` domain. End-to-end coverage:
`sim/integration/modbus/cam_bridge`.

The Modbus server's two blocks, their state machines, and all their
connections are documented in [modbus_server.md](modbus_server.md); the
full host-facing reference (register map, status registers, LEDs, web
app, CLI) is in [host_control.md](host_control.md).

### Frame grab and host download

The second PSRAM channel (channel 1) lets a host capture a full 640×480
frame and download it over the same Modbus link. `psram_ch1` *tees* the
channel-0 camera-write stream into channel 1 for one frame (armed by
register `0xF3`), then serves it back as 8-word burst reads;
`modbus_cam_backend` streams it pixel-by-pixel to FC03 reads of the
`≥ 0x1000` band. A full frame downloads in ~10 s at 1 Mbaud. The capture
costs no extra PSRAM read bandwidth and needs no arbiter changes — see
[video_datapath.md](video_datapath.md#frame-grab-and-host-download).

## Capture path

The OV7670 produces two pixel-clocks per RGB565 pixel (high byte then
low byte). [`src/cam_pixel_processor.sv`](../src/cam_pixel_processor.sv)
packs the byte stream into 16-bit pixels and pushes them into the
camera-side FIFO (`fifo_cam_data`, a Gowin async FIFO instance from
[`src/fifo_top/`](../src/fifo_top)).

`FrameUploader` (running on `fb_clk`) drains the FIFO in bursts,
forms PSRAM write commands, and hands them to the arbiter. When it
finishes the last row of a frame it asks `BufferController` to
advance the write pointer.

## 3-frame circular buffer

The buffer organizes the PSRAM as three frame slots and runs two
pointers around them, mirroring Gowin's Video Frame Buffer IP
behavior:

```mermaid
flowchart LR
    subgraph RING["PSRAM — 3 frame slots"]
        direction LR
        F1["frame 1"] --> F2["frame 2"] --> F3["frame 3"] --> F1
    end
    WR(["wr_pt — FrameUploader (write)"]) -.-> F1
    RD(["rd_pt — FrameDownloader (read)"]) -.-> F2
```

- `rd_pt` cycles frame1 → frame2 → frame3 → frame1 …
- `wr_pt` does the same, independently.
- **Writer faster than reader** → writer skips its current target
  forward, overwriting the previous frame (drops a frame to keep up).
- **Reader faster than writer** → reader stays on its current frame
  and replays it until the writer advances (repeats a frame).

This decouples the camera and LCD rates without needing them to match
or be PLL-locked.

## Display path

`FrameDownloader` reads pixels out of the active display frame and
pushes them into an asynchronous FIFO toward the LCD domain.
[`src/video_controller.sv`](../src/video_controller.sv) pulls pixels
from that FIFO and drives [`src/lcd_controller.sv`](../src/lcd_controller.sv),
which uses [`src/VGA_timing.v`](../src/VGA_timing.v) to generate
HSYNC / VSYNC / DE for the 4.3" 480×272 panel.

The 640×480 → LCD-size resize happens on the read side in two places:
[`src/PositionScaler_vert.sv`](../src/PositionScaler_vert.sv) drives the
**vertical** downscale (480 → 272) from inside `DownloadRowCache` (it sets
the per-row source-address stride), and
[`src/PositionScaler_horz.sv`](../src/PositionScaler_horz.sv) drives the
**horizontal** downscale inside `HorizontalResizer`, which also adds the
pillarbox borders. Both are compact DDA kernels (the older LUT variant is
generated by [`scripts/scaler_generator.py`](../scripts/scaler_generator.py)).
The number of source columns `FrameDownloader` reads/emits per row — and that
`HorizontalResizer` downscales — is the `EMIT_ROW_SIZE` parameter (640 for the
full row). See [state_machines.md](state_machines.md) for the FSMs.

### Configuration

Frame geometry is defined once in [`platform.json`](../platform.json)
(input/screen size, `emit_row_size`); CMake generates the SystemVerilog header
`src/platform_config.vh` from it, which `VGA_timing.v` includes and feeds to
`VideoController`. The geometry parameters (`FRAME_WIDTH`/`FRAME_HEIGHT`,
`ORIG_FRAME_WIDTH`/`HEIGHT`, `EMIT_ROW_SIZE`) have no defaults, so they must be
supplied explicitly. See [build.md](build.md#platform-configuration).

## Debug / bring-up paths

Two synthetic pattern generators bypass the camera input entirely:

- [`src/debug_pattern_generator.sv`](../src/debug_pattern_generator.sv)
- [`src/debug_pattern_generator2.sv`](../src/debug_pattern_generator2.sv)

These are wired into several testbenches (`debug_pattern_generator/*`,
`buffer_controller/*`) and are useful when you need a known,
predictable input to chase an integration bug without the camera in
the loop.

## Pin map

The `cst` file is the authoritative source; this is just the
shape of the connections.

### LCD (480×272 RGB565, 16 bpp + DE/HSYNC/VSYNC)

| Signal       | Pins                | Notes              |
| ------------ | ------------------- | ------------------ |
| `LCD_R[4:0]` | 71 72 73 74 75      |                    |
| `LCD_G[5:0]` | 55 56 57 68 69 70   |                    |
| `LCD_B[4:0]` | 41 42 51 53 54      |                    |
| `LCD_CLK`    | 35                  |                    |
| `LCD_DEN`    | 33                  |                    |
| `LCD_SYNC`   | 34                  | VSYNC              |
| `LCD_HYNC`   | 40                  | HSYNC (repo spelling) |

### OV7670

| Signal            | Pins                    | Notes                  |
| ----------------- | ----------------------- | ---------------------- |
| `cam_data_i[7:0]` | 79 77 81 80 83 82 85 84 |                        |
| `v_sync_i`        | 31                      | VSYNC from camera      |
| `h_sync_i`        | 32                      | HREF from camera       |
| `video_clk_i`     | 28                      | PCLK from camera       |
| `cam_clk`         | 29                      | XCLK to camera (= sys_clk) |
| `cam_reset`       | 63                      |                        |
| `cam_pwdn`        | 27                      | held low — always powered |
| `master_sda`      | 25                      | SCCB data              |
| `master_scl`      | 26                      | SCCB clock             |

### Board

| Signal        | Pins      | Notes              |
| ------------- | --------- | ------------------ |
| `sys_clk`     | 52        | 27 MHz crystal     |
| `sys_rst_n`   | 4         | S2 button          |
| `status_leds` | 14 15 16  |                    |
| `debug_led`   | 13        |                    |
| `led_out`     | 10        |                    |
| `led_out1`    | 11        |                    |

PSRAM (`O_psram_*` / `IO_psram_*`) is routed to the GW1NR-9C's
on-package HyperRAM through the Gowin
`psram_memory_interface_hs_2ch` IP — its pin assignments come from
the IP, not the user `.cst`. Channel 0 is the live video frame buffer;
**channel 1** is owned by `src/psram_ch1.sv`, which on request *tees* the camera
write stream into ch1 to capture a full frame and serves it back as 8-word burst
reads. `modbus_cam_backend.sv` streams that frame to the host over Modbus FC03
(stream band `≥ 0x1000`) — see [host_control.md](host_control.md#frame-grab-and-download).

## Source-tree organization

```
src/                  Synthesizable RTL
├── fsms/             FrameDownloader, FrameUploader state machines
├── gowin_rpll/       PLL IP (regenerate from IDE — don't hand-edit)
├── gowin_sdpb/       Dual-port BRAM IP
├── gowin_sdpb_dn/    Dual-port BRAM IP (legacy download cache — no longer instantiated)
├── gowin_alu54/      DSP block IP for the scaler
├── fifo_top/         Async FIFO IP (camera-side)
├── psram_memory_interface_hs_2ch/   HyperRAM PHY IP
├── sdpb_1kx32/       1Kx32 BRAM IP (camera row buffers + download prefetch banks)
├── cam_settings_rom/ ROM IP holding OV7670 register defaults
├── i2c_master/       I2C / SCCB master core
└── (top-level: camera_control.v, BufferController.sv, video_controller.sv,
   lcd_controller.sv, VGA_timing.v, cam_pixel_processor.sv,
   DownloadRowCache.sv, HorizontalResizer.sv,
   PositionScaler_horz.sv, PositionScaler_vert.sv,
   ov7670_default.sv, ov7670_regs.vh, debug_pattern_generator{,2}.sv,
   uart.sv, modbus_rtu_slave.sv, modbus_cam_backend.sv,
   camera_ov7670.cst, camera_control.sdc, …)

sim/                  Icarus Verilog testbenches and behavioural models
├── common/           Shared infra + models (psram_model.sv, i2c_slave_model.sv,
│                     svlogger.sv, test_utils.sv, …)
├── unit/             Per-module tests (unit/<dut>/<scenario>.sv)
└── integration/      Cross-module tests (integration/<topic>/<scenario>.sv)

FPGADesignElements/   Submodule — CDC and pipeline primitives
scripts/              Codegen helpers (e.g. scaler_generator.py)
physical/             OpenSCAD + STL for the 3D-printed enclosure
doc/                  Diagrams, photos, this guide
```

The Gowin IP cores (every `gowin_*`, `fifo_top`, `psram_memory_interface_hs_2ch`,
`sdpb_1kx32`, `cam_settings_rom`) are generated by Gowin IDE.
Regenerate them through the IDE rather than hand-editing the `.v` /
`.vo` outputs.

When adding a new top-level synthesizable module, register it in
**both**:

1. `camera_ov7670.gprj` (so the Gowin IDE picks it up for synthesis).
2. The relevant CMake source list — `VIDEO_BUFFER_TEST_SOURCES` in
   [`sim/CMakeLists.txt`](../sim/CMakeLists.txt) for simulation, or
   `SYNT_SOURCES` in [`src/CMakeLists.txt`](../src/CMakeLists.txt) if
   it belongs to the standalone synthesis target.
