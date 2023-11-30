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
        FRAME_PROCESSING_START_WAIT = 8'b00000001, 
        CHECK_QUEUE                 = 8'b00000010, 
        FRAME_PROCESSING_DONE       = 8'b00000100, 
        FRAME_PROCESSING_WRITE_CYC  = 8'b00001000, 
        READ_QUEUE_DATA             = 8'b00010000, 
        WAIT_TRANSACTION_COMPLETE   = 8'b00100000, 
        WRITE_MEMORY                = 8'b01000000, 
        WRITE_MEMORY_WAIT           = 8'b10000000
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
    
    wire [31:0] mem_word;
    wire [21:0] adder_out;

    assign cache_addr_next = cache_addr + 1'b1;
    assign write_addr = frame_addr_counter;
    assign write_counter_next = write_counter + 1'b1;

    Gowin_ALU54 frame_addr_adder(
        .dout(adder_out), //output [21:0] dout
        .caso(), //output [54:0] caso
        .a(frame_addr_counter), //input [20:0] a
        .b(frame_addr_inc), //input [4:0] b
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

    initial begin
        frame_addr_counter <= `WRAP_SIM(#1) 'd0;
        cmd_cyc_counter <= `WRAP_SIM(#1) 'd0;
        write_counter <= `WRAP_SIM(#1) 'd0;
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            cmd_cyc_counter <= `WRAP_SIM(#1) 'd0;
        else begin
            case (state)
                WRITE_MEMORY_WAIT:
                    cmd_cyc_counter <= `WRAP_SIM(#1) 'd0;
                WRITE_MEMORY:
                    if (write_counter >= 'd2)
                        cmd_cyc_counter <= `WRAP_SIM(#1) cmd_cyc_counter + 1'b1;
                WAIT_TRANSACTION_COMPLETE:
                    if (cmd_cyc_counter === TCMD)
                        cmd_cyc_counter <= `WRAP_SIM(#1) 'd0;
                    else
                        cmd_cyc_counter <= `WRAP_SIM(#1) cmd_cyc_counter + 1'b1;
            endcase
        end
    end

    always @(posedge clk or negedge reset_n) begin: p_states
        if (reset_n == 1'b0) begin
            state <= `WRAP_SIM(#1) FRAME_PROCESSING_START_WAIT;
            frame_addr_counter <= `WRAP_SIM(#1) 'd0;
            write_data <= `WRAP_SIM(#1) 'd0;
            frame_upload_cycle <= `WRAP_SIM(#1) 1'b0;
            frame_addr_inc <= `WRAP_SIM(#1) 'd0;
        end else begin
            // State Machine:
            case (state)
                FRAME_PROCESSING_START_WAIT: begin
                    frame_addr_counter <= `WRAP_SIM(#1) base_addr;
                    if (start == 1'b1) begin
`ifdef __ICARUS__
                        string str_msg;
`endif

                        pixel_counter <= `WRAP_SIM(#1) 'd0;
                        state <= `WRAP_SIM(#1) FRAME_PROCESSING_WRITE_CYC;
                        frame_upload_cycle <= `WRAP_SIM(#1) 1'b0;
                        frame_addr_inc <= `WRAP_SIM(#1) 'd0;
 
`ifdef __ICARUS__
                        $sformat(str_msg, "Start frame uploading at memory addr %0h", base_addr);
                        logger.info(module_name, str_msg);
`endif
                   end
                end
                FRAME_PROCESSING_DONE: begin
                    state <= `WRAP_SIM(#1) FRAME_PROCESSING_START_WAIT;
                    frame_upload_cycle <= `WRAP_SIM(#1) 1'b0;

`ifdef __ICARUS__
                    logger.info(module_name, "Frame uploading finished");
`endif
                end
                FRAME_PROCESSING_WRITE_CYC: begin
                    if (pixel_counter === FRAME_PIXELS_NUM) begin
`ifdef __ICARUS__
                        string str_msg;
`endif

                        state <= `WRAP_SIM(#1) FRAME_PROCESSING_DONE;

`ifdef __ICARUS__
                        $sformat(str_msg, "Received %0d pixels for frame at address %0h", FRAME_PIXELS_NUM, base_addr);
                        logger.debug(module_name, str_msg);
`endif
                    end else begin
                        cache_addr <= `WRAP_SIM(#1) 'd0;
                        state <= `WRAP_SIM(#1) CHECK_QUEUE;

                        if (frame_upload_cycle)
                            frame_addr_counter <= `WRAP_SIM(#1) adder_out[20:0];
                    end
                end
                CHECK_QUEUE: begin
                    if (queue_empty == 1'b0) begin
                        state <= `WRAP_SIM(#1) READ_QUEUE_DATA;
                    end
                end
                READ_QUEUE_DATA: begin
                    if (!rd_en) begin
                        // Do nothing and wait until rd_en signal will be holded on
                    end else if (!queue_empty && queue_data === 17'h10000) begin
                        if (!frame_upload_cycle) begin
                            frame_upload_cycle <= `WRAP_SIM(#1) 1'b1;
`ifdef __ICARUS__
                            logger.info(module_name, "Start frame upload cycle");
`endif
                        end else begin
                            state <= `WRAP_SIM(#1) FRAME_PROCESSING_DONE;

`ifdef __ICARUS__
                            logger.warning(module_name, "Unexpected frame start command received");
`endif
                        end
                        frame_addr_inc <= `WRAP_SIM(#1) 'd0;
                    end else if (queue_empty == 1'b1 || cache_addr_next === CACHE_SIZE) begin
                        if (cache_addr !== 'd0) begin
                            state <= `WRAP_SIM(#1) WRITE_MEMORY_WAIT;
                            if (queue_empty == 1'b1) begin
                                frame_addr_inc <= `WRAP_SIM(#1) cache_addr;
                            end else begin
                                frame_addr_inc <= `WRAP_SIM(#1) cache_addr_next;
                            end
                        end
                    end else if (!queue_empty) begin
                        cache_addr <= `WRAP_SIM(#1) cache_addr_next;
                    end
                end
                WRITE_MEMORY_WAIT: begin
                    if (write_ack == 1'b1) begin
                        pixel_counter <= `WRAP_SIM(#1) pixel_counter + frame_addr_inc;

                        write_counter <= `WRAP_SIM(#1) 'd0;
                        state <= `WRAP_SIM(#1) WRITE_MEMORY;
                    end
                end
                WRITE_MEMORY: begin
                    if (write_counter === BURST_CYCLES + 'd1)
                        state <= `WRAP_SIM(#1) WAIT_TRANSACTION_COMPLETE;
                    else begin
                        write_data <= `WRAP_SIM(#1) mem_word;
                        write_counter <= `WRAP_SIM(#1) write_counter_next;
                    end
                end
                WAIT_TRANSACTION_COMPLETE:
                    if (cmd_cyc_counter === TCMD)
                        state <= `WRAP_SIM(#1) FRAME_PROCESSING_WRITE_CYC;
            endcase
        end
    end

    initial begin
        cache_in_en <= `WRAP_SIM(#1) 1'b0;
        cache_out_en <= `WRAP_SIM(#1) 1'b0;
    end

    initial
        upload_done <= `WRAP_SIM(#1) 1'b0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            upload_done <= `WRAP_SIM(#1) 1'b0;
        else if (state == FRAME_PROCESSING_DONE)
            upload_done <= `WRAP_SIM(#1) 1'b1;
        else
            upload_done <= `WRAP_SIM(#1) 1'b0;
    end

    initial
        write_rq <= `WRAP_SIM(#1) 1'b0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            write_rq <= `WRAP_SIM(#1) 1'b0;
        else if (state == WRITE_MEMORY || state == WRITE_MEMORY_WAIT || state == WAIT_TRANSACTION_COMPLETE)
            write_rq <= `WRAP_SIM(#1) 1'b1;
        else
            write_rq <= `WRAP_SIM(#1) 1'b0;
    end

    initial
        adder_ce <= `WRAP_SIM(#1) 1'b0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            adder_ce <= `WRAP_SIM(#1) 1'b0;
        else if (state == FRAME_PROCESSING_START_WAIT || state == WAIT_TRANSACTION_COMPLETE)
            adder_ce <= `WRAP_SIM(#1) 1'b1;
        else
            adder_ce <= `WRAP_SIM(#1) 1'b0;
    end

    initial
        mem_wr_en <= `WRAP_SIM(#1) 1'b0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            mem_wr_en <= `WRAP_SIM(#1) 1'b0;
        else if (state == WRITE_MEMORY && write_counter === 'd1)
            mem_wr_en <= `WRAP_SIM(#1) 1'b1;
        else
            mem_wr_en <= `WRAP_SIM(#1) 1'b0;
    end

    initial
        rd_en <= `WRAP_SIM(#1) 1'b0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            rd_en <= `WRAP_SIM(#1) 1'b0;
        else if (state == READ_QUEUE_DATA && 
                 cache_addr_next !== CACHE_SIZE &&
                 !queue_empty) begin
            rd_en <= `WRAP_SIM(#1) 1'b1;
        end else
            rd_en <= `WRAP_SIM(#1) 1'b0;
    end

    always @(*) begin
        // Default State Actions:
        cache_in_en = 1'b0;
        cache_out_en = 1'b0;

        // State Actions:
        case (state)
            READ_QUEUE_DATA:
                if (!queue_empty && cache_addr !== CACHE_SIZE) begin
                    cache_in_en = 1'b1;
                end
            WRITE_MEMORY:
                cache_out_en = 1'b1;
        endcase
    end
endmodule
