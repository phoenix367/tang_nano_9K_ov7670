# demo_mcu_apps

Example firmware **overlays** for the SERV soft core. On a SERV-enabled bitstream
(`serv_mcu.enable`, see [`../doc/serv.md`](../doc/serv.md)) the MCU boots a
bootloader that loads an overlay from the host at runtime and jumps to it — so
these run without re-synthesizing the FPGA.

Each overlay is RISC-V (RV32I) assembly linked at `0x1000`
(`../serv_soc/overlay.ld`). It runs on SERV as a Wishbone master: it reaches the
device registers through the `0x40000000` window (low 16 bits = register number).
SERV presents word-aligned accesses + byte-enables; `serv_wb_cdc` resolves the
exact register (`word_addr + lane_offset(sel)`) and the value, so any register —
word-aligned or not — is reachable with normal loads/stores.

CMake builds each overlay to `build/serv_fw/<name>.bin` (part of the
`serv_firmware` target). Upload one with the web app's **Firmware** tab or
`modbus_client.serv_boot_load(open(path,'rb').read())`. An overlay that **jumps
back to `0x0000`** when finished returns control to the bootloader, so the host
can load another via the bootloader's re-arm (`osd_hello` does this). An overlay
that **parks** (loops forever) can't re-arm — but `serv_boot_load` resets the MCU
into the bootloader before every upload (Modbus reg `0xE2`, or the **Reset MCU**
button), so the host can always load any firmware over any running overlay.

## Apps

| App | What it does |
| --- | ------------ |
| [`osd_hello`](osd_hello/osd_hello.S) | After boot, writes **"Hello from MCU!!!"** centered on the OSD overlay (enable 0xFB, cursor 0xFC, chars 0xFD). |
| [`psram_test`](psram_test/psram_test.S) | Writes a pseudo-random sequence into channel-1 PSRAM (write port 0xF3/0xF4-0xF7), reads it back, compares, and prints **"PSRAM test: PASS/FAIL"** on the OSD. |

## Adding an app

1. Write `demo_mcu_apps/<name>/<name>.S` (link-at-0x1000 assembly; set `sp` in
   `_start` if you need a stack — the OSD demo doesn't).
2. Add an overlay build to the `serv_firmware` block in `CMakeLists.txt`
   (mirror `osd_hello`), producing `build/serv_fw/<name>.bin`.
3. Upload it via the Firmware tab / `serv_boot_load`.
