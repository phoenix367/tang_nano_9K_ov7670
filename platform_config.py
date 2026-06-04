"""Single source of truth for host-side platform constants.

Loads platform.json -- the *same* file CMake reads to generate
src/platform_config.vh for the gateware -- so the host UART/Modbus defaults
(baud, device id, framing) cannot drift from what the FPGA actually implements.
Both host stacks import this: the Flask web app (webapp/) and the CLI scripts
(scripts/). Change platform.json and both the RTL and the host follow.
"""

import json
import os

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "platform.json")
with open(_PATH) as _f:
    _CFG = json.load(_f)

# --- geometry ---
_geom = _CFG["geometry"]
FRAME_WIDTH = _geom["input_frame_width"]
FRAME_HEIGHT = _geom["input_frame_height"]
SCREEN_WIDTH = _geom["screen_width"]
SCREEN_HEIGHT = _geom["screen_height"]
EMIT_ROW_SIZE = _geom["emit_row_size"]

# --- clock ---
SYS_CLK_HZ = _CFG["clock"]["sys_clk_hz"]

# --- modbus ---
_modbus = _CFG["modbus"]
MODBUS_DEVICE_ID = _modbus["device_id"]
# addr_limit may be a hex string ("0x1100") or a plain int; normalize to int.
_addr_limit = _modbus["addr_limit"]
MODBUS_ADDR_LIMIT = int(_addr_limit, 0) if isinstance(_addr_limit, str) else int(_addr_limit)
MODBUS_MAX_READ_QTY = _modbus["max_read_qty"]
# Gateware-internal sizing (no host consumer); mirrored here so this module
# stays a complete view of platform.json.
MODBUS_MAX_FRAME = _modbus["max_frame"]
MODBUS_REG_COUNT = _modbus["reg_count"]

# --- uart ---
_uart = _CFG["uart"]
UART_BAUD = _uart["baud"]
UART_DATA_BITS = _uart["data_bits"]
UART_STOP_BITS = _uart["stop_bits"]
# pyserial / pymodbus take a single-char parity code.
_PARITY_CODE = {"none": "N", "odd": "O", "even": "E"}
UART_PARITY = _PARITY_CODE[_uart["parity"]]
