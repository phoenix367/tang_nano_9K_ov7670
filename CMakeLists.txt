cmake_minimum_required(VERSION 3.8)

project (cam_ov7670_sim LANGUAGES NONE)

option(IVerilog_PATH "Path to Icarus Verilog bin folder" NONE)
option(Gowin_PATH "Path to Gowin IDE folder" NONE)
option(Yosys_PATH "Path to yosys bin folder (optional, enables formal targets)" NONE)
option(DUMP_SIM_VARIABLES "Enable dump variables during tests simulation" OFF)

set(SimLogLevel "Info" CACHE STRING
    "Logging level during tests simulation")
set(SimLogLevelValues "Fatal;Error;Info;Debug;None" CACHE STRING
  "List of possible values for the SimLogLevel cache variable")
set_property(CACHE SimLogLevel PROPERTY STRINGS ${SimLogLevelValues})

if (${SimLogLevel} STREQUAL "Fatal")
    set(TESTS_LOG_LEVEL "SVL_VERBOSE_FATAL")
elseif (${SimLogLevel} STREQUAL "Error")
    set(TESTS_LOG_LEVEL "SVL_VERBOSE_ERROR")
elseif (${SimLogLevel} STREQUAL "Info")
    set(TESTS_LOG_LEVEL "SVL_VERBOSE_INFO")
elseif (${SimLogLevel} STREQUAL "Debug")
    set(TESTS_LOG_LEVEL "SVL_VERBOSE_DEBUG")
elseif (${SimLogLevel} STREQUAL "None")
    set(TESTS_LOG_LEVEL "SVL_VERBOSE_NONE")
else()
    message(FATAL_ERROR "Invalid log level: ${SimLogLevel}")
endif()

message(STATUS "Simulation logging level: ${SimLogLevel}")

find_program(VERILOG_BUILDER iverilog HINTS ${IVerilog_PATH})
if (NOT VERILOG_BUILDER)
    message(FATAL_ERROR "Icarus verilog builder not found")
else()
    message(STATUS "Found Icarus verilog at ${VERILOG_BUILDER}")
endif()

find_program(VERILOG_SIM vvp HINTS ${IVerilog_PATH})
if (NOT VERILOG_SIM)
    message(FATAL_ERROR "Icarus verilog simulator not found")
else()
    message(STATUS "Found Icarus verilog simulator at ${VERILOG_SIM}")
endif()

find_file(SIMLIB_SRC NAMES "prim_tsim.v" HINTS "${Gowin_PATH}/simlib/gw1n")
if (NOT SIMLIB_SRC)
    message(FATAL_ERROR "Gowin simlib sources not found")
else()
    message(STATUS "Found Gowin simlib source file at ${SIMLIB_SRC}")
endif()

find_program(GOWIN_SYNTHESIS GowinSynthesis HINTS "${Gowin_PATH}/bin")
if (NOT GOWIN_SYNTHESIS)
    message(FATAL_ERROR "Gowin synthesis not found")
else()
    message(STATUS "Found Gowin synthesis at ${GOWIN_SYNTHESIS}")
endif()

# `programmer_cli` ships alongside the IDE under <root>/Programmer/bin.
# Strip the trailing /IDE off Gowin_PATH to find it. Not fatal if missing —
# the programming targets just won't be registered.
get_filename_component(_GOWIN_ROOT_FOR_PROG "${Gowin_PATH}" DIRECTORY)
find_program(GOWIN_PROGRAMMER programmer_cli
             HINTS "${_GOWIN_ROOT_FOR_PROG}/Programmer/bin")
if (GOWIN_PROGRAMMER)
    message(STATUS "Found Gowin programmer at ${GOWIN_PROGRAMMER}")
else()
    message(STATUS "Gowin programmer_cli not found - hw_program targets disabled")
endif()

# yosys is optional: when present it enables the formal-verification ctest
# targets (sby/). Not fatal if missing — those tests simply aren't registered.
find_program(YOSYS yosys HINTS ${Yosys_PATH})
if (YOSYS)
    message(STATUS "Found yosys at ${YOSYS} - formal targets enabled (ctest -L formal)")
else()
    message(STATUS "yosys not found - formal targets disabled")
endif()

set(SRC_FOLDER "${CMAKE_CURRENT_SOURCE_DIR}/src")
set(SIM_SRC_FOLDER "${CMAKE_CURRENT_SOURCE_DIR}/sim")
set(FPGA_ELEMENTS_FOLDER "${CMAKE_CURRENT_SOURCE_DIR}/FPGADesignElements")

