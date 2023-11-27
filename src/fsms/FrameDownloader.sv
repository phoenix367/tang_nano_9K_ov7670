`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`ifdef __ICARUS__
`include "svlogger.sv"
`endif

module FrameDownloader
    #(
`ifdef __ICARUS__
        parameter MODULE_NAME = "",
        parameter LOG_LEVEL = `SVL_VERBOSE_INFO,
`endif

        parameter MEMORY_BURST = 32,
        parameter FRAME_WIDTH = 480,
        parameter FRAME_HEIGHT = 272,
        parameter ORIG_FRAME_WIDTH = 640,
        parameter ORIG_FRAME_HEIGHT = 480
    )
    (
        input clk,
        input reset_n,
        input start,
        input queue_full,
        input read_ack,
        input [20:0] base_addr,
        input reg [31:0] read_data,
        
        output [16:0] queue_data,
        output reg wr_en,
        output reg read_rq,
        output [20:0] read_addr,
        output reg mem_rd_en,
        output reg download_done
    );

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

endmodule
