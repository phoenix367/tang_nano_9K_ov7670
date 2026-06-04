set(CTEST_PARALLEL_LEVEL 4)

set(VIDEO_BUFFER_TEST_SOURCES
    "${SRC_FOLDER}/functions.v"
    "${SRC_FOLDER}/arbiter.v"
    "${SRC_FOLDER}/timescale.v"
    "${SRC_FOLDER}/ov7670_default.sv"
    "${SRC_FOLDER}/gowin_rpll/memory_rpll.v"
    "${SRC_FOLDER}/gowin_sdpb/gowin_sdpb.v"
    "${SRC_FOLDER}/gowin_sdpb_dn/gowin_sdpb_dn.v"
    "${SRC_FOLDER}/fifo_top/fifo_cam_data.vo"
    "${SRC_FOLDER}/video_controller.sv"
    "${SRC_FOLDER}/fsms/FrameUploader.sv"
    "${SRC_FOLDER}/fsms/FrameDownloader.sv"
    "${SRC_FOLDER}/DownloadRowCache.sv"
    "${SRC_FOLDER}/cam_pixel_processor.sv"
    "${SRC_FOLDER}/lcd_controller.sv"
    "${SRC_FOLDER}/osd_overlay.sv"
    "${SRC_FOLDER}/debug/debug_pattern_generator.sv"
    "${SRC_FOLDER}/debug/debug_pattern_generator2.sv"
    "${SRC_FOLDER}/BufferController.sv"
    "${SRC_FOLDER}/sdpb_1kx32/sdpb_1kx32.v"
    "${SRC_FOLDER}/resize/PositionScaler_horz.sv"
    "${SRC_FOLDER}/resize/HorizontalResizer.sv"
    "${SRC_FOLDER}/resize/PositionScaler_vert.sv"
    "${SRC_FOLDER}/device_delay.sv"
    "${FPGA_ELEMENTS_FOLDER}/Register.v"
    "${FPGA_ELEMENTS_FOLDER}/Register_Toggle.v"
    "${FPGA_ELEMENTS_FOLDER}/Reset_Synchronizer.v"
    "${FPGA_ELEMENTS_FOLDER}/CDC_Word_Synchronizer.v"
    "${FPGA_ELEMENTS_FOLDER}/CDC_Bit_Synchronizer.v"
    "${FPGA_ELEMENTS_FOLDER}/Pipeline_Skid_Buffer.v"
    "${FPGA_ELEMENTS_FOLDER}/Pipeline_to_Pulse.v"
    "${FPGA_ELEMENTS_FOLDER}/Pulse_Generator.v"
    "${FPGA_ELEMENTS_FOLDER}/Pulse_Latch.v"
    "${FPGA_ELEMENTS_FOLDER}/Pulse_to_Pipeline.v"
)

# Tests are grouped by scope: `unit/<dut>/<scenario>` for per-module
# tests and `integration/<topic>/<scenario>` for cross-module tests.
# The path under sim/ becomes the relative source file, and the
# slash-separated form is also used as the ctest label group (so
# `ctest -L unit` and `ctest -L buffer_controller` both work).
set(UNIT_TESTS
    buffer_controller/read
    buffer_controller/write
    buffer_controller/read_write_1
    buffer_controller/read_write_2
    debug_pattern_generator/version2
    lcd_controller/timing
    position_scaler_vert/scale_272_480
    position_scaler_horz/characterization
    device_delay/countdown
    arbiter/round_robin
    cam_pixel_processor/frame_sequence
    horizontal_resizer/stream
    download_row_cache/prefetch
    frame_downloader/stream
    osd/overlay
)
set(INTEGRATION_TESTS
    frame_roundtrip/read_23x17
    pillarbox/borders
    pillarbox/borders_full
    pillarbox/borders_vmap
)

set(SIM_COMMON_FOLDER "${SIM_SRC_FOLDER}/common")
set(BASE_TEST_DIR "${CMAKE_CURRENT_BINARY_DIR}/tests")
set(CMAKE_CTEST_ARGUMENTS "--extra-verbose")

if (WIN32)
    set(RUN_SIM_SCRIPT_NAME "run_simulator.bat")
else()
    set(RUN_SIM_SCRIPT_NAME "run_simulator.sh")
endif()

set(TEST_SCRIPT_TEMPLATE "${SIM_COMMON_FOLDER}/${RUN_SIM_SCRIPT_NAME}.in")
configure_file("${SIM_COMMON_FOLDER}/test_config.sv.in" "${CMAKE_CURRENT_BINARY_DIR}/test_config.sv.tmp"
               )
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/test_config.sv"
     INPUT "${CMAKE_CURRENT_BINARY_DIR}/test_config.sv.tmp")