# ---------------------------------------------------------------------------
# Platform configuration: platform.json is the single source of truth for the
# frame geometry, clock, Modbus identity and UART framing, and CMake turns it
# into the SystemVerilog header src/platform_config.vh (a set of `define macros)
# that VGA_timing.v / camera_control.v include and feed to their submodules.
# JSON is parsed with a regex (no string(JSON), to keep
# cmake_minimum_required(3.8)); the regex matches each key at any nesting depth,
# so the "geometry"/"clock"/"modbus"/"uart" sections are purely cosmetic to
# CMake and the keys must stay globally unique. Editing platform.json re-runs
# cmake.
# ---------------------------------------------------------------------------
set(PLATFORM_JSON "${CMAKE_CURRENT_SOURCE_DIR}/platform.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${PLATFORM_JSON}")
file(READ "${PLATFORM_JSON}" _PLATFORM_JSON_CONTENT)

# Extract an integer-valued key from the JSON into a cmake variable.
macro(platform_json_int key outvar)
    if (_PLATFORM_JSON_CONTENT MATCHES "\"${key}\"[ \t\r\n]*:[ \t\r\n]*([0-9]+)")
        set(${outvar} "${CMAKE_MATCH_1}")
    else()
        message(FATAL_ERROR "platform.json: key '${key}' is missing or not an integer")
    endif()
endmacro()

# Extract a hex-string-valued key ("0x1100") and convert it to a decimal cmake
# integer (so it can be emitted as a plain Verilog integer literal).
macro(platform_json_hex key outvar)
    if (_PLATFORM_JSON_CONTENT MATCHES "\"${key}\"[ \t\r\n]*:[ \t\r\n]*\"(0[xX][0-9A-Fa-f]+)\"")
        math(EXPR ${outvar} "${CMAKE_MATCH_1}")
    else()
        message(FATAL_ERROR "platform.json: key '${key}' is missing or not a hex string (\"0x...\")")
    endif()
endmacro()

# Extract a string-valued key and map it to a numeric code via a lookup list of
# "name=value" pairs (used for the UART parity enum: none=0, odd=1, even=2).
macro(platform_json_enum key outvar)
    if (_PLATFORM_JSON_CONTENT MATCHES "\"${key}\"[ \t\r\n]*:[ \t\r\n]*\"([A-Za-z]+)\"")
        set(_enum_name "${CMAKE_MATCH_1}")
        set(${outvar} "")
        foreach(_pair ${ARGN})
            string(REPLACE "=" ";" _kv "${_pair}")
            list(GET _kv 0 _n)
            list(GET _kv 1 _v)
            if (_enum_name STREQUAL _n)
                set(${outvar} "${_v}")
            endif()
        endforeach()
        if (${outvar} STREQUAL "")
            message(FATAL_ERROR "platform.json: key '${key}' has unsupported value '${_enum_name}'")
        endif()
    else()
        message(FATAL_ERROR "platform.json: key '${key}' is missing or not a string")
    endif()
endmacro()

# geometry
platform_json_int("input_frame_width"  PLATFORM_INPUT_FRAME_WIDTH)
platform_json_int("input_frame_height" PLATFORM_INPUT_FRAME_HEIGHT)
platform_json_int("screen_width"       PLATFORM_SCREEN_WIDTH)
platform_json_int("screen_height"      PLATFORM_SCREEN_HEIGHT)
platform_json_int("emit_row_size"      PLATFORM_EMIT_ROW_SIZE)
# clock
platform_json_int("sys_clk_hz"         PLATFORM_SYS_CLK_HZ)
# modbus
platform_json_int("device_id"          PLATFORM_MODBUS_DEVICE_ID)
platform_json_hex("addr_limit"         PLATFORM_MODBUS_ADDR_LIMIT)
platform_json_int("max_read_qty"       PLATFORM_MODBUS_MAX_READ_QTY)
platform_json_int("max_frame"          PLATFORM_MODBUS_MAX_FRAME)
platform_json_int("reg_count"          PLATFORM_MODBUS_REG_COUNT)
# uart
platform_json_int("baud"               PLATFORM_UART_BAUD)
platform_json_int("data_bits"          PLATFORM_UART_DATA_BITS)
platform_json_int("stop_bits"          PLATFORM_UART_STOP_BITS)
platform_json_enum("parity"            PLATFORM_UART_PARITY  none=0 odd=1 even=2)

