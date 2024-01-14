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
`include "color_utilities.vh"

package FrameUploaderTypes;
    typedef enum bit[7:0] {
        FRAME_PROCESSING_START_WAIT = 8'd0, 
        CHECK_QUEUE                 = 8'd1, 
        FRAME_PROCESSING_DONE       = 8'd2, 
        FRAME_PROCESSING_WRITE_CYC  = 8'd3, 
        READ_QUEUE_DATA             = 8'd4, 
        WAIT_TRANSACTION_COMPLETE   = 8'd5, 
        WRITE_MEMORY                = 8'd6, 
        WRITE_MEMORY_WAIT           = 8'd7,
        FRAME_WRITE_ROW_START       = 8'd8,
        INITIALIZE_PATTERN          = 8'd9,
        GENERATE_PATTERN            = 8'd10
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
        output reg [20:0] write_addr,
        output reg mem_wr_en,
        output reg [31:0] write_data,
        output reg upload_done
    );

    localparam NUM_COLOR_BARS = 10;
    localparam Colorbar_width = FRAME_WIDTH / NUM_COLOR_BARS;

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

    import ColorUtilities::*;

    logic [15:0] bar_colors[NUM_COLOR_BARS];

    initial begin
        logic [3:0] i;
        logic [15:0] c;

        for (i = 0; i < NUM_COLOR_BARS; i = i + 1) begin
            c = get_rgb_color(i);
            bar_colors[i] = c;
        end
    end

    function logic [15:0] get_pixel_color(input logic [10:0] column_index);
        integer i;
        logic exit;

        get_pixel_color = 16'h0000;
        exit = 1'b0;
        for (i = 0; i < NUM_COLOR_BARS && !exit; i = i + 1)
            if (column_index < (i + 1) * Colorbar_width) begin
                get_pixel_color = bar_colors[i];
                exit = 1'b1;
            end
    endfunction

    t_state state;

    reg [10:0] row_counter, col_counter;
    reg [5:0] write_cyc_counter;
    reg [20:0] frame_addr;
    reg [10:0] frame_counter;
    reg pattern_initialized;

    reg [31:0] pattern_in;
    wire [31:0] cache_data_out;
    reg wr_en, cache_rd_en;

    sram_2kx16 row_mem(
        .dout(cache_data_out), //output [31:0] dout
        .clk(clk), //input clk
        .oce(cache_rd_en), //input oce
        .ce(1'b1), //input ce
        .reset(~reset_n), //input reset
        .wre(wr_en), //input wre
        .ad(col_counter[10:1]), //input [9:0] ad
        .din(pattern_in) //input [31:0] din
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            row_counter <= `WRAP_SIM(#1) 'd0;
            col_counter <= `WRAP_SIM(#1) 'd0;
            write_cyc_counter <= `WRAP_SIM(#1) 'd0;
            frame_addr <= `WRAP_SIM(#1) 'd0;
            write_data <= `WRAP_SIM(#1) 'd0;
            write_addr <= `WRAP_SIM(#1) 'd0;
            upload_done <= `WRAP_SIM(#1) 1'b0;
            rd_en <= `WRAP_SIM(#1) 1'b0;
            write_rq <= `WRAP_SIM(#1) 1'b0;
            mem_wr_en <= `WRAP_SIM(#1) 1'b0;
            frame_counter <= `WRAP_SIM(#1) 'd0;
            pattern_initialized <= `WRAP_SIM(#1) 1'b0;
            wr_en <= `WRAP_SIM(#1) 1'b0;
            cache_rd_en <= `WRAP_SIM(#1) 1'b0;

            state <= `WRAP_SIM(#1) FRAME_PROCESSING_START_WAIT;
        end else begin
            case (state)
                FRAME_PROCESSING_START_WAIT: begin
                    upload_done <= `WRAP_SIM(#1) 1'b0;

                    if (start) begin
                        frame_addr <= `WRAP_SIM(#1) base_addr;
                        
                        if (pattern_initialized) begin
                            row_counter <= `WRAP_SIM(#1) 'd0;

                            state <= `WRAP_SIM(#1) CHECK_QUEUE;
                        end else begin
                            pattern_in[15:0] <= `WRAP_SIM(#1) get_pixel_color('d0);
                            pattern_in[31:16] <= `WRAP_SIM(#1) get_pixel_color('d1);
                    wr_en <= `WRAP_SIM(#1) 1'b1;
                    col_counter <= `WRAP_SIM(#1) 'd0;

                            state <= `WRAP_SIM(#1) INITIALIZE_PATTERN;
                        end
                    end
                end
                CHECK_QUEUE: begin
                    if (row_counter === FRAME_HEIGHT)
                        state <= `WRAP_SIM(#1) FRAME_PROCESSING_DONE;
                    else
                        state <= `WRAP_SIM(#1) FRAME_WRITE_ROW_START;
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
                    if (write_cyc_counter === 'd8) begin
                        logic [21:0] tmp;

                        tmp = frame_addr + 'd16;
                        frame_addr <= `WRAP_SIM(#1) tmp[20:0];

                        state <= `WRAP_SIM(#1) FRAME_PROCESSING_WRITE_CYC;
                    end else if (write_cyc_counter === 'd0) begin
                        mem_wr_en <= `WRAP_SIM(#1) 1'b1;
                        write_addr <= `WRAP_SIM(#1) frame_addr;
                        write_cyc_counter <= `WRAP_SIM(#1) write_cyc_counter + 1'b1;
                        write_data <= `WRAP_SIM(#1) {
                            cache_data_out
                        };

                        if (col_counter !== FRAME_WIDTH) begin
                            logic [11:0] tmp;

                            tmp = col_counter + 'd2;
                            col_counter <= `WRAP_SIM(#1) tmp[10:0];
                        end
                    end else begin
                        mem_wr_en <= `WRAP_SIM(#1) 1'b0;
                        write_cyc_counter <= `WRAP_SIM(#1) write_cyc_counter + 1'b1;
                        write_data <= `WRAP_SIM(#1) {
                            cache_data_out
                        };

                        if (col_counter !== FRAME_WIDTH) begin
                            logic [11:0] tmp;

                            tmp = col_counter + 'd2;
                            col_counter <= `WRAP_SIM(#1) tmp[10:0];
                        end
                    end
                end
                FRAME_PROCESSING_WRITE_CYC: begin
                    if (write_cyc_counter === TCMD) begin
                        write_rq <= `WRAP_SIM(#1) 1'b0;

                        if (col_counter === FRAME_WIDTH) begin
                            row_counter <= `WRAP_SIM(#1) row_counter + 1'b1;

                            state <= `WRAP_SIM(#1) CHECK_QUEUE;
                        end else if (write_ack == 1'b0)
                            state <= `WRAP_SIM(#1) WRITE_MEMORY_WAIT;
                    end else
                        write_cyc_counter <= `WRAP_SIM(#1) write_cyc_counter + 1'b1;
                end
                INITIALIZE_PATTERN: begin
                    cache_rd_en <= `WRAP_SIM(#1) 1'b1;
                    state <= `WRAP_SIM(#1) GENERATE_PATTERN;
                end
                GENERATE_PATTERN: begin
                    if (col_counter === FRAME_WIDTH) begin
                        pattern_initialized <= `WRAP_SIM(#1) 1'b1;
                        row_counter <= `WRAP_SIM(#1) 'd0;
                        wr_en <= `WRAP_SIM(#1) 1'b0;
                        cache_rd_en <= `WRAP_SIM(#1) 1'b1;

                        state <= `WRAP_SIM(#1) CHECK_QUEUE;
                    end else begin
                        logic [11:0] tmp;

                        pattern_in[15:0] <= `WRAP_SIM(#1) get_pixel_color(col_counter);
                        pattern_in[31:16] <= `WRAP_SIM(#1) get_pixel_color(col_counter + 1'b1);

                        tmp = col_counter + 'd2;
                        col_counter <= `WRAP_SIM(#1) tmp[10:0];
                    end
                end
            endcase
        end
    end

endmodule
