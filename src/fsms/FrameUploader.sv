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

package FrameUploaderTypes;
    typedef enum bit[7:0] {
        IDLE                        = 8'd0,
        FRAME_PROCESSING_START_WAIT = 8'd1, 
        WAIT_START_ROW              = 8'd2, 
        FRAME_PROCESSING_DONE       = 8'd3, 
        FRAME_PROCESSING_WRITE_CYC  = 8'd4, 
        READ_QUEUE_DATA             = 8'd5, 
        WAIT_TRANSACTION_COMPLETE   = 8'd6, 
        WRITE_MEMORY                = 8'd7, 
        WRITE_MEMORY_WAIT           = 8'd8
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

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    localparam CACHE_SIZE = MEMORY_BURST / 2;
    localparam BURST_CYCLES = MEMORY_BURST / 4;
    localparam FRAME_PIXELS_NUM = FRAME_WIDTH * FRAME_HEIGHT;
    localparam TCMD = 19;


    t_state state;
    //reg [15:0] upload_cache[MEMORY_BURST / 2];
    reg [20:0] frame_addr_counter;
    reg [4:0] cache_addr;
    reg [4:0] frame_addr_inc;
    reg [4:0] cache_addr_next;
    reg [4:0] write_counter;
    reg [4:0] write_counter_next;
    reg [5:0] cmd_cyc_counter;
    reg [20:0] pixel_counter;
    reg cache_in_en;
    reg cache_out_en;
    reg frame_upload_cycle;
    reg adder_ce;

    reg [10:0] row_counter;
    reg [10:0] col_counter;
    
    wire [31:0] mem_word;
    wire [21:0] adder_out;

    assign cache_addr_next = cache_addr + 1'b1;
    assign write_addr = frame_addr_counter;
    assign write_counter_next = write_counter + 1'b1;

    Gowin_ALU54 frame_addr_adder(
        .dout(adder_out), //output [21:0] dout
        .caso(), //output [54:0] caso
        .a(frame_addr_counter), //input [20:0] a
        .b({6'd0, frame_addr_inc}), //input [4:0] b
        .ce(adder_ce), //input ce
        .clk(clk), //input clk
        .reset(~reset_n) //input reset
    );

    Cache_SDPB upload_cache(
        .dout(mem_word), 
        .clka(clk), 
        .cea(cache_in_en), 
        .reseta(~reset_n), 
        .clkb(clk), 
        .ceb(cache_out_en), 
        .resetb(~reset_n), 
        .oce(1'b0), 
        .ada(cache_addr[3:0]), 
        .din(queue_data[15:0]), 
        .adb(write_counter[2:0])
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= `WRAP_SIM(#1) IDLE;
            rd_en <= `WRAP_SIM(#1) 1'b0;

            row_counter <= `WRAP_SIM(#1) 'd0;
            col_counter <= `WRAP_SIM(#1) 'd0;

            frame_addr_counter <= `WRAP_SIM(#1) 'd0;
            adder_ce <= `WRAP_SIM(#1) 1'b0;
            cache_in_en <= `WRAP_SIM(#1) 1'b0;
            cache_out_en <= `WRAP_SIM(#1) 1'b0;

            cache_addr <= `WRAP_SIM(#1) 'd0;
            write_rq <= `WRAP_SIM(#1) 1'b0;
            mem_wr_en <= `WRAP_SIM(#1) 1'b0;
            write_data <= `WRAP_SIM(#1) 'd0;
            write_counter <= `WRAP_SIM(#1) 'd0;
            frame_addr_inc <= `WRAP_SIM(#1) 'd0;
            cmd_cyc_counter <= `WRAP_SIM(#1) 'd0;
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        rd_en <= `WRAP_SIM(#1) 1'b1;
                        frame_addr_counter <= `WRAP_SIM(#1) base_addr;
                        adder_ce <= `WRAP_SIM(#1) 1'b1;

                        state <= `WRAP_SIM(#1) FRAME_PROCESSING_START_WAIT;
                    end else
                        rd_en <= `WRAP_SIM(#1) 1'b0;
                end
                FRAME_PROCESSING_START_WAIT: begin
                    adder_ce <= `WRAP_SIM(#1) 1'b0;

                    if (queue_empty)
                        ; // Do nothing
                    else if (queue_data === 17'h10000) begin
                        row_counter <= `WRAP_SIM(#1) 'd0;
                        state <= `WRAP_SIM(#1) WAIT_START_ROW;
                    end
                end
                WAIT_START_ROW: begin
                    if (queue_empty)
                        ; // Do nothing
                    else if (queue_data === 17'h10001) begin
                        cache_addr <= `WRAP_SIM(#1) 'd0;
                        col_counter <= `WRAP_SIM(#1) 'd0;
                        cache_in_en <= `WRAP_SIM(#1) 1'b1;

                        state <= `WRAP_SIM(#1) READ_QUEUE_DATA;
                    end
                end
                READ_QUEUE_DATA: begin
                    if (queue_empty && cache_addr !== 'd0) begin
                        cache_in_en <= `WRAP_SIM(#1) 1'b0;
                        rd_en <= `WRAP_SIM(#1) 1'b0;

                        state <= `WRAP_SIM(#1) WRITE_MEMORY_WAIT;
                    end else if (queue_empty) begin
                        // Do nothing
                    end else begin
                        if (cache_addr_next === 'd16) begin
                            cache_in_en <= `WRAP_SIM(#1) 1'b0;
                            rd_en <= `WRAP_SIM(#1) 1'b0;

                            state <= `WRAP_SIM(#1) WRITE_MEMORY_WAIT;
                        end else begin
                            cache_addr <= `WRAP_SIM(#1) cache_addr_next;
                        end
                    end
                end
                WRITE_MEMORY_WAIT: begin
                    write_rq <= `WRAP_SIM(#1) 1'b1;
                    if (write_ack) begin
                        write_counter <= `WRAP_SIM(#1) 'd0;
                        cmd_cyc_counter <= `WRAP_SIM(#1) 'd0;
                        cache_out_en <= `WRAP_SIM(#1) 1'b1;

                        state <= `WRAP_SIM(#1) WRITE_MEMORY;
                    end
                end
                WRITE_MEMORY: begin
                end
            endcase
        end
    end
endmodule
