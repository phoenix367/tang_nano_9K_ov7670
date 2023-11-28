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

set(SRC_FOLDER "${CMAKE_CURRENT_SOURCE_DIR}/src")
set(SIM_SRC_FOLDER "${CMAKE_CURRENT_SOURCE_DIR}/sim")

set(CTEST_OUTPUT_ON_FAILURE ON)
set_property(GLOBAL PROPERTY USE_FOLDERS ON)

enable_testing()

add_subdirectory("sim")
