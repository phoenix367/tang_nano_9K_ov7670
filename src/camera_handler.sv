`include "camera_control_defs.vh"
`ifdef __ICARUS__
`include "svlogger.sv"
`endif

module CameraHandler
`ifdef __ICARUS__
#(
    parameter MODULE_NAME = "",
    parameter LOG_LEVEL = `SVL_VERBOSE_INFO
)
`endif
(
    input                   PixelClk,
    input                   nRST
);
// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

endmodule
