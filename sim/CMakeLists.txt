set(CTEST_PARALLEL_LEVEL 4)

set(VIDEO_BUFFER_TEST_SOURCES
    "${SRC_FOLDER}/functions.v"
    "${SRC_FOLDER}/arbiter.v"
    "${SRC_FOLDER}/timescale.v"
    "${SRC_FOLDER}/ov7670_default.sv"
    "${SRC_FOLDER}/gowin_rpll/memory_rpll.v"
    "${SRC_FOLDER}/gowin_sdpb_dn/gowin_sdpb_dn.v"
    "${SRC_FOLDER}/gowin_alu54/gowin_alu54.v"
    "${SRC_FOLDER}/fifo_top/fifo_cam_data.vo"
    "${SRC_FOLDER}/video_controller.sv"
    "${SRC_FOLDER}/fsms/FrameUploader.sv"
    "${SRC_FOLDER}/fsms/FrameDownloader.sv"
    "${SRC_FOLDER}/cam_pixel_processor.sv"
    "${SRC_FOLDER}/lcd_controller.sv"
    "${SRC_FOLDER}/debug_pattern_generator.sv"
    "${SRC_FOLDER}/debug_pattern_generator2.sv"
    "${SRC_FOLDER}/BufferController.sv"
    "${SRC_FOLDER}/sdpb_1kx32/sdpb_1kx32.v"
    "${SRC_FOLDER}/sdpb_2kx16/sdpb_2kx16.v"
    "${SRC_FOLDER}/PositionScaler_horz.sv"
    "${SRC_FOLDER}/PositionScaler_vert.sv"
    "${SRC_FOLDER}/DownloadBuffer.sv"
    "${FPGA_ELEMENTS_FOLDER}/Register.v"
    "${FPGA_ELEMENTS_FOLDER}/Register_Toggle.v"
    "${FPGA_ELEMENTS_FOLDER}/Reset_Synchronizer.v"
    "${FPGA_ELEMENTS_FOLDER}/CDC_Word_Synchronizer.v"
    "${FPGA_ELEMENTS_FOLDER}/CDC_Bit_Synchronizer.v"
    "${FPGA_ELEMENTS_FOLDER}/Pipeline_Skid_buffer.v"
    "${FPGA_ELEMENTS_FOLDER}/Pipeline_Half_buffer.v"
    "${FPGA_ELEMENTS_FOLDER}/Pipeline_to_Pulse.v"
    "${FPGA_ELEMENTS_FOLDER}/Pulse_Generator.v"
    "${FPGA_ELEMENTS_FOLDER}/Pulse_Latch.v"
    "${FPGA_ELEMENTS_FOLDER}/Pulse_to_Pipeline.v"
)

set(TESTS_LIST 
    frame_buffer_test_full_frame_23x17
    frame_buffer_test_full_frame_multi_23x17
    frame_buffer_test_init_rnd_len
    frame_buffer_test_init_var_len
    frame_buffer_test_init0
    frame_buffer_test_init16
    frame_buffer_test_init16_0
    frame_buffer_test_init16_rnd_len
    frame_buffer_test_init16_var_len
    frame_buffer_test_read_frame_23x17
    frame_buffer_test_read_frame_23x17_2
    frame_buffer_test_read_frame_multi_23x17
    frame_buffer_test_read_frame_multi_23x17_2
    frame_buffer_test_read_write_frame_23x17
    lcd_controller_test
    debug_pattern_test
    debug_pattern_test_no_extra
    test_patter_write_frame_640x20
    debug_pattern_2_test
    buffer_controller_test_write
    buffer_controller_test_read
    buffer_controller_test_read_write_1
    buffer_controller_test_read_write_2
    download_buffer_test
)

set(BASE_TEST_DIR "${CMAKE_CURRENT_BINARY_DIR}/tests")
set(CMAKE_CTEST_ARGUMENTS "--extra-verbose")

if (WIN32)
    set(RUN_SIM_SCRIPT_NAME "run_simulator.bat")
else()
    message(FATAL_ERROR "Only Windows OS is supported")
endif()

set(TEST_SCRIPT_TEMPLATE "${SIM_SRC_FOLDER}/${RUN_SIM_SCRIPT_NAME}.in")
configure_file("${SIM_SRC_FOLDER}/test_config.sv.in" "${CMAKE_CURRENT_BINARY_DIR}/test_config.sv.tmp"
               )
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/test_config.sv" 
     INPUT "${CMAKE_CURRENT_BINARY_DIR}/test_config.sv.tmp")

foreach (TEST_NAME IN LISTS TESTS_LIST)
    set(TEST_SOURCES 
        "${SIM_SRC_FOLDER}/${TEST_NAME}.sv"
        "${SIM_SRC_FOLDER}/svlogger.sv"
        "${CMAKE_CURRENT_BINARY_DIR}/test_config.sv"
    )

    set(TEST_NAME_RUN "${TEST_NAME}_run")
    set(WORKING_TEST_DIR "${BASE_TEST_DIR}/${TEST_NAME}")

    set(TEST_OUTPUT_FILE "${WORKING_TEST_DIR}/${TEST_NAME}.bin")
    add_custom_command(OUTPUT ${TEST_OUTPUT_FILE}
        COMMAND "${VERILOG_BUILDER}"
                -g2012
                -I "${SRC_FOLDER}"
                -I "${SIM_SRC_FOLDER}"
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

    set(TEST_TARGET_NAME "${TEST_NAME}_BUILD")
    add_custom_target(
        ${TEST_TARGET_NAME} ALL DEPENDS ${TEST_OUTPUT_FILE}
        SOURCES ${VIDEO_BUFFER_TEST_SOURCES} ${TEST_SOURCES} "${SIMLIB_SRC}"
    )
    source_group("Functional Sources" FILES ${VIDEO_BUFFER_TEST_SOURCES})
    source_group("Test Sources" FILES ${TEST_SOURCES})
    source_group("Device library" FILES "${SIMLIB_SRC}")

    set(TEST_TARGET_NAME_SIM "${TEST_NAME}_SIM")
    add_custom_target(${TEST_TARGET_NAME_SIM} 
        COMMAND "${VERILOG_SIM}" 
                -n 
                "${TEST_OUTPUT_FILE}"
        COMMENT "Run simulation for test \"${TEST_NAME}\"..."
        DEPENDS "${TEST_OUTPUT_FILE}"
        WORKING_DIRECTORY "${WORKING_TEST_DIR}"
    )

    add_test(NAME ${TEST_NAME_RUN} 
        COMMAND "${WORKING_TEST_DIR}/${RUN_SIM_SCRIPT_NAME}"
    )

    set_tests_properties(${TEST_NAME_RUN} PROPERTIES DEPENDS ${TEST_OUTPUT_FILE}
        WORKING_DIRECTORY "${WORKING_TEST_DIR}")

    set_target_properties(${TEST_TARGET_NAME} PROPERTIES FOLDER "Tests/FrameBuffer/Build")
    set_target_properties(${TEST_TARGET_NAME_SIM} PROPERTIES FOLDER "Tests/FrameBuffer/Sim")
endforeach()
