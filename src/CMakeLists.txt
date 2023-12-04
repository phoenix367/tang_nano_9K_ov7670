set(SYNT_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/arbiter.v"
    "${CMAKE_CURRENT_SOURCE_DIR}/functions.v"
    "${CMAKE_CURRENT_SOURCE_DIR}/i2c_master.v"
    "${CMAKE_CURRENT_SOURCE_DIR}/i2c_master_bit_ctrl.v"
    "${CMAKE_CURRENT_SOURCE_DIR}/i2c_master_byte_ctrl.v"
    "${CMAKE_CURRENT_SOURCE_DIR}/i2c_master_defines.v"
    "${CMAKE_CURRENT_SOURCE_DIR}/i2c_control_fsm.v"
    "${CMAKE_CURRENT_SOURCE_DIR}/ov7670_default.sv"
    "${CMAKE_CURRENT_SOURCE_DIR}/ov7670_regs.vh"
)

add_custom_target(
    cam_synthesize
    COMMAND ${GOWIN_SYNTHESIS}
        -i ${SYNT_SOURCES}
)
