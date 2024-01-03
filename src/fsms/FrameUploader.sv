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
        WRITE_MEMORY_WAIT           = 8'd8,
        UPDATE_COL_COUNTERS         = 8'd9,
        CHECK_COL_COUNTERS          = 8'd10,
        CHECK_ROW_COUNTERS          = 8'd11
    } t_state;

    typedef enum bit[1:0] {
        FILL_COMPLETE               = 'd0,
        FILL_INCOMPLETE             = 'd1
    } t_cache_complete;
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
    t_cache_complete cache_fill_type;

    //reg [15:0] upload_cache[MEMORY_BURST / 2];
    reg [20:0] frame_addr_counter;
    reg [4:0] cache_addr;
    reg [4:0] cache_addr_max;
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

    function logic[4:0] get_max_cache_load(input logic[10:0] c);
        logic[10:0] diff;

        diff = FRAME_WIDTH - c;
        if (diff > 'd16)
            get_max_cache_load = 'd16;
        else
            get_max_cache_load = diff[4:0];
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= `WRAP_SIM(#1) IDLE;
            rd_en <= `WRAP_SIM(#1) 1'b0;
            upload_done <= `WRAP_SIM(#1) 1'b0;

            row_counter <= `WRAP_SIM(#1) 'd0;
            col_counter <= `WRAP_SIM(#1) 'd0;

            frame_addr_counter <= `WRAP_SIM(#1) 'd0;
            adder_ce <= `WRAP_SIM(#1) 1'b0;
            cache_in_en <= `WRAP_SIM(#1) 1'b0;
            cache_out_en <= `WRAP_SIM(#1) 1'b0;

            cache_addr <= `WRAP_SIM(#1) 'd0;
            cache_addr_max <= `WRAP_SIM(#1) 'd0;
            write_rq <= `WRAP_SIM(#1) 1'b0;
            mem_wr_en <= `WRAP_SIM(#1) 1'b0;
            write_data <= `WRAP_SIM(#1) 'd0;
            write_counter <= `WRAP_SIM(#1) 'd0;
            frame_addr_inc <= `WRAP_SIM(#1) 'd0;
            cmd_cyc_counter <= `WRAP_SIM(#1) 'd0;

            cache_fill_type <= `WRAP_SIM(#1) FILL_INCOMPLETE;
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        //rd_en <= `WRAP_SIM(#1) 1'b1;
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
                        state <= `WRAP_SIM(#1) CHECK_ROW_COUNTERS;
                    end
                end
                CHECK_ROW_COUNTERS: begin
                    if (row_counter === FRAME_HEIGHT) begin
                    end else begin
                        rd_en <= `WRAP_SIM(#1) 1'b1;
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
                        cache_addr_max <= `WRAP_SIM(#1) 'd16;

                        state <= `WRAP_SIM(#1) READ_QUEUE_DATA;
                    end
                end
                READ_QUEUE_DATA: begin
                    if (queue_empty && cache_addr !== 'd0) begin
                        cache_in_en <= `WRAP_SIM(#1) 1'b0;
                        rd_en <= `WRAP_SIM(#1) 1'b0;
                        //if (cache_addr !== 'dF)
                            cache_fill_type <= `WRAP_SIM(#1) FILL_INCOMPLETE;
                        //else
                        //    cache_fill_type <= `WRAP_SIM(#1) FILL_COMPLETE;

                        state <= `WRAP_SIM(#1) WRITE_MEMORY_WAIT;
                    end else if (queue_empty) begin
                        // Do nothing
                    end else begin
                        if (queue_data[16] == 1'b1) begin
                            case (queue_data)
                                17'h10000: begin
`ifdef __ICARUS__
                                    logger.warning(module_name, "Received unxepected start frame");
`endif
                                end
                                17'h10001: begin
`ifdef __ICARUS__
                                    logger.warning(module_name, "Received unxepected start row");
`endif
                                end
                                17'h1FFFF: begin
`ifdef __ICARUS__
                                    logger.warning(module_name, "Received unxepected end frame");
`endif
                                end
                                default: begin
`ifdef __ICARUS__
                                    string str;
                                    $sformat(str, "Unknown command value: %0h", queue_data);
                                    logger.critical(module_name, str);
`endif
                                end
                            endcase
                        end else begin
                            if (cache_addr_next === cache_addr_max) begin
                                cache_in_en <= `WRAP_SIM(#1) 1'b0;
                                rd_en <= `WRAP_SIM(#1) 1'b0;
                                cache_fill_type <= `WRAP_SIM(#1) FILL_COMPLETE;

                                state <= `WRAP_SIM(#1) WRITE_MEMORY_WAIT;
                            end else begin
                                cache_addr <= `WRAP_SIM(#1) cache_addr_next;
                            end
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
                    write_counter <= `WRAP_SIM(#1) write_counter + 1'b1;

                    if (cmd_cyc_counter === 'd0) begin
                        mem_wr_en <= `WRAP_SIM(#1) 1'b1;
                        cmd_cyc_counter <= `WRAP_SIM(#1) cmd_cyc_counter + 1'b1;
                    end else if (cmd_cyc_counter === 'd8) begin
                        mem_wr_en <= `WRAP_SIM(#1) 1'b0;
                        cache_out_en <= `WRAP_SIM(#1) 1'b0;
                        cmd_cyc_counter <= `WRAP_SIM(#1) cmd_cyc_counter + 1'b1;

                        state <= `WRAP_SIM(#1) WAIT_TRANSACTION_COMPLETE;
                    end else begin
                        mem_wr_en <= `WRAP_SIM(#1) 1'b0;
                        cmd_cyc_counter <= `WRAP_SIM(#1) cmd_cyc_counter + 1'b1;
                    end
                end
                WAIT_TRANSACTION_COMPLETE: begin
                    if (cmd_cyc_counter === 'd19) begin
                        write_rq <= `WRAP_SIM(#1) 1'b0;
                        if (cache_fill_type == FILL_COMPLETE)
                            frame_addr_inc <= `WRAP_SIM(#1) cache_addr_next;
                        else
                            frame_addr_inc <= `WRAP_SIM(#1) cache_addr;

                        state <= `WRAP_SIM(#1) UPDATE_COL_COUNTERS;
                        adder_ce <= `WRAP_SIM(#1) 1'b1;
                    end else begin
                        cmd_cyc_counter <= `WRAP_SIM(#1) cmd_cyc_counter + 1'b1;
                    end
                end
                UPDATE_COL_COUNTERS: begin
                    col_counter <= `WRAP_SIM(#1) col_counter + frame_addr_inc;
                    adder_ce <= `WRAP_SIM(#1) 1'b0;
                    state <= `WRAP_SIM(#1) CHECK_COL_COUNTERS;
                end
                CHECK_COL_COUNTERS: begin
                    frame_addr_counter <= `WRAP_SIM(#1) adder_out[20:0];

                    if (col_counter >= FRAME_WIDTH) begin
                        row_counter <= `WRAP_SIM(#1) row_counter + 1'b1;
                        state <= `WRAP_SIM(#1) CHECK_ROW_COUNTERS;
                    end else begin
                        rd_en <= `WRAP_SIM(#1) 1'b1;
                        cache_addr <= `WRAP_SIM(#1) 'd0;
                        cache_in_en <= `WRAP_SIM(#1) 1'b1;
                        cache_addr_max <= `WRAP_SIM(#1) get_max_cache_load(col_counter);

                        state <= `WRAP_SIM(#1) READ_QUEUE_DATA;
                    end
                end
            endcase
        end
    end
endmodule
