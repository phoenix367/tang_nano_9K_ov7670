# Host control: Modbus server, registers, LEDs, and the web app

After power-on the design configures the OV7670 from its ROM and starts
streaming to the LCD. From then on a host (PC) can **read and write the camera's
registers live** over the on-board USB-UART, using a Modbus RTU server built into
the FPGA. This document covers that interface end-to-end and a quick-start guide.

- [Quick start](#quick-start)
- [Modbus server](#modbus-server)
- [Camera register map](#camera-register-map)
- [Reserved status registers](#reserved-status-registers)
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
| Read-burst cap   | a single `0x03` reads ≤ ~13 registers (`MAX_FRAME`) |

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

Addresses `0xCA`–`0xEF` read as 0; `0xF0`–`0xF8` are the
[status / frame-grab registers](#reserved-status-registers); the stream band
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

## Reserved status registers

The bridge answers three addresses **directly** (no SCCB cycle, served even
during camera init) so a host can identify the firmware and detect a hard reset:

| Addr  | Meaning                                                                 |
| ----- | ----------------------------------------------------------------------- |
| `0xF0`| Firmware magic — reads `0xA5` (confirms you're talking to this bridge)   |
| `0xF1`| Uptime, high byte                                                       |
| `0xF2`| Uptime, low byte                                                        |
| `0xF3`| Write `1` = arm a frame grab; write `2` = trigger a single-word ch1 read. Read: bit0 = busy, bit1 = ch1 calibrated |
| `0xF4`/`0xF5`| Single-read ch1 address, low / high (debug)                      |
| `0xF6`/`0xF7`| Single-read ch1 word, high / low halves (debug)                  |
| `0xF8`| Write = rewind the [download stream](#frame-grab-and-download) to pixel 0 |
| `0xF9`| Watchdog board health (read-only): bit0 LCD hang, bit1 memory hang, bit2 camera hang, bit3 any-hang, bit4 monitoring (armed). Per-subsystem bits are sticky until reset. Reads `0` on firmware without the watchdog. |

The 16-bit uptime is `0` at reset and free-runs (~1 Hz). A host that sees it jump
**backward** knows the board was reset (and its registers reverted to defaults),
and should re-read its settings.

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
  register read/write panel.
- **Color tab** — a **gamma-curve** block (enable toggle + exponent slider that
  regenerates SLOP+GAM1–15, with a live SVG plot and the register values) and a
  **color-matrix** block (the 2×3 chroma matrix as a signed heatmap grid with
  per-cell sliders, an auto-contrast toggle, and before→after color swatches).
- **Capture tab** — grabs a full 640×480 frame into PSRAM channel 1, streams it
  back over Modbus (~10 s), draws it to a canvas, and offers a PNG download.
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
