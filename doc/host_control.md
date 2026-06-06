# Host control: Modbus server, registers, LEDs, and the web app

After power-on the design configures the OV7670 from its ROM and starts
streaming to the LCD. From then on a host (PC) can **read and write the camera's
registers live** over the on-board USB-UART, using a Modbus RTU server built into
the FPGA. This document covers that interface end-to-end and a quick-start guide.

- [Quick start](#quick-start)
- [Modbus server](#modbus-server)
- [Camera register map](#camera-register-map)
- [Reserved registers (above the OV7670 map)](#reserved-registers-above-the-ov7670-map)
- [Board health (watchdog)](#board-health-watchdog)
- [OSD text overlay](#osd-text-overlay)
- [Frame grab and download](#frame-grab-and-download)
- [Status LEDs](#status-leds)
- [Web app](#web-app)
- [Command-line client](#command-line-client)

---

## Quick start

1. **Build and flash** the bitstream (full build reference in
   [build.md](build.md)):
   ```sh
   cmake -S . -B build -D IVerilog_PATH=/usr/bin -D Gowin_PATH=/opt/gowin/IDE
   cmake --build build --target hw_all
   cmake --build build --target hw_program_flash   # persistent (survives power-cycle)
   ```
2. **Make the serial port available.** The FT2232H channel B is the UART. Install
   the udev rule once so it appears as a stable, user-writable `/dev/ttyGowin`:
   ```sh
   sudo install -m 644 udev/99-gowin-ft2232h.rules /etc/udev/rules.d/
   sudo udevadm control --reload-rules        # then replug the cable
   ```
3. **Talk to it.** Either the web app or the CLI:
   ```sh
   # Web app (recommended)
   python3 -m venv .venv && .venv/bin/pip install -r webapp/requirements.txt
   .venv/bin/python webapp/app.py              # open http://127.0.0.1:5000

   # …or the CLI: read the OV7670 product ID (expect 0x76)
   scripts/modbus_test.py --port /dev/ttyGowin --reg-count 202 --read 0x0A 1
   ```
4. **Verify the camera answers:** PID `0x0A`=`0x76`, VER `0x0B`=`0x73`,
   MIDH/MIDL `0x1C`/`0x1D`=`0x7F`/`0xA2`. The host-active LED lights while a
   client is connected (see [Status LEDs](#status-leds)).

---

## Modbus server

A Modbus RTU **slave/server** ([`src/modbus/modbus_rtu_slave.sv`](../src/modbus/modbus_rtu_slave.sv))
sits on the 1 Mbaud 8-E-1 UART ([`src/modbus/uart.sv`](../src/modbus/uart.sv)) wired to the
FT2232H channel B.

| Parameter        | Value                                            |
| ---------------- | ------------------------------------------------ |
| Serial port      | `/dev/ttyGowin` (FT2232H channel B)              |
| Framing          | 1,000,000 baud (1 Mbaud), 8 data, **even** parity, 1 stop (8-E-1) |
| Transmission     | Modbus **RTU** (binary, CRC-16, t3.5 framing)    |
| Slave / unit id  | **7**                                            |
| Function codes   | `0x03` read holding, `0x06` write single, `0x10` write multiple |
| Exceptions       | `0x01` illegal function, `0x02` illegal address, `0x03` illegal value |
| Read-burst cap   | a single `0x03` reads ≤ 125 registers (response payload in BSRAM) |

The clock, slave id, address bound (`addr_limit`), FC03 read ceiling
(`max_read_qty`) and UART framing are defined once in [`platform.json`](../platform.json)
(`clock` / `modbus` / `uart` sections) and flow to **both** sides: CMake bakes them
into the gateware via `src/platform_config.vh`, and the host reads the same file
through [`platform_config.py`](../platform_config.py), so the web app
([`webapp/modbus_client.py`](../webapp/modbus_client.py)) and the CLI scripts
([`scripts/modbus_test.py`](../scripts/modbus_test.py),
[`scripts/frame_grab.py`](../scripts/frame_grab.py)) default to the right baud/parity/id
without hardcoding. Change `platform.json` and the RTL and host stay in lockstep.

Instead of an internal register file, the server runs with `EXTERNAL_BACKEND=1`:
every holding-register access is handed to
[`src/modbus/modbus_cam_backend.sv`](../src/modbus/modbus_cam_backend.sv), which performs **one
live SCCB transaction** on the shared `i2c_control_fsm`. The bridge stays idle
until power-on camera init has finished (`cam_init_complete`), so the default
configuration loads undisturbed ("block until init done"); a request that lands
during init simply waits for it to complete.

See [architecture.md](architecture.md#runtime-register-access-over-modbus-direct-11)
for how the bridge is wired into the SCCB datapath.

## Camera register map

The mapping is **Direct 1:1** — the Modbus holding-register address *is* the
OV7670 register number (`0x00`–`0xC9`, see
[`src/ov7670_regs.vh`](../src/ov7670_regs.vh)). OV7670 registers are 8-bit:

- **Write** (`0x06`/`0x10`): the **low byte** of the 16-bit Modbus value is sent.
- **Read** (`0x03`): returns `{0x00, reg_byte}` (value in the low byte).

Addresses `0xCA`–`0xEF` read as 0; `0xF0`–`0xFA` are the
[reserved bridge registers](#reserved-registers-above-the-ov7670-map); the stream band
`≥ 0x1000` serves the [frame download](#frame-grab-and-download). Addresses above
the configured range (`≥ 0x1100`) return illegal-address.

Commonly useful registers:

| Addr  | Name        | Meaning                                                        |
| ----- | ----------- | -------------------------------------------------------------- |
| `0x0A`| PID         | Product ID, read-only → `0x76`                                 |
| `0x0B`| VER         | Version, read-only → `0x73`                                    |
| `0x1C`/`0x1D` | MIDH/MIDL | Manufacturer ID → `0x7F`/`0xA2`                            |
| `0x00`| GAIN        | AGC gain (effective when AGC off)                              |
| `0x10`| AECH        | Exposure 9:2 (effective when AEC off)                          |
| `0x13`| COM8        | bit2 AGC, bit1 AWB, bit0 AEC auto-enables                      |
| `0x55`| BRIGHT      | Brightness                                                     |
| `0x56`| CONTRAS     | Contrast                                                       |
| `0x1E`| MVFP        | bit5 mirror, bit4 vertical flip                                |
| `0x3A`| TSLB        | bit5 negative image                                            |
| `0x3B`| COM11       | bit7 night mode                                                |
| `0x3D`| COM13       | bit7 gamma-correction enable                                   |
| `0x7A`,`0x7B`–`0x89` | SLOP, GAM1–GAM15 | Gamma curve (slope + 15 knee points)          |
| `0x4F`–`0x54`| MTX1–MTX6 | Color-correction matrix coefficients                        |
| `0x58`| MTXS        | Matrix coefficient signs (+ bit7 auto contrast-center)         |
| `0x70`/`0x71` | SCALING_XSC/YSC | bit7 each selects the test pattern (see below)       |

**Test pattern** (`SCALING_XSC[7]`, `SCALING_YSC[7]`): `00` none/live, `01`
(YSC bit) 8-bar color bar, `10` (XSC bit) shifting "1", `11` fade-to-gray. The
low bits are scaling values — preserve them (defaults `0x3A`/`0x35`), e.g. write
`0x71`=`0xB5` for the color bar, `0x35` to restore.

> Writing **COM7** (`0x12`) with its reset bit (`0x80`) re-resets the camera.

## Reserved registers (above the OV7670 map)

Addresses `0xF0`–`0xFD` are **bridge** registers, answered directly (no SCCB
cycle, served even during camera init) so a host can identify the firmware,
detect a hard reset, drive the [frame grab](#frame-grab-and-download), read
[board health](#board-health-watchdog), and write the [OSD text
overlay](#osd-text-overlay). The download stream band (`≥ 0x1000`) is
covered in [Frame grab and download](#frame-grab-and-download).

| Addr  | Access | Meaning                                                        |
| ----- | ------ | -------------------------------------------------------------- |
| `0xF0`| R      | Firmware magic — reads `0xA5` (confirms you're talking to this bridge) |
| `0xF1`| R      | Uptime, high byte                                              |
| `0xF2`| R      | Uptime, low byte                                              |
| `0xF3`| R/W    | Write `1` = arm a frame grab, `2` = trigger a single-word ch1 read. Read: bit0 = grab busy, bit1 = ch1 calibrated |
| `0xF4`/`0xF5`| W | Single-read ch1 address, low / high (debug)                    |
| `0xF6`/`0xF7`| R | Single-read ch1 word, high / low halves (debug)                |
| `0xF8`| W      | Rewind the [download stream](#frame-grab-and-download) to pixel 0 |
| `0xF9`| R      | [Watchdog board health](#board-health-watchdog) (bit-field, below) |
| `0xFA`| W      | Write `1` = reset to defaults — re-run the power-on camera init (reloads every OV7670 register from ROM) |
| `0xFB`| R/W    | [OSD overlay](#osd-text-overlay) control: write bit0 = show, bit1 = clear buffer; read bit0 = currently shown |
| `0xFC`| R/W    | OSD cursor (character cell `row*60 + col`, `0`–`1019`)          |
| `0xFD`| R/W    | OSD character at the cursor — **write** stores a code, **read** returns the stored code; either way the cursor auto-increments (wraps at 1020) |

The 16-bit uptime (`0xF1`/`0xF2`) is `0` at reset and free-runs (~1 Hz); read the
high byte first (it latches the low byte for a coherent pair). A host that sees
it jump **backward** knows the board was reset (its registers reverted to
defaults) and should re-read its settings.

### GPIO (4 bidirectional pins)

Two more bridge registers expose 4 general-purpose pins (`wb_gpio`; Tang Nano 9K
pins 48/49/76/30). They power up as inputs.

| Addr  | Access | Meaning                                                        |
| ----- | ------ | -------------------------------------------------------------- |
| `0xEA`| R/W    | Direction, bits[3:0]: `1` = output (drive), `0` = input (hi-Z). Reset `0` = all inputs |
| `0xEB`| R/W    | **Write** bits[3:0] = output latch (driven where dir=1); **read** bits[3:0] = live pin levels |

`modbus_client` helpers: `gpio_set_dir(mask)`, `gpio_write(value)`, `gpio_read()`,
`gpio_get_dir()`. The pins are shared with the SERV core — see
[serv.md](serv.md) and the [`gpio_blink`](../demo_mcu_apps/gpio_blink/gpio_blink.c)
MCU demo.

## Board health (watchdog)

A hardware **health watchdog** (`src/watchdog.sv`) continuously monitors an
activity heartbeat from each of three subsystems and surfaces the result two
ways — an on-board LED and a Modbus register:

| Subsystem | Heartbeat it watches            |
| --------- | ------------------------------- |
| LCD rendering        | `LCD_VSYNC` (per displayed frame)    |
| Memory subsystem     | PSRAM `rd_data_valid` / `cmd_en`     |
| OV7670 frame capture | camera `vsync` (per captured frame)  |

Each heartbeat must show activity at least every ~0.5 s once the watchdog is
armed (a ~2 s startup grace covers reset / PSRAM calibration / first frame). A
subsystem that goes quiet latches a **sticky** hang flag (held until the board is
reset).

**Debug LED** (pin 13): **blinks** ~1.6 Hz while all three subsystems are
healthy, and turns **solid on** if any of them hangs.

**Register `0xF9`** (read-only) reports the same state as a bit-field:

| Bit | Name         | Meaning                                              |
| --- | ------------ | ---------------------------------------------------- |
| 0   | `lcd_hang`   | LCD render heartbeat stalled (sticky)                |
| 1   | `mem_hang`   | memory/PSRAM heartbeat stalled (sticky)              |
| 2   | `cam_hang`   | OV7670 capture heartbeat stalled (sticky)            |
| 3   | `any_hang`   | OR of the three (== `lcd|mem|cam`)                   |
| 4   | `monitoring` | watchdog armed (past the startup grace)              |

A healthy board reads `0x10` (monitoring, no hangs). `monitoring = 0` means the
watchdog is still in its startup grace **or** the firmware predates the watchdog
(the register reads `0`), so treat the hang bits as meaningful only when
`monitoring = 1`. The web app's [Board-health row](#web-app) decodes these bits
live; the CLI can read them directly:

```sh
scripts/modbus_test.py --port /dev/ttyGowin --read 0xF9 1   # 0x0010 = healthy
```

## OSD text overlay

The LCD output carries an **on-screen-display** text layer composited over the
live video by `src/osd_overlay.sv` (see [the datapath
doc](video_datapath.md#osd-text-overlay)). Text is drawn in a built-in **8×16
font** (the IBM-VGA bitmap), white, over a **60 columns × 17 rows** character
grid (480×272 LCD). The host fills a character buffer over Modbus; the overlay
paints lit glyph pixels white and passes the video through everywhere else.

The font ROM is indexed by the raw byte sent: `0x00`–`0xFF` are the Latin-1
glyphs, and the otherwise-unused C1 range `0x80`–`0x9F` is overlaid with 32
**box-drawing / block pseudographics** (`─ │ ┌ ┐ … ═ ║ ╔ ╗ … █ ▀ ▄ ░ ▒ ▓ ■ ·`).
The byte each pseudographic maps to is defined once in `webapp/osd_charset.py`
and shared by the font generator and the host encoder.

Three reserved registers drive it (all served without an SCCB cycle):

| Addr  | Access | Meaning                                                        |
| ----- | ------ | -------------------------------------------------------------- |
| `0xFB`| R/W    | Control — write bit0 = show overlay, bit1 = clear the whole buffer; read bit0 = currently shown |
| `0xFC`| R/W    | Cursor — character cell `row*60 + col` (`0`–`1019`)            |
| `0xFD`| R/W    | Character at the cursor — **write** a code (Latin-1 `0x00`–`0xFF`, or `0x80`–`0x9F` for a pseudographic), or **read** to get the code stored there; either access **auto-increments** the cursor (wrapping at cell 1020) |

To write a string: set the cursor (`0xFC`) to `row*60 + col`, then write each
character's code to `0xFD` in turn — the auto-increment lets a whole line stream
with back-to-back FC06 writes. Control codes and space render blank. Clearing
(`0xFB` bit1) sweeps all 1020 cells to blank in hardware and homes the cursor.

**Reading the overlay back:** set the cursor (`0xFC`), then read `0xFD` to get the
glyph at the cursor; the cursor auto-increments, so back-to-back single reads walk
a run of cells. (The read is one bus wait-state slower than a write — the
character buffer's read port is registered — but the host doesn't notice over
UART.) To read the *whole* buffer efficiently, use the **burst-read band**:
addresses `0x0800`–`0x0FFF` (reads only) return successive cells from the cursor,
so a single FC03 of up to 127 registers fetches 127 cells at once — the full
60×17 buffer is ~9 reads instead of 1020. Set the cursor (`0xFC`), then FC03-burst
from `0x0800` (the address is ignored; the cursor walks). A write in this band is
ignored (reads as 0).

```sh
# show "HI" at the top-left, then enable the overlay
scripts/modbus_test.py --port /dev/ttyGowin --write 0xFC 0      # cursor -> (0,0)
scripts/modbus_test.py --port /dev/ttyGowin --write 0xFD 0x48   # 'H'
scripts/modbus_test.py --port /dev/ttyGowin --write 0xFD 0x49   # 'I'
scripts/modbus_test.py --port /dev/ttyGowin --write 0xFB 1      # show overlay

# read the two cells back
scripts/modbus_test.py --port /dev/ttyGowin --write 0xFC 0      # cursor -> (0,0)
scripts/modbus_test.py --port /dev/ttyGowin --read  0xFD 2      # -> 0x48 0x49
```

The character buffer crosses from the Modbus (`sys_clk`) domain to the LCD pixel
(`screen_clk`) domain through a dual-clock RAM; the show/hide bit crosses through
a `CDC_Bit_Synchronizer`. The web app exposes the same feature on its **OSD
overlay** tab, which caps the editor at 60×17 and offers click-to-insert palettes
for the special Latin-1 symbols and the box-drawing/block pseudographics.

## Frame grab and download

The bridge can capture a full **640×480 RGB565** camera frame into PSRAM
**channel 1** and stream it to the host — independent of the live LCD path on
channel 0. The capture is a zero-cost *tee* of the camera write stream into ch1
(no extra PSRAM read bandwidth); the download is plain Modbus FC03.

Sequence:

1. **Arm** — write `1` to `0xF3`. The next complete frame is mirrored into ch1.
2. **Wait** — poll `0xF3`; bit0 (busy) clears when the capture is done (~1 frame).
3. **Rewind** — write `1` to `0xF8` to reset the stream pointer to pixel 0.
4. **Stream** — repeatedly `FC03` read from the stream band (any address
   `≥ 0x1000`, e.g. `0x1000`) with up to 125 registers per request. Each register
   is one RGB565 pixel in raster order; the device auto-advances its pointer, so
   back-to-back reads walk the whole 307,200-pixel frame.

A full frame is ~614 KB and takes **~10 s at 1 Mbaud** (round-trip overhead over
the raw UART floor of ~6.8 s). The bus is busy for the whole download.

## Status LEDs

The six on-board user LEDs are **active-low** (driven `0` = lit):

| LED            | Pin | Meaning                                                  |
| -------------- | --- | -------------------------------------------------------- |
| `led_out`      | 10  | **Host active** — lit while a client is connected (recent traffic; clears ~6 s after it stops) |
| `led_out1`     | 11  | SCCB transmit error                                      |
| `debug_led`    | 13  | Video debug (bring-up)                                   |
| `status_leds[0]` | 14 | **UART RX** activity (blinks per received byte)        |
| `status_leds[1]` | 15 | **UART TX** activity (blinks per transmitted byte)     |
| `status_leds[2]` | 16 | Camera init done                                       |

RX/TX activity is stretched to ~50 ms so an individual 1 Mbaud byte is visible.

## Web app

A local Flask control panel ([`webapp/`](../webapp/), full docs in
[webapp/README.md](../webapp/README.md)) drives the camera over the Modbus
bridge:

```sh
python3 -m venv .venv && .venv/bin/pip install -r webapp/requirements.txt
.venv/bin/python webapp/app.py            # http://127.0.0.1:5000
```

Capabilities:

- **Connect** — pick a serial port (auto-detected, plus `/dev/ttyGowin`), set
  baud/slave; the connect step sanity-reads the Product ID.
- **Basic controls tab** — camera identity readout, a compact two-column control
  panel (sliders: brightness/contrast/gain/exposure + test-pattern selector;
  checkboxes: AGC/AWB/AEC, mirror/flip, negative, night mode), and a raw
  register read/write panel with a **Reset to defaults** button (re-runs the
  power-on camera init via register `0xFA`, then re-reads the reverted state).
- **Color tab** — a **gamma-curve** block (enable toggle + exponent slider that
  regenerates SLOP+GAM1–15, with a live SVG plot and the register values) and a
  **color-matrix** block (the 2×3 chroma matrix as a signed heatmap grid with
  per-cell sliders, an auto-contrast toggle, and before→after color swatches).
- **Capture tab** — grabs a full 640×480 frame into PSRAM channel 1, streams it
  back over Modbus (~10 s), draws it to a canvas, and offers a PNG download.
- **OSD overlay tab** — a text box (one line per screen row, 60 columns) with
  **Send to display** / **Clear** buttons and a **Show overlay** toggle; the text
  is composited over the live video on the LCD (see [OSD text
  overlay](#osd-text-overlay)).
- **Board health** — the Connection panel shows a health row, refreshed by the
  heartbeat, with an overall chip (Healthy / HANG / starting…) plus per-subsystem
  LCD / Memory / Camera chips decoded from the [watchdog](#board-health-watchdog)
  register `0xF9` (green OK, red on a latched hang).
- **Reset resilience** — a heartbeat polls the status registers; if the board is
  reset the UI resyncs, and if the port drops it shows a banner and
  auto-reconnects when it returns.

## Command-line client

[`scripts/modbus_test.py`](../scripts/modbus_test.py) is a dependency-light
(pyserial only) RTU client for scripting and bring-up:

```sh
# read the product ID (0x76) and version (0x73)
scripts/modbus_test.py --port /dev/ttyGowin --reg-count 202 --read 0x0A 2

# brightness = 0x60
scripts/modbus_test.py --port /dev/ttyGowin --reg-count 202 --write 0x55 0x60

# enable the 8-bar color bar, then restore the live image
scripts/modbus_test.py --port /dev/ttyGowin --reg-count 202 --write 0x71 0xB5
scripts/modbus_test.py --port /dev/ttyGowin --reg-count 202 --write 0x71 0x35
```

`--read ADDR COUNT`, `--write ADDR VALUE`, `--write-multi ADDR V…`; defaults to a
self-test if no operation is given. `-p/--port`, `-b/--baud`, `-s/--slave`.

[`scripts/frame_grab.py`](../scripts/frame_grab.py) captures a frame and saves
it (binary PPM always, plus PNG if Pillow is installed):

```sh
scripts/frame_grab.py --port /dev/ttyGowin -o frame.ppm
```
