# tang_nano_9K_ov7670
This is OV7670 camera sensor demo project for Tang Nano 9K board. In this
project the development board is using to capture video from OV7670 sensor
and show it on 4.3" LCD screen in real time. The 640×480 capture is
resized on the fly to fit the 480×272 LCD with full aspect-preserving
(pillarbox) output: a vertical downscale plus a horizontal downscale of
the whole row, centred with black side borders.

The frame geometry (input/screen size, emit row size) is configured in
[`platform.json`](platform.json), from which CMake generates the
SystemVerilog header `src/platform_config.vh` used by the design.

## Hardware setup
Below you can find main components diagram.

![Components diagram](./doc/images/main_components.drawio.png "Title")

Here we have Tang Nano 9K development board, 4.3'' LCD screen and OV7670 camera sensor.
The whole system powered through USB cable. The fully assembled setup is on the photo.

![Board photo](./doc/images/board_photo.jpg "Board photo")

Here I added 3D-printed plastic holder to hold on all components together and
a simple PCB for interconnect between camera module and Tang Nano board.

You can find OpenSCAD file of plastic holder and STL model [here](physical).


## System description

Figure below shows high level representation of the system.

![System components](./doc/images/system_structure.drawio.png)

Here we have tree clock signals:
* main clock 27 MHz
* Memory clock 135 MHz
* LCD screen clock 13.5 MHz

I2C controller is used for camera module initial configuration. You can refer
to [ov7670_default.sv](src/ov7670_default.sv) file for configuration details.

Video buffer implements circular buffer for 3 frames. Frames have 640x480 size 
with 16-bit RGB565 pixels. Clock frequency for video buffer logi is 67.5 MHz.

The image below describes more detailed the video buffer.

![Frame buffer](doc/images/frame_buffer.png)

The buffer logic is very similar to implemented in Gowin Video Frame buffer IP.
The main steps are following:

The read pointer is represented by rd_pt, and the write pointer is represented by wr_pt.

1. Both read and write pointers are cyclic in the order of frame 1, frame 2,
frame 3.
2. rd_pt points to the next frame when one frame of data has been read.
3. wr_pt points to the next frame when one frame of data has been written.
4. After the initial reset, both read and write pointers start from frame 1.
5. When read is faster than write, it will be adjusted by repeating read
frame, i.e., the output frame rate is larger than the input frame rate, and
the switching of the read pointer is faster than that of the write pointer.
As shown in figure above, when a frame of data is read, rd_pt should be
switched from frame 1 to frame 2, if it is found that wr_pt is still in frame
2, then rd_pt still stops at frame 1, and read the data from frame 1, i.e.,
repeating frame 1 data one time.
6. When write is faster than read, it will be adjusted by writing a new
frame to overwrite the previous frame, i.e., the input frame rate is
greater than the output frame rate, and the switching of write pointer is
faster than that of the read pointer. As shown in figure above, when one
frame of data is written, wr_pt is to be switched to frame 3 from frame 2;
at this time, frame 3 is not occupied, then wr_pt is switched to frame 3
to write the data; because write is fast, after writing a frame of data,
wr_pt should be switched to frame 1 from frame 3; if it is found that
rd_pt is still in frame 1, then rd_pt still stops at frame 3, then the data is
still written to frame 3 buffer, overwriting the previously written data.
7. When the read and write rates are the same, i.e., the output frame rate
is equal to the input frame rate, then the read pointer will always follow
the write pointer, switching at the same rate.

The arbiter circuit is to receive and arbitrate the memory read/write
access requests from the input line buffer control circuit and the output line
buffer control circuit. At the same time, the data interface of input line buffer
control circuit and output line buffer control circuit is connected to memory controller.

Here memory controller is a Gowin PSRAM IP instance.

## Host control (Modbus + web app)

A **Modbus RTU server** built into the FPGA exposes the **live OV7670 registers**
over the on-board USB-UART (`/dev/ttyGowin`, 9600 8-E-1, slave id 7). The
holding-register address maps **1:1** to the camera register number
(`0x00`–`0xC9`), so a host reads/writes the camera over SCCB in real time —
adjust brightness, gain, white balance, gamma, the color matrix, mirror/flip,
test patterns, and more, without rebuilding.

A bundled **Flask web app** ([`webapp/`](webapp/)) gives a point-and-click panel
for all of this (with a gamma-curve plot and a color-matrix editor), and
`scripts/modbus_test.py` is a CLI for scripting. The board's status LEDs show
UART RX/TX activity, host-connected, camera-init-done, and SCCB errors.

See **[doc/host_control.md](doc/host_control.md)** for the quick-start guide,
register map, status registers, LED map, and web-app reference.

## How to build

Clone the repo with submodules (the `FPGADesignElements` library is a
submodule):

```sh
git clone --recurse-submodules https://github.com/phoenix367/tang_nano_9K_ov7670.git
cd tang_nano_9K_ov7670
```

Configure the build (Gowin IDE 1.9.9 Beta-4 or newer required for the
hardware flow, Icarus Verilog 12+ for the simulation flow):

```sh
cmake -S . -B build \
    -D IVerilog_PATH=/usr/bin \
    -D Gowin_PATH=/opt/Gowin/IDE
```

Then pick what you want to do — every step has a CMake target and
runs on Linux as well as Windows:

```sh
cmake --build build --target hw_all       # synthesis + PnR + bitstream
cmake --build build --target hw_program   # load bitstream into SRAM
ctest --test-dir build                    # run simulation tests
```

The Gowin IDE GUI still works as a fallback — `camera_ov7670.gprj` is
the authoritative project file and any synthesizable source has to be
registered there.

For the full reference — every target, the `--device` flag list, log
levels, FTDI udev setup on Linux, GtkWave dumps — see
**[doc/build.md](doc/build.md)**.

## Documentation

- **[doc/build.md](doc/build.md)** — build, simulate, and program from
  CMake on Linux or Windows.
- **[doc/architecture.md](doc/architecture.md)** — clock plan, data
  path, frame buffer, scaler, pin map.
- **[doc/host_control.md](doc/host_control.md)** — Modbus server, camera
  register map, status registers, LED map, web app, and quick-start guide.
- **[doc/testing.md](doc/testing.md)** — simulation testbench layout,
  CTest labels, NBA-race conventions, how to add a new test.
- **[CLAUDE.md](CLAUDE.md)** — quick context for AI coding agents
  (Claude Code etc.) working in the tree.

## Working demo

Here is a short video to demonstrate how the whole setup is working.

https://github.com/phoenix367/tang_nano_9K_ov7670/assets/2589419/772c0f9f-d9df-424a-a7af-923fc6d49a3e

## Known issues

* Resistors are used for logic level converting. Need to replace them
  with a specialized level-shifter IC.

## License

Source code and model files are distributed under MIT license. See the full license
text in the [LICENSE](LICENSE) file.
