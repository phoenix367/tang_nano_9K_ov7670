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

`include "psram_utils.vh"

package FrameUploaderTypes;
    typedef enum bit[7:0] {
        FRAME_PROCESSING_START_WAIT = 8'd0, 
        CHECK_QUEUE                 = 8'd1, 
        FRAME_PROCESSING_DONE       = 8'd2, 
        FRAME_PROCESSING_WRITE_CYC  = 8'd3, 
        READ_QUEUE_DATA             = 8'd4, 
        WAIT_TRANSACTION_COMPLETE   = 8'd5, 
        WRITE_MEMORY                = 8'd6, 
        WRITE_MEMORY_WAIT           = 8'd7
    } t_state;
endpackage

module FrameUploader
    #(
`ifdef __ICARUS__
        parameter MODULE_NAME = "",
        parameter LOG_LEVEL = `SVL_VERBOSE_INFO,
`endif

        parameter MEMORY_BURST = 32,
        parameter FRAME_WIDTH = 640,
        parameter FRAME_HEIGHT = 480
    )
    (
        input clk,
        input reset_n,
        input start,
        input queue_empty,
        input [16:0] queue_data,
        input write_ack,
        input [20:0] base_addr,
        
        output reg rd_en,
        output reg write_rq,
        output [20:0] write_addr,
        output reg mem_wr_en,
        output reg [31:0] write_data,
        output reg upload_done
    );

    import FrameUploaderTypes::*;
    import PSRAM_Utilities::*;

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    localparam CACHE_SIZE = MEMORY_BURST / 2;
    localparam BURST_CYCLES = MEMORY_BURST / 4;
    localparam FRAME_PIXELS_NUM = FRAME_WIDTH * FRAME_HEIGHT;
    localparam TCMD = burst_delay(MEMORY_BURST);


    t_state state;

    reg [10:0] row_counter, col_counter;
    reg [5:0] write_cyc_counter;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            row_counter <= `WRAP_SIM(#1) 'd0;
            col_counter <= `WRAP_SIM(#1) 'd0;
            write_cyc_counter <= `WRAP_SIM(#1) 'd0;

            state <= `WRAP_SIM(#1) FRAME_PROCESSING_START_WAIT;
        end else begin
            case (state)
                FRAME_PROCESSING_START_WAIT: begin
                    if (start) begin
                        row_counter <= `WRAP_SIM(#1) 'd0;
                    end
                end
                CHECK_QUEUE: begin
                end
            endcase
        end
    end

endmodule
