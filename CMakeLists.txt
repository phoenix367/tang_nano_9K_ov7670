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

# Extract a boolean-valued key (true/false) into ON/OFF.
macro(platform_json_bool key outvar)
    if (_PLATFORM_JSON_CONTENT MATCHES "\"${key}\"[ \t\r\n]*:[ \t\r\n]*(true|false)")
        if (CMAKE_MATCH_1 STREQUAL "true")
            set(${outvar} ON)
        else()
            set(${outvar} OFF)
        endif()
    else()
        message(FATAL_ERROR "platform.json: key '${key}' is missing or not a boolean")
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
# SERV co-master (Phase 2). Whether the camera design includes the SERV soft
# core as a 2nd Wishbone master is controlled by platform.json's serv_mcu.enable
# (default true) -- the single source of truth, like the rest of the platform
# config. Building it needs the RISC-V toolchain + the serv/ submodule; if those
# are absent we WARN and build without SERV rather than fail, so a toolchain-less
# checkout still builds the camera. (The hw_serv_* standalone bring-up below is
# independent and stays gated purely on the toolchain.)
# ---------------------------------------------------------------------------
platform_json_bool("enable"            PLATFORM_SERV_MCU_ENABLE)
find_program(RISCV_GCC NAMES riscv64-unknown-elf-gcc riscv32-unknown-elf-gcc
             HINTS ${RISCV_PATH})
set(SERV_DIR "${CMAKE_CURRENT_SOURCE_DIR}/serv")
if (PLATFORM_SERV_MCU_ENABLE AND RISCV_GCC AND EXISTS "${SERV_DIR}/servant/servant.v")
    set(SERV_CONTROL TRUE)
    message(STATUS "SERV co-master ENABLED (platform.json serv_mcu.enable) -- heartbeat @0x00E0, mcu_clk 30 MHz")
else()
    set(SERV_CONTROL FALSE)
    if (PLATFORM_SERV_MCU_ENABLE)
        message(WARNING "platform.json serv_mcu.enable=true but RISC-V gcc / serv submodule not found "
                        "-> building the camera WITHOUT the SERV co-master "
                        "(set -D RISCV_PATH=<bin> and run: git submodule update --init serv)")
    endif()
endif()
set(SERV_BOOT_HEX    "${CMAKE_CURRENT_BINARY_DIR}/serv_fw/bootloader.hex")   # baked in
set(SERV_OVERLAY_BIN "${CMAKE_CURRENT_BINARY_DIR}/serv_fw/overlay_heartbeat.bin")  # host-uploaded
if (SERV_CONTROL)
    set(SERV_CONTROL_DEFINE "`define SERV_CONTROL")
    set(SERV_MEMFILE "${SERV_BOOT_HEX}")
    set(SERV_ENABLE "1")
    message(STATUS "SERV_CONTROL=ON: SERV boots the bootloader (loads overlays from the host)")
else()
    set(SERV_CONTROL_DEFINE "")
    set(SERV_MEMFILE "")
    set(SERV_ENABLE "0")
endif()
configure_file("${SRC_FOLDER}/build_config.vh.in"
               "${SRC_FOLDER}/build_config.vh" @ONLY)
# The timing constraints are generated too: Gowin uses a single SDC, so the
# SERV co-master's mcu_clk (30 MHz, mcu_rpll) constraints are injected here only
# on a SERV_CONTROL build (empty otherwise -> the default SDC is unchanged).
if (SERV_CONTROL)
    set(SERV_SDC_BLOCK
"create_generated_clock -name mcu_clk -source [get_ports {sys_clk}] -master_clock base -multiply_by 10 -divide_by 9 [get_pins {mcu_pll/rpll_inst/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {mcu_clk}]")
else()
    set(SERV_SDC_BLOCK "")