# Build one ctest case per (scope, scenario) entry. Each test gets:
#   - a build target  <scope>_<flat_name>_BUILD       (compile only)
#   - a simulate target <scope>_<flat_name>_SIM       (compile + run)
#   - a ctest case    <scope>_<flat_name>_run        (compile + run + check exit)
# `flat_name` is the slash-separated path with `/` replaced by `_`,
# so the make targets stay legal.
function(register_test SCOPE TEST_PATH)
    string(REPLACE "/" "_" FLAT_NAME "${TEST_PATH}")
    set(TEST_NAME "${SCOPE}_${FLAT_NAME}")
    set(TEST_SOURCE "${SIM_SRC_FOLDER}/${SCOPE}/${TEST_PATH}.sv")
    set(WORKING_TEST_DIR "${BASE_TEST_DIR}/${SCOPE}/${TEST_PATH}")
    set(TEST_OUTPUT_FILE "${WORKING_TEST_DIR}/${TEST_NAME}.bin")

    string(REGEX REPLACE "/.*$" "" DUT_LABEL "${TEST_PATH}")
    set(TEST_LABELS "${SCOPE};${DUT_LABEL}")

    # Extra per-test RTL/behavioural sources can be passed after TEST_PATH
    # (e.g. the I2C core + slave model for the i2c tests, which the common
    # VIDEO_BUFFER_TEST_SOURCES list does not include).
    set(TEST_SOURCES
        "${TEST_SOURCE}"
        "${SIM_COMMON_FOLDER}/svlogger.sv"
        "${CMAKE_CURRENT_BINARY_DIR}/test_config.sv"
        ${ARGN}
    )

    add_custom_command(OUTPUT ${TEST_OUTPUT_FILE}
        COMMAND "${VERILOG_BUILDER}"
                -g2012
                -I "${SRC_FOLDER}"
                -I "${SRC_FOLDER}/i2c"
                -I "${SRC_FOLDER}/modbus"
                -I "${SRC_FOLDER}/resize"
                -I "${SRC_FOLDER}/debug"
                -I "${SIM_SRC_FOLDER}"
                -I "${SIM_COMMON_FOLDER}"
                -s main
                -s GSR
                -o ${TEST_OUTPUT_FILE}
                ${VIDEO_BUFFER_TEST_SOURCES}
                "${SIMLIB_SRC}"
                ${TEST_SOURCES}
        DEPENDS ${VIDEO_BUFFER_TEST_SOURCES} ${TEST_SOURCES}
    )

    configure_file(${TEST_SCRIPT_TEMPLATE} "${WORKING_TEST_DIR}/${RUN_SIM_SCRIPT_NAME}"
                   @ONLY)

    add_custom_target("${TEST_NAME}_BUILD" ALL DEPENDS ${TEST_OUTPUT_FILE}
        SOURCES ${VIDEO_BUFFER_TEST_SOURCES} ${TEST_SOURCES} "${SIMLIB_SRC}"
    )
    source_group("Functional Sources" FILES ${VIDEO_BUFFER_TEST_SOURCES})
    source_group("Test Sources" FILES ${TEST_SOURCES})
    source_group("Device library" FILES "${SIMLIB_SRC}")

    add_custom_target("${TEST_NAME}_SIM"
        COMMAND "${VERILOG_SIM}"
                -n
                "${TEST_OUTPUT_FILE}"
        COMMENT "Run simulation for test \"${TEST_NAME}\"..."
        DEPENDS "${TEST_OUTPUT_FILE}"
        WORKING_DIRECTORY "${WORKING_TEST_DIR}"
    )

    if (WIN32)
        add_test(NAME "${TEST_NAME}_run"
            COMMAND "${WORKING_TEST_DIR}/${RUN_SIM_SCRIPT_NAME}"
        )
    else()
        add_test(NAME "${TEST_NAME}_run"
            COMMAND sh "${WORKING_TEST_DIR}/${RUN_SIM_SCRIPT_NAME}"
        )
    endif()

    set_tests_properties("${TEST_NAME}_run" PROPERTIES
        DEPENDS ${TEST_OUTPUT_FILE}
        WORKING_DIRECTORY "${WORKING_TEST_DIR}"
        LABELS "${TEST_LABELS}"
    )

    string(TOUPPER "${SCOPE}" SCOPE_UPPER)
    set_target_properties("${TEST_NAME}_BUILD" PROPERTIES FOLDER "Tests/${SCOPE_UPPER}/Build")
    set_target_properties("${TEST_NAME}_SIM" PROPERTIES FOLDER "Tests/${SCOPE_UPPER}/Sim")
endfunction()

foreach (TEST_PATH IN LISTS UNIT_TESTS)
    register_test(unit "${TEST_PATH}")
endforeach()

foreach (TEST_PATH IN LISTS INTEGRATION_TESTS)
    register_test(integration "${TEST_PATH}")