message(STATUS "Platform: ${PLATFORM_INPUT_FRAME_WIDTH}x${PLATFORM_INPUT_FRAME_HEIGHT} in, "
               "${PLATFORM_SCREEN_WIDTH}x${PLATFORM_SCREEN_HEIGHT} screen, "
               "emit_row_size=${PLATFORM_EMIT_ROW_SIZE}")
message(STATUS "Platform: ${PLATFORM_SYS_CLK_HZ} Hz sys_clk, Modbus id ${PLATFORM_MODBUS_DEVICE_ID} "
               "(addr_limit=${PLATFORM_MODBUS_ADDR_LIMIT}, max_read_qty=${PLATFORM_MODBUS_MAX_READ_QTY}), "
               "UART ${PLATFORM_UART_BAUD} ${PLATFORM_UART_DATA_BITS}-parity${PLATFORM_UART_PARITY}-${PLATFORM_UART_STOP_BITS}")

configure_file("${SRC_FOLDER}/platform_config.vh.in"
               "${SRC_FOLDER}/platform_config.vh" @ONLY)

# ---------------------------------------------------------------------------
# Build-variant config (src/build_config.vh). SERV_CONTROL=ON adds the SERV soft
# core as a 2nd Wishbone master in the camera design (Phase 2; see doc/serv.md);
# the firmware hex it loads is built in the SERV block below. Generated
# unconditionally so camera_control.v's `include always resolves.
# ---------------------------------------------------------------------------
option(SERV_CONTROL "Add the SERV soft core as a 2nd Wishbone master (Phase 2)" OFF)
set(SERV_HEARTBEAT_HEX "${CMAKE_CURRENT_BINARY_DIR}/serv_fw/heartbeat.hex")
if (SERV_CONTROL)
    set(SERV_CONTROL_DEFINE "`define SERV_CONTROL")
    set(SERV_MEMFILE "${SERV_HEARTBEAT_HEX}")
    set(SERV_ENABLE "1")
    message(STATUS "SERV_CONTROL=ON: SERV is a 2nd Wishbone master (heartbeat @0x00E0)")
else()
    set(SERV_CONTROL_DEFINE "")
    set(SERV_MEMFILE "")
    set(SERV_ENABLE "0")
endif()
configure_file("${SRC_FOLDER}/build_config.vh.in"
               "${SRC_FOLDER}/build_config.vh" @ONLY)
# The Gowin project file is generated from a template: the SERV files carry
# enable="${SERV_ENABLE}", so when SERV_CONTROL is off Gowin excludes them from
# synthesis (they're not parsed, so they add no logic or phantom clocks).
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/camera_ov7670.gprj.in"
               "${CMAKE_CURRENT_SOURCE_DIR}/camera_ov7670.gprj" @ONLY)

set(CTEST_OUTPUT_ON_FAILURE ON)
set_property(GLOBAL PROPERTY USE_FOLDERS ON)

enable_testing()

add_subdirectory("src")
add_subdirectory("sim")
if (YOSYS)
    add_subdirectory("sby")
endif()

# Hardware build targets — drive Gowin's gw_sh in console mode to
# synthesize / place-and-route / generate the bitstream without the IDE
# GUI. `Gowin_PATH` is the IDE-root sibling, so strip the trailing /IDE
# segment to feed `GOWIN_PATH` to the wrapper script (which then sets
# the LD_LIBRARY_PATH / LD_PRELOAD the Linux launcher needs).
get_filename_component(GOWIN_ROOT "${Gowin_PATH}" DIRECTORY)
set(GPRJ_FILE "${CMAKE_CURRENT_SOURCE_DIR}/camera_ov7670.gprj")
set(HW_WRAPPER "${CMAKE_CURRENT_SOURCE_DIR}/scripts/gw_run.sh")
add_custom_target(hw_synth
    COMMAND ${CMAKE_COMMAND} -E env
            GOWIN_PATH=${GOWIN_ROOT}
            GPRJ=${GPRJ_FILE}
            STAGE=syn
            ${HW_WRAPPER}
    COMMENT "Gowin synthesis"
    USES_TERMINAL
)
add_custom_target(hw_impl
    COMMAND ${CMAKE_COMMAND} -E env
            GOWIN_PATH=${GOWIN_ROOT}
            GPRJ=${GPRJ_FILE}
            STAGE=pnr
            ${HW_WRAPPER}
    COMMENT "Gowin place-and-route + bitstream"
    USES_TERMINAL
)
add_custom_target(hw_all
    COMMAND ${CMAKE_COMMAND} -E env
            GOWIN_PATH=${GOWIN_ROOT}
            GPRJ=${GPRJ_FILE}
            STAGE=all
            ${HW_WRAPPER}
    COMMENT "Gowin synthesis + place-and-route + bitstream"
    USES_TERMINAL
)

