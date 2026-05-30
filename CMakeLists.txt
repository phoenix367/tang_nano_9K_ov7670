cmake_minimum_required(VERSION 3.8)

project (cam_ov7670_sim LANGUAGES NONE)

option(IVerilog_PATH "Path to Icarus Verilog bin folder" NONE)
option(Gowin_PATH "Path to Gowin IDE folder" NONE)
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

set(SRC_FOLDER "${CMAKE_CURRENT_SOURCE_DIR}/src")
set(SIM_SRC_FOLDER "${CMAKE_CURRENT_SOURCE_DIR}/sim")
set(FPGA_ELEMENTS_FOLDER "${CMAKE_CURRENT_SOURCE_DIR}/FPGADesignElements")

# ---------------------------------------------------------------------------
# Platform configuration: platform.json is the single source of truth for the
# frame geometry, and CMake turns it into the SystemVerilog header
# src/platform_config.vh (a set of `define macros) that VGA_timing.v includes
# and feeds to VideoController. JSON is parsed with a regex (no string(JSON),
# to keep cmake_minimum_required(3.8)). Editing platform.json re-runs cmake.
# ---------------------------------------------------------------------------
set(PLATFORM_JSON "${CMAKE_CURRENT_SOURCE_DIR}/platform.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${PLATFORM_JSON}")
file(READ "${PLATFORM_JSON}" _PLATFORM_JSON_CONTENT)

# Extract an integer-valued key from the (flat) JSON into a cmake variable.
macro(platform_json_int key outvar)
    if (_PLATFORM_JSON_CONTENT MATCHES "\"${key}\"[ \t\r\n]*:[ \t\r\n]*([0-9]+)")
        set(${outvar} "${CMAKE_MATCH_1}")
    else()
        message(FATAL_ERROR "platform.json: key '${key}' is missing or not an integer")
    endif()
endmacro()

platform_json_int("input_frame_width"  PLATFORM_INPUT_FRAME_WIDTH)
platform_json_int("input_frame_height" PLATFORM_INPUT_FRAME_HEIGHT)
platform_json_int("screen_width"       PLATFORM_SCREEN_WIDTH)
platform_json_int("screen_height"      PLATFORM_SCREEN_HEIGHT)
platform_json_int("emit_row_size"      PLATFORM_EMIT_ROW_SIZE)

message(STATUS "Platform: ${PLATFORM_INPUT_FRAME_WIDTH}x${PLATFORM_INPUT_FRAME_HEIGHT} in, "
               "${PLATFORM_SCREEN_WIDTH}x${PLATFORM_SCREEN_HEIGHT} screen, "
               "emit_row_size=${PLATFORM_EMIT_ROW_SIZE}")

configure_file("${SRC_FOLDER}/platform_config.vh.in"
               "${SRC_FOLDER}/platform_config.vh" @ONLY)

set(CTEST_OUTPUT_ON_FAILURE ON)
set_property(GLOBAL PROPERTY USE_FOLDERS ON)

enable_testing()

add_subdirectory("src")
add_subdirectory("sim")

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
