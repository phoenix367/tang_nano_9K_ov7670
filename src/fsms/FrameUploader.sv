`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`include "psram_utils.vh"
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`include "../psram_utils.vh"
`endif

`ifdef __ICARUS__
`include "svlogger.sv"
`endif

`include "psram_utils.vh"
`include "color_utilities.vh"

package FrameUploaderTypes;
    typedef enum bit[3:0] {
        FRAME_PROCESSING_START_WAIT = 'd0, 
        CHECK_QUEUE                 = 'd1, 
        FRAME_PROCESSING_DONE       = 'd2, 
        FRAME_PROCESSING_WRITE_CYC  = 'd3, 
        WRITE_MEMORY                = 'd4, 
        WRITE_MEMORY_WAIT           = 'd5,
        FRAME_WRITE_ROW_START       = 'd6,
        WAIT_FRAME_START_CMD        = 'd7,
        CHECK_FRAME_START           = 'd8,
        WAIT_ROW_START              = 'd9,
        CHECK_ROW_START             = 'd10,
        WAIT_FRAME_END              = 'd11,
        CHECK_FRAME_END             = 'd12
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
        input command_data_valid,
        input [1:0] command_data,
        input [31:0] pixel_data,
        input write_ack,
        input [20:0] base_addr,
        
        output reg read_rdy,
        output reg [9:0] pixel_addr,
        output reg write_rq,
        output reg [20:0] write_addr,
        output reg mem_wr_en,
        output [31:0] write_data,
        output reg upload_done,
        output mem_load_clk
    );

    localparam CACHE_DELAY = 'd2;

    import FrameUploaderTypes::*;
    import PSRAM_Utilities::*;

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    localparam FRAME_PIXELS_NUM = FRAME_WIDTH * FRAME_HEIGHT;
    localparam TCMD = burst_delay(MEMORY_BURST);
    localparam BURST_CYCLES = burst_cycles(MEMORY_BURST);

    assign mem_load_clk = clk;

    t_state state;

    reg [10:0] row_counter, col_counter;
    reg [5:0] write_cyc_counter;
    reg [20:0] frame_addr;
    reg [10:0] frame_counter;
    reg [1:0] command_data_recv;

    assign pixel_addr = col_counter[10:1];
    assign write_data = pixel_data;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            row_counter <= `WRAP_SIM(#1) 'd0;
            col_counter <= `WRAP_SIM(#1) 'd0;
            write_cyc_counter <= `WRAP_SIM(#1) 'd0;
            frame_addr <= `WRAP_SIM(#1) 'd0;
            write_addr <= `WRAP_SIM(#1) 'd0;
            upload_done <= `WRAP_SIM(#1) 1'b0;
            read_rdy <= `WRAP_SIM(#1) 1'b0;
            write_rq <= `WRAP_SIM(#1) 1'b0;
            mem_wr_en <= `WRAP_SIM(#1) 1'b0;
            frame_counter <= `WRAP_SIM(#1) 'd0;
            read_rdy <= `WRAP_SIM(#1) 1'b0;
            command_data_recv <= `WRAP_SIM(#1) 'd0;

            state <= `WRAP_SIM(#1) FRAME_PROCESSING_START_WAIT;
        end else begin
            case (state)
                FRAME_PROCESSING_START_WAIT: begin
                    upload_done <= `WRAP_SIM(#1) 1'b0;

                    if (start) begin
`ifdef __ICARUS__
                        string str;
`endif

                        frame_addr <= `WRAP_SIM(#1) base_addr;
                        row_counter <= `WRAP_SIM(#1) 'd0;

                        state <= `WRAP_SIM(#1) WAIT_FRAME_START_CMD;

`ifdef __ICARUS__
                        $sformat(str, "Start frame uploading at %0h", base_addr);
                        logger.info(module_name, str);
`endif
                    end
                end
                CHECK_QUEUE: begin
                    if (row_counter === FRAME_HEIGHT)
                        state <= `WRAP_SIM(#1) WAIT_FRAME_END;
                    else
                        state <= `WRAP_SIM(#1) WAIT_ROW_START;
                end
                WAIT_FRAME_START_CMD: begin
                    if (command_data_valid) begin
                        read_rdy <= `WRAP_SIM(#1) 1'b1;
                        command_data_recv <= `WRAP_SIM(#1) command_data;
                        state <= `WRAP_SIM(#1) CHECK_FRAME_START;
                    end
                end
                CHECK_FRAME_START: begin
                    read_rdy <= `WRAP_SIM(#1) 1'b0;

                    if (command_data_recv === 'd1)
                        state <= `WRAP_SIM(#1) WAIT_ROW_START;
                    else
                        state <= `WRAP_SIM(#1) WAIT_FRAME_START_CMD;
                end
                WAIT_ROW_START: begin
                    if (command_data_valid) begin
                        read_rdy <= `WRAP_SIM(#1) 1'b1;
                        command_data_recv <= `WRAP_SIM(#1) command_data;
                        state <= `WRAP_SIM(#1) CHECK_ROW_START;
                    end
                end
                CHECK_ROW_START: begin
                    read_rdy <= `WRAP_SIM(#1) 1'b0;

                    if (command_data_recv === 'd2)
                        state <= `WRAP_SIM(#1) FRAME_WRITE_ROW_START;
                    else
                        state <= `WRAP_SIM(#1) WAIT_ROW_START;
                end
                WAIT_FRAME_END: begin
                    if (command_data_valid) begin
                        read_rdy <= `WRAP_SIM(#1) 1'b1;
                        command_data_recv <= `WRAP_SIM(#1) command_data;
                        state <= `WRAP_SIM(#1) CHECK_FRAME_END;
                    end
                end
                CHECK_FRAME_END: begin
                    read_rdy <= `WRAP_SIM(#1) 1'b0;

                    if (command_data_recv === 'd3)
                        state <= `WRAP_SIM(#1) FRAME_PROCESSING_DONE;
                    else
                        state <= `WRAP_SIM(#1) WAIT_FRAME_END;
                end
                FRAME_PROCESSING_DONE: begin
                    upload_done <= `WRAP_SIM(#1) 1'b1;
                    frame_counter <= `WRAP_SIM(#1) frame_counter + 1'b1;
                    state <= `WRAP_SIM(#1) FRAME_PROCESSING_START_WAIT;
                end
                FRAME_WRITE_ROW_START: begin
                    write_cyc_counter <= `WRAP_SIM(#1) 'd0;
                    col_counter <= `WRAP_SIM(#1) 'd0;

                    state <= `WRAP_SIM(#1) WRITE_MEMORY_WAIT;
                end
                WRITE_MEMORY_WAIT: begin
                    write_rq <= `WRAP_SIM(#1) 1'b1;
                    write_cyc_counter <= `WRAP_SIM(#1) 'd0;

                    if (write_ack)
                        state <= `WRAP_SIM(#1) WRITE_MEMORY;
                end
                WRITE_MEMORY: begin
                    if (write_cyc_counter === BURST_CYCLES) begin
                        logic [21:0] tmp;

                        tmp = frame_addr + 'd16;
                        frame_addr <= `WRAP_SIM(#1) tmp[20:0];

                        state <= `WRAP_SIM(#1) FRAME_PROCESSING_WRITE_CYC;
                    end else if (write_cyc_counter === CACHE_DELAY) begin // Set two-cycles delay to compensate
                                                                          // delay of BSRAM with buffered output
                        mem_wr_en <= `WRAP_SIM(#1) 1'b1;
                        write_addr <= `WRAP_SIM(#1) frame_addr;
                        write_cyc_counter <= `WRAP_SIM(#1) write_cyc_counter + 1'b1;

                        if (col_counter !== FRAME_WIDTH) begin
                            logic [11:0] tmp;

                            tmp = col_counter + 'd2;
                            col_counter <= `WRAP_SIM(#1) tmp[10:0];
                        end
                    end else begin
                        mem_wr_en <= `WRAP_SIM(#1) 1'b0;
                        write_cyc_counter <= `WRAP_SIM(#1) write_cyc_counter + 1'b1;

                        if (col_counter !== FRAME_WIDTH) begin
                            logic [11:0] tmp;

                            tmp = col_counter + 'd2;
                            col_counter <= `WRAP_SIM(#1) tmp[10:0];
                        end
                    end
                end
                FRAME_PROCESSING_WRITE_CYC: begin
                    if (write_cyc_counter === TCMD + CACHE_DELAY) begin
                        write_rq <= `WRAP_SIM(#1) 1'b0;

                        if (col_counter === FRAME_WIDTH) begin
                            row_counter <= `WRAP_SIM(#1) row_counter + 1'b1;

                            state <= `WRAP_SIM(#1) CHECK_QUEUE;
                        end else if (write_ack == 1'b0)
                            state <= `WRAP_SIM(#1) WRITE_MEMORY_WAIT;
                    end else
                        write_cyc_counter <= `WRAP_SIM(#1) write_cyc_counter + 1'b1;
                end
            endcase
        end
    end

endmodule