# Programming targets — load the bitstream onto the Tang Nano 9K via
# the Gowin USB JTAG cable. `hw_program` writes SRAM only (volatile,
# fast — the FPGA reverts on power cycle). `hw_program_flash` writes
# the embedded flash so the bitstream survives a power cycle.
# Operation indices come from `programmer_cli --help`:
#   2 = SRAM Program
#   6 = embFlash Erase, Program, Verify
if (GOWIN_PROGRAMMER)
    set(BITSTREAM_FILE "${CMAKE_CURRENT_SOURCE_DIR}/impl/pnr/camera_ov7670.fs")
    add_custom_target(hw_program
        COMMAND ${GOWIN_PROGRAMMER}
                --device GW1NR-9C
                --run 2
                --fsFile ${BITSTREAM_FILE}
        COMMENT "Loading bitstream into SRAM (volatile)"
        USES_TERMINAL
    )
    add_custom_target(hw_program_flash
        COMMAND ${GOWIN_PROGRAMMER}
                --device GW1NR-9C
                --run 6
                --fsFile ${BITSTREAM_FILE}
        COMMENT "Programming embedded flash (persistent)"
        USES_TERMINAL
    )
endif()

# ---------------------------------------------------------------------------
# SERV soft-core bring-up (standalone, optional). Gated on a RISC-V toolchain
# and the serv/ submodule. Builds the blinky firmware into a BSRAM-preload hex,
# generates the serv_blink top with that hex path baked in, and registers
# hw_serv_* Gowin targets driving the ISOLATED serv_soc/serv_blink.gprj (its own
# impl/ dir). The camera design is completely untouched. See doc/serv.md.
# Provide RISCV_PATH if riscv*-elf-gcc isn't on PATH (e.g. a Vitis gnu/riscv bin).
# ---------------------------------------------------------------------------
find_program(RISCV_GCC NAMES riscv64-unknown-elf-gcc riscv32-unknown-elf-gcc
             HINTS ${RISCV_PATH})