endforeach()

# UART module test (src/modbus/uart.sv is not part of VIDEO_BUFFER_TEST_SOURCES).
register_test(unit "uart/frame" "${SRC_FOLDER}/modbus/uart.sv")

# Health watchdog unit test (standalone module).
register_test(unit "watchdog/health" "${SRC_FOLDER}/watchdog.sv")

# Modbus RTU slave test (UART byte layer + the slave).
register_test(integration "modbus/rtu_slave"
    "${SRC_FOLDER}/modbus/uart.sv"
    "${SRC_FOLDER}/modbus/modbus_rtu_slave.sv"
)

# Modbus -> OV7670 register bridge: the slave (external backend) + the SCCB
# bridge + the full i2c controller/master stack against the behavioural slave.
register_test(integration "modbus/cam_bridge"
    "${SRC_FOLDER}/modbus/uart.sv"
    "${SRC_FOLDER}/modbus/modbus_rtu_slave.sv"
    "${SRC_FOLDER}/modbus/modbus_cam_backend.sv"
    "${SRC_FOLDER}/modbus/wb_interconnect.sv"
    "${SRC_FOLDER}/modbus/wb_sccb.sv"
    "${SRC_FOLDER}/modbus/wb_sysregs.sv"
    "${SRC_FOLDER}/modbus/wb_grab.sv"
    "${SRC_FOLDER}/modbus/wb_osd.sv"
    "${SRC_FOLDER}/i2c/i2c_master.v"
    "${SRC_FOLDER}/i2c/i2c_master_bit_ctrl.v"
    "${SRC_FOLDER}/i2c/i2c_master_byte_ctrl.v"
    "${SRC_FOLDER}/i2c/i2c_control_fsm.v"
    "${SIM_COMMON_FOLDER}/i2c_slave_model.sv"
)

# Wishbone bus slaves (split out of modbus_cam_backend). Each is a standalone
# module on the 27 MHz bus; the interconnect test stubs the slaves, so it needs
# only the decode/mux logic. wb_sccb drives the full SCCB stack like cam_bridge.
register_test(unit "wb_sysregs/regs"        "${SRC_FOLDER}/modbus/wb_sysregs.sv")
register_test(unit "wb_osd/cursor"          "${SRC_FOLDER}/modbus/wb_osd.sv")
register_test(unit "wb_grab/stream"         "${SRC_FOLDER}/modbus/wb_grab.sv")
register_test(unit "wb_interconnect/decode" "${SRC_FOLDER}/modbus/wb_interconnect.sv")
register_test(unit "wb_sccb/transaction"
    "${SRC_FOLDER}/modbus/wb_sccb.sv"
    "${SRC_FOLDER}/i2c/i2c_master.v"
    "${SRC_FOLDER}/i2c/i2c_master_bit_ctrl.v"
    "${SRC_FOLDER}/i2c/i2c_master_byte_ctrl.v"
    "${SRC_FOLDER}/i2c/i2c_control_fsm.v"
    "${SIM_COMMON_FOLDER}/i2c_slave_model.sv"
)

# The I2C controller test needs the opencores I2C master core, the control FSM
# and the behavioural slave model -- none are in VIDEO_BUFFER_TEST_SOURCES, so
# pass them as per-test extra sources.
register_test(integration "i2c/register_write"
    "${SRC_FOLDER}/i2c/i2c_master.v"
    "${SRC_FOLDER}/i2c/i2c_master_bit_ctrl.v"
    "${SRC_FOLDER}/i2c/i2c_master_byte_ctrl.v"
    "${SRC_FOLDER}/i2c/i2c_control_fsm.v"
    "${SIM_COMMON_FOLDER}/i2c_slave_model.sv"
)

# Register read exercises the i2c_master_top SCCB read path directly via a
# WISHBONE BFM, so it does not need i2c_control_fsm.
register_test(integration "i2c/register_read"
    "${SRC_FOLDER}/i2c/i2c_master.v"
    "${SRC_FOLDER}/i2c/i2c_master_bit_ctrl.v"
    "${SRC_FOLDER}/i2c/i2c_master_byte_ctrl.v"
    "${SIM_COMMON_FOLDER}/i2c_slave_model.sv"
)

# FSM read exercises the read path added to i2c_control_fsm end to end.
register_test(integration "i2c/fsm_read"
    "${SRC_FOLDER}/i2c/i2c_master.v"
    "${SRC_FOLDER}/i2c/i2c_master_bit_ctrl.v"
    "${SRC_FOLDER}/i2c/i2c_master_byte_ctrl.v"
    "${SRC_FOLDER}/i2c/i2c_control_fsm.v"
    "${SIM_COMMON_FOLDER}/i2c_slave_model.sv"
)