endif()
configure_file("${SRC_FOLDER}/camera_control.sdc.in"
               "${SRC_FOLDER}/camera_control.sdc" @ONLY)
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
# (RISCV_GCC / SERV_DIR were already resolved above for the SERV co-master gate.)
# ---------------------------------------------------------------------------
if (RISCV_GCC AND EXISTS "${SERV_DIR}/servant/servant.v")
    message(STATUS "Found RISC-V gcc at ${RISCV_GCC} - SERV bring-up targets enabled (hw_serv_*)")
    string(REPLACE "gcc" "objcopy" RISCV_OBJCOPY "${RISCV_GCC}")
    set(SERV_SOC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/serv_soc")
    set(SERV_FW_DIR  "${CMAKE_CURRENT_BINARY_DIR}/serv_fw")
    file(MAKE_DIRECTORY "${SERV_FW_DIR}")
    set(SERV_BLINK_DELAY "0x40000" CACHE STRING "blinky busy-loop delay (~1.5 s/toggle at 27 MHz)")

    # SERV memory layout: the overlay load/run base address (so the bootloader-
    # reserved region below it stays small -- the bootloader is only ~72 bytes).
    # Single source of truth: platform.json serv_mcu.overlay_base. The bootloader
    # copies overlays here + jumps here (-DOVERLAY); the overlay linker scripts are
    # generated from .in to link here -- so all three can never drift.
    platform_json_hex("overlay_base" SERV_OVERLAY_BASE)   # e.g. "0x400" -> 1024
    configure_file("${SERV_SOC_DIR}/overlay.ld.in"   "${SERV_SOC_DIR}/overlay.ld"   @ONLY)
    configure_file("${SERV_SOC_DIR}/overlay_c.ld.in" "${SERV_SOC_DIR}/overlay_c.ld" @ONLY)

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
    add_custom_target(serv_blink_firmware DEPENDS ${SERV_FW_HEX})

    # SERV bootloader (baked into BSRAM, the path build_config.vh points $readmemh
    # at) + the heartbeat OVERLAY (linked at the overlay base, emitted as a .bin the host
    # uploads at runtime -- not baked in). See doc/serv.md.
    add_custom_command(
        OUTPUT  ${SERV_BOOT_HEX}
        COMMAND ${RISCV_GCC} -nostartfiles -nostdlib -march=rv32i_zicsr -mabi=ilp32
                -Wl,--build-id=none -T ${SERV_DIR}/sw/link.ld -DOVERLAY=${SERV_OVERLAY_BASE}
                ${SERV_SOC_DIR}/bootloader.S -o ${SERV_FW_DIR}/bootloader.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${SERV_FW_DIR}/bootloader.elf ${SERV_FW_DIR}/bootloader.bin
        COMMAND python3 ${SERV_SOC_DIR}/bin2hex.py ${SERV_FW_DIR}/bootloader.bin ${SERV_BOOT_HEX}
        DEPENDS ${SERV_SOC_DIR}/bootloader.S ${SERV_DIR}/sw/link.ld ${SERV_SOC_DIR}/bin2hex.py
        COMMENT "Building SERV bootloader firmware (RV32I)"
        VERBATIM
    )
    add_custom_command(
        OUTPUT  ${SERV_OVERLAY_BIN}
        COMMAND ${RISCV_GCC} -nostartfiles -nostdlib -march=rv32i_zicsr -mabi=ilp32
                -Wl,--build-id=none -T ${SERV_SOC_DIR}/overlay.ld
                ${SERV_SOC_DIR}/heartbeat.S -o ${SERV_FW_DIR}/overlay_heartbeat.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${SERV_FW_DIR}/overlay_heartbeat.elf ${SERV_OVERLAY_BIN}
        DEPENDS ${SERV_SOC_DIR}/heartbeat.S ${SERV_SOC_DIR}/overlay.ld
        COMMENT "Building SERV heartbeat overlay (RV32I, linked at the overlay base)"
        VERBATIM
    )
    # demo_mcu_apps overlays (host-uploadable, linked at the overlay base).
    set(DEMO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/demo_mcu_apps")
    set(SERV_OSD_HELLO_BIN "${SERV_FW_DIR}/osd_hello.bin")
    add_custom_command(
        OUTPUT  ${SERV_OSD_HELLO_BIN}
        COMMAND ${RISCV_GCC} -nostartfiles -nostdlib -march=rv32i_zicsr -mabi=ilp32
                -Wl,--build-id=none -T ${SERV_SOC_DIR}/overlay.ld
                ${DEMO_DIR}/osd_hello/osd_hello.S -o ${SERV_FW_DIR}/osd_hello.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${SERV_FW_DIR}/osd_hello.elf ${SERV_OSD_HELLO_BIN}
        DEPENDS ${DEMO_DIR}/osd_hello/osd_hello.S ${SERV_SOC_DIR}/overlay.ld
        COMMENT "Building demo_mcu_apps/osd_hello overlay (RV32I, linked at the overlay base)"
        VERBATIM
    )
    # C overlays share demo_mcu_apps/common: crt0.S (stack + .bss zero + return to
    # the bootloader) and serv_io.h (device registers + helpers). They link at
    # the overlay base with the C-aware overlay_c.ld (adds .rodata + __bss_* symbols).
    set(DEMO_COMMON "${DEMO_DIR}/common")
    set(SERV_C_CRT  "${DEMO_COMMON}/crt0.S")
    set(SERV_C_HDR  "${DEMO_COMMON}/serv_io.h")
    set(SERV_C_BUILD ${RISCV_GCC} -nostartfiles -nostdlib -march=rv32i_zicsr -mabi=ilp32
                     -Os -ffreestanding -I ${DEMO_COMMON}
                     -Wl,--build-id=none -T ${SERV_SOC_DIR}/overlay_c.ld ${SERV_C_CRT})

    # c_hello: the OSD greeting in C.
    set(SERV_C_HELLO_BIN "${SERV_FW_DIR}/c_hello.bin")
    add_custom_command(
        OUTPUT  ${SERV_C_HELLO_BIN}
        COMMAND ${SERV_C_BUILD} ${DEMO_DIR}/c_hello/c_hello.c -o ${SERV_FW_DIR}/c_hello.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${SERV_FW_DIR}/c_hello.elf ${SERV_C_HELLO_BIN}
        DEPENDS ${DEMO_DIR}/c_hello/c_hello.c ${SERV_C_CRT} ${SERV_C_HDR} ${SERV_SOC_DIR}/overlay_c.ld
        COMMENT "Building demo_mcu_apps/c_hello overlay (C, linked at the overlay base)"
        VERBATIM
    )

    # psram_test: PSRAM write/read/verify with progress bars, in C.
    set(SERV_PSRAM_TEST_BIN "${SERV_FW_DIR}/psram_test.bin")
    add_custom_command(
        OUTPUT  ${SERV_PSRAM_TEST_BIN}
        COMMAND ${SERV_C_BUILD} ${DEMO_DIR}/psram_test/psram_test.c -o ${SERV_FW_DIR}/psram_test.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${SERV_FW_DIR}/psram_test.elf ${SERV_PSRAM_TEST_BIN}
        DEPENDS ${DEMO_DIR}/psram_test/psram_test.c ${SERV_C_CRT} ${SERV_C_HDR} ${SERV_SOC_DIR}/overlay_c.ld
        COMMENT "Building demo_mcu_apps/psram_test overlay (C, linked at the overlay base)"
        VERBATIM
    )
    # motion: background-subtraction motion detector (grab + free-PSRAM bg model).
    # Hand-written assembly (overlay.ld, no C runtime): the C version's monitor
    # loop miscompiled at -Os (desynced induction variables broke the periodic
    # background refresh), so the schedule is kept exact in explicit registers.
    set(SERV_MOTION_BIN "${SERV_FW_DIR}/motion.bin")
    add_custom_command(
        OUTPUT  ${SERV_MOTION_BIN}
        COMMAND ${RISCV_GCC} -nostartfiles -nostdlib -march=rv32i_zicsr -mabi=ilp32
                -Wl,--build-id=none -T ${SERV_SOC_DIR}/overlay.ld
                ${DEMO_DIR}/motion/motion.S -o ${SERV_FW_DIR}/motion.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${SERV_FW_DIR}/motion.elf ${SERV_MOTION_BIN}
        DEPENDS ${DEMO_DIR}/motion/motion.S ${SERV_SOC_DIR}/overlay.ld
        COMMENT "Building demo_mcu_apps/motion overlay (assembly, linked at the overlay base)"
        VERBATIM
    )
    # motion_c: the motion detector in C, to compare FPS against the asm motion.
    set(SERV_MOTION_C_BIN "${SERV_FW_DIR}/motion_c.bin")
    add_custom_command(
        OUTPUT  ${SERV_MOTION_C_BIN}
        COMMAND ${SERV_C_BUILD} ${DEMO_DIR}/motion_c/motion_c.c -o ${SERV_FW_DIR}/motion_c.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${SERV_FW_DIR}/motion_c.elf ${SERV_MOTION_C_BIN}
        DEPENDS ${DEMO_DIR}/motion_c/motion_c.c ${SERV_C_CRT} ${SERV_C_HDR} ${SERV_SOC_DIR}/overlay_c.ld
        COMMENT "Building demo_mcu_apps/motion_c overlay (C, linked at the overlay base)"
        VERBATIM
    )
    # calc: host-driven floating-point calculator (C). Needs libgcc (soft-float +
    # soft integer divide), so it links -lgcc and relies on the 16 KB MCU RAM.
    set(SERV_CALC_BIN "${SERV_FW_DIR}/calc.bin")
    add_custom_command(
        OUTPUT  ${SERV_CALC_BIN}
        COMMAND ${SERV_C_BUILD} ${DEMO_DIR}/calc/calc.c -lgcc -o ${SERV_FW_DIR}/calc.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${SERV_FW_DIR}/calc.elf ${SERV_CALC_BIN}
        DEPENDS ${DEMO_DIR}/calc/calc.c ${SERV_C_CRT} ${SERV_C_HDR} ${SERV_SOC_DIR}/overlay_c.ld
        COMMENT "Building demo_mcu_apps/calc overlay (C + libgcc soft-float, linked at the overlay base)"
        VERBATIM
    )
    add_custom_target(serv_firmware DEPENDS ${SERV_BOOT_HEX} ${SERV_OVERLAY_BIN}
                      ${SERV_OSD_HELLO_BIN} ${SERV_PSRAM_TEST_BIN} ${SERV_C_HELLO_BIN}
                      ${SERV_MOTION_BIN} ${SERV_MOTION_C_BIN} ${SERV_CALC_BIN})
    if (SERV_CONTROL)
        add_dependencies(hw_synth serv_firmware)
        add_dependencies(hw_all   serv_firmware)
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
    # SERV_CONTROL was already forced FALSE above when the toolchain/submodule is
    # missing (with a warning if serv_mcu.enable=true), so the camera still builds.
    message(STATUS "RISC-V gcc or serv/ submodule not found - SERV bring-up targets "
                   "disabled (set -D RISCV_PATH=<...> and run git submodule update --init serv)")
endif()