set(SERV_DIR "${CMAKE_CURRENT_SOURCE_DIR}/serv")
if (RISCV_GCC AND EXISTS "${SERV_DIR}/servant/servant.v")
    message(STATUS "Found RISC-V gcc at ${RISCV_GCC} - SERV bring-up targets enabled (hw_serv_*)")
    string(REPLACE "gcc" "objcopy" RISCV_OBJCOPY "${RISCV_GCC}")
    set(SERV_SOC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/serv_soc")
    set(SERV_FW_DIR  "${CMAKE_CURRENT_BINARY_DIR}/serv_fw")
    file(MAKE_DIRECTORY "${SERV_FW_DIR}")
    set(SERV_BLINK_DELAY "0x40000" CACHE STRING "blinky busy-loop delay (~1.5 s/toggle at 27 MHz)")

    # Firmware: blinky.S -> elf -> bin -> 32-bit-word hex for servant_ram.
    set(SERV_FW_HEX "${SERV_FW_DIR}/blinky.hex")
    add_custom_command(
        OUTPUT  ${SERV_FW_HEX}
        COMMAND ${RISCV_GCC} -nostartfiles -nostdlib -march=rv32i_zicsr -mabi=ilp32
                -Wl,--build-id=none -T ${SERV_DIR}/sw/link.ld
                -DGPIO_BASE=0x40000000 -DDELAY=${SERV_BLINK_DELAY}
                ${SERV_DIR}/sw/blinky.S -o ${SERV_FW_DIR}/blinky.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${SERV_FW_DIR}/blinky.elf ${SERV_FW_DIR}/blinky.bin
        COMMAND python3 ${SERV_SOC_DIR}/bin2hex.py ${SERV_FW_DIR}/blinky.bin ${SERV_FW_HEX}
        DEPENDS ${SERV_DIR}/sw/blinky.S ${SERV_DIR}/sw/link.ld ${SERV_SOC_DIR}/bin2hex.py
        COMMENT "Building SERV blinky firmware (RV32I)"
        VERBATIM
    )
    add_custom_target(serv_firmware DEPENDS ${SERV_FW_HEX})

    # Phase 2 heartbeat firmware (SERV as a 2nd Wishbone master in the camera
    # design). Built into the path build_config.vh already points $readmemh at;
    # when SERV_CONTROL=ON, the camera hw_* builds depend on it.
    add_custom_command(
        OUTPUT  ${SERV_HEARTBEAT_HEX}
        COMMAND ${RISCV_GCC} -nostartfiles -nostdlib -march=rv32i_zicsr -mabi=ilp32
                -Wl,--build-id=none -T ${SERV_DIR}/sw/link.ld
                ${SERV_SOC_DIR}/heartbeat.S -o ${SERV_FW_DIR}/heartbeat.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${SERV_FW_DIR}/heartbeat.elf ${SERV_FW_DIR}/heartbeat.bin
        COMMAND python3 ${SERV_SOC_DIR}/bin2hex.py ${SERV_FW_DIR}/heartbeat.bin ${SERV_HEARTBEAT_HEX}
        DEPENDS ${SERV_SOC_DIR}/heartbeat.S ${SERV_DIR}/sw/link.ld ${SERV_SOC_DIR}/bin2hex.py
        COMMENT "Building SERV heartbeat firmware (RV32I)"
        VERBATIM
    )
    add_custom_target(serv_heartbeat_firmware DEPENDS ${SERV_HEARTBEAT_HEX})
    if (SERV_CONTROL)
        add_dependencies(hw_synth serv_heartbeat_firmware)
        add_dependencies(hw_all   serv_heartbeat_firmware)
    endif()

    # Generate serv_blink.v with the absolute hex path baked in for $readmemh.
    set(SERV_MEMFILE "${SERV_FW_HEX}")
    configure_file("${SERV_SOC_DIR}/serv_blink.v.in" "${SERV_SOC_DIR}/serv_blink.v" @ONLY)

    set(SERV_GPRJ "${SERV_SOC_DIR}/serv_blink.gprj")
    add_custom_target(hw_serv_synth
        COMMAND ${CMAKE_COMMAND} -E env GOWIN_PATH=${GOWIN_ROOT} GPRJ=${SERV_GPRJ}
                TOP=serv_blink STAGE=syn ${HW_WRAPPER}
        DEPENDS serv_firmware
        COMMENT "Gowin synthesis (SERV blinky)" USES_TERMINAL)
    add_custom_target(hw_serv_impl
        COMMAND ${CMAKE_COMMAND} -E env GOWIN_PATH=${GOWIN_ROOT} GPRJ=${SERV_GPRJ}
                TOP=serv_blink STAGE=pnr ${HW_WRAPPER}
        COMMENT "Gowin PnR + bitstream (SERV blinky)" USES_TERMINAL)
    add_custom_target(hw_serv_all
        COMMAND ${CMAKE_COMMAND} -E env GOWIN_PATH=${GOWIN_ROOT} GPRJ=${SERV_GPRJ}
                TOP=serv_blink STAGE=all ${HW_WRAPPER}
        DEPENDS serv_firmware
        COMMENT "Gowin synth + PnR + bitstream (SERV blinky)" USES_TERMINAL)

    if (GOWIN_PROGRAMMER)
        set(SERV_BITSTREAM "${SERV_SOC_DIR}/impl/pnr/serv_blink.fs")
        add_custom_target(hw_serv_program
            COMMAND ${GOWIN_PROGRAMMER} --device GW1NR-9C --run 2 --fsFile ${SERV_BITSTREAM}
            COMMENT "Loading SERV blinky into SRAM (volatile)" USES_TERMINAL)
        add_custom_target(hw_serv_program_flash
            COMMAND ${GOWIN_PROGRAMMER} --device GW1NR-9C --run 6 --fsFile ${SERV_BITSTREAM}
            COMMENT "Programming SERV blinky to embedded flash (persistent)" USES_TERMINAL)
    endif()
else()
    if (SERV_CONTROL)
        message(FATAL_ERROR "SERV_CONTROL=ON needs a RISC-V toolchain + the serv/ submodule "
                            "(set -D RISCV_PATH=<bin> and run git submodule update --init serv)")
    endif()
    message(STATUS "RISC-V gcc or serv/ submodule not found - SERV bring-up targets "
                   "disabled (set -D RISCV_PATH=<...> and run git submodule update --init serv)")
endif()
