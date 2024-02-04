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

package FrameDownloaderTypes;
    typedef enum bit[7:0] {
        FRAME_PROCESSING_START_WAIT      = 8'd01,
        FRAME_PROCESSING_READ_CYC        = 8'd02,
        FRAME_PROCESSING_DONE            = 8'd03,
        CHECK_QUEUE                      = 8'd04,
        START_READ_CYC                   = 8'd05,
        START_READ_ROW                   = 8'd07,
        READ_ROW_CYC                     = 8'd08,
        START_READ_FROM_MEMORY           = 8'd09,
        READ_FROM_MEMORY_CYC             = 8'd10,
        READ_MEMORY_WAIT                 = 8'd11,
        QUEUE_UPLOAD_CYC                 = 8'd12,
        QUEUE_UPLOAD_DONE                = 8'd13,
        ADJUST_ROW_ADDRESS               = 8'd14,
        CACHE_COUNTER_INCREMENT          = 8'd15,
        SKIP_ROW                         = 8'd16
    } t_state;
endpackage

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
        parameter ORIG_FRAME_HEIGHT = 480,
        parameter ENABLE_RESIZE = 0
    )
    (
        input clk,
        input reset_n,
        input start,
        input queue_full,
        input read_ack,
        input [20:0] base_addr,
        input reg [31:0] read_data,
        input rd_data_valid,
        
        output [16:0] queue_data_o,
        output reg wr_en,
        output reg read_rq,
        output [20:0] read_addr,
        output reg mem_rd_en,
        output reg download_done
    );

    import FrameDownloaderTypes::*;
    import PSRAM_Utilities::*;

    localparam CACHE_SIZE = MEMORY_BURST / 2;
    localparam BURST_CYCLES = burst_cycles(MEMORY_BURST);
    localparam real ASPECT_RATIO = real'(ORIG_FRAME_WIDTH) / real'(ORIG_FRAME_HEIGHT);
    localparam RESIZED_WIDTH = integer'(FRAME_HEIGHT * ASPECT_RATIO);

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    t_state state;

    reg [20:0] frame_addr_counter;
    reg [4:0] cache_addr;
    reg [10:0] frame_addr_inc;
    reg [4:0] cache_addr_next;
    reg [4:0] read_counter;
    reg [4:0] read_counter_next;
    reg [5:0] cmd_cyc_counter;
    //reg cache_in_en;
    reg cache_out_en;
    reg frame_download_cycle;
    reg adder_ce;

    reg [10:0] col_counter;
    reg [10:0] row_counter;
    reg [1:0] column_increment;

    reg [16:0] queue_data;

    wire [31:0] mem_word;
    wire [21:0] adder_out;
    wire [15:0] cache_out;

    assign cache_addr_next = cache_addr + 1'b1;
    assign read_addr = frame_addr_counter;
    assign read_counter_next = read_counter + 1'b1;

    assign mem_word = read_data;

    assign `WRAP_SIM(#1) queue_data_o = (state == QUEUE_UPLOAD_CYC || 
                                         state == QUEUE_UPLOAD_DONE ||
                                         state == CACHE_COUNTER_INCREMENT) ? 
                                        cache_out : queue_data;

    Gowin_ALU54 frame_addr_adder(
        .dout(adder_out), //output [21:0] dout
        .caso(), //output [54:0] caso
        .a(frame_addr_counter), //input [20:0] a
        .b(frame_addr_inc),
        .ce(adder_ce), //input ce
        .clk(clk), //input clk
        .reset(~reset_n) //input reset
    );

    Gowin_SDPB_DN download_cache(
        .dout(cache_out), 
        .clka(clk), 
        .cea(rd_data_valid), 
        .reseta(~reset_n), 
        .clkb(clk), 
        .ceb(cache_out_en), 
        .resetb(~reset_n), 
        .oce(1'b0), 
        .ada(read_counter[2:0]), 
        .din(mem_word), 
        .adb(cache_addr[3:0])
    );

    initial begin
        read_rq <= `WRAP_SIM(#1) 1'b0;
        mem_rd_en <= `WRAP_SIM(#1) 1'b0;
        download_done <= `WRAP_SIM(#1) 1'b0;
        wr_en <= `WRAP_SIM(#1) 1'b0;
    end

    initial begin
        frame_addr_counter <= `WRAP_SIM(#1) 'd0;
        queue_data <= `WRAP_SIM(#1) 'd0;

        col_counter <= `WRAP_SIM(#1) 'd0;
        row_counter <= `WRAP_SIM(#1) 'd0;
    end

    reg [1:0] row_inc;
    wire [1:0] row_inc_o;
    reg [1:0] col_inc;
    wire [1:0] col_inc_o;

    PositionScaler_vert position_scaler_vert(
        .source_position(row_counter), 
        .position_increment(row_inc_o)
    );
    PositionScaler_horz position_scaler_horz(
        .source_position(col_counter), 
        .position_increment(col_inc_o)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cmd_cyc_counter <= `WRAP_SIM(#1) 'd0;
            queue_data <= `WRAP_SIM(#1) 'd0;
            read_rq <= `WRAP_SIM(#1) 1'b0;

            col_counter <= `WRAP_SIM(#1) 'd0;
            row_counter <= `WRAP_SIM(#1) 'd0;

            state <= `WRAP_SIM(#1) FRAME_PROCESSING_START_WAIT;
            adder_ce <= `WRAP_SIM(#1) 1'b0;
            read_counter <= `WRAP_SIM(#1) 'd0;
            cache_addr <= `WRAP_SIM(#1) 'd0;
            frame_addr_inc <= `WRAP_SIM(#1) 'd0;
            frame_download_cycle <= `WRAP_SIM(#1) 1'b0;

            download_done <= `WRAP_SIM(#1) 1'b0;
            cache_out_en <= `WRAP_SIM(#1) 1'b0;
            row_inc <= `WRAP_SIM(#1) 'd0;
            col_inc <= `WRAP_SIM(#1) 'd0;
        end else begin
            // State Machine:
            case (state)
                FRAME_PROCESSING_START_WAIT: begin
                    frame_addr_counter <= `WRAP_SIM(#1) base_addr;
                    download_done <= `WRAP_SIM(#1) 1'b0;

                    if (start == 1'b1) begin
`ifdef __ICARUS__
                        string str_msg;
`endif

                        state <= `WRAP_SIM(#1) FRAME_PROCESSING_READ_CYC;
                        frame_download_cycle <= `WRAP_SIM(#1) 1'b0;
                        frame_addr_inc <= `WRAP_SIM(#1) 'd0;

                        adder_ce <= `WRAP_SIM(#1) 1'b1;
                        row_counter <= `WRAP_SIM(#1) 'd0;
 
`ifdef __ICARUS__
                        $sformat(str_msg, "Start frame downloading at memory addr %0h", base_addr);
                        logger.info(module_name, str_msg);
`endif
                    end
                end
                FRAME_PROCESSING_READ_CYC: begin
                    wr_en <= `WRAP_SIM(#1) 1'b0;
                    adder_ce <= `WRAP_SIM(#1) 1'b0;

                    if (row_counter === FRAME_HEIGHT) begin
`ifdef __ICARUS__
                        string str_msg;
`endif

                        state <= `WRAP_SIM(#1) FRAME_PROCESSING_DONE;

`ifdef __ICARUS__
                        $sformat(str_msg, "Received %0d pixels for frame at address %0h", 
                                 FRAME_HEIGHT * FRAME_WIDTH, base_addr);
                        logger.debug(module_name, str_msg);
`endif
                    end else begin
                        cache_addr <= `WRAP_SIM(#1) 'd0;
                        state <= `WRAP_SIM(#1) CHECK_QUEUE;

                        if (frame_download_cycle)
                            frame_addr_counter <= `WRAP_SIM(#1) adder_out[20:0];
                    end
                end
                CHECK_QUEUE: 
                    if (!queue_full) begin
                        if (!frame_download_cycle) begin
                            state <= `WRAP_SIM(#1) START_READ_CYC;
                            queue_data <= `WRAP_SIM(#1) 17'h10000;
                            wr_en <= `WRAP_SIM(#1) 1'b1;

                            frame_download_cycle <= `WRAP_SIM(#1) 1'b1;
                            col_counter <= `WRAP_SIM(#1) 'd0;
                        end else begin
`ifdef __ICARUS__
                            logger.critical(module_name, "Inconsisted state in CHECK_QUEUE");
`endif
                        end
                    end
                START_READ_CYC: begin
                    adder_ce <= `WRAP_SIM(#1) 1'b0;
                    wr_en <= `WRAP_SIM(#1) 1'b0;
                    frame_addr_inc <= `WRAP_SIM(#1) 'd0;

                    state <= `WRAP_SIM(#1) START_READ_ROW;
                end
                START_READ_ROW: begin
                    if (row_counter === FRAME_HEIGHT) begin
                        if (!queue_full) begin
`ifdef __ICARUS__
                            logger.info(module_name, "Finalized frame downloading");
`endif                        
                            
                            queue_data <= `WRAP_SIM(#1) 17'h1FFFF;
                            wr_en <= `WRAP_SIM(#1) 1'b1;
                            state <= `WRAP_SIM(#1) FRAME_PROCESSING_READ_CYC;
                        end
                    end else if (!queue_full) begin
                        queue_data <= `WRAP_SIM(#1) 17'h10001;
                        wr_en <= `WRAP_SIM(#1) 1'b1;
                        col_counter <= `WRAP_SIM(#1) 'd0;

                        state <= `WRAP_SIM(#1) READ_ROW_CYC;
                    end
                end
                READ_ROW_CYC: begin
                    wr_en <= `WRAP_SIM(#1) 1'b0;
                    if (col_counter !== FRAME_WIDTH) begin
                        adder_ce <= `WRAP_SIM(#1) 1'b0;
                        state <= `WRAP_SIM(#1) START_READ_FROM_MEMORY;
                    end else begin
                        row_inc <= `WRAP_SIM(#1) row_inc_o;
                        row_counter <= `WRAP_SIM(#1) row_counter + 1'b1;
                        frame_addr_inc <= `WRAP_SIM(#1) ORIG_FRAME_WIDTH - FRAME_WIDTH;
                        adder_ce <= `WRAP_SIM(#1) 1'b1;
                        state <= `WRAP_SIM(#1) ADJUST_ROW_ADDRESS;
                    end
                end
                START_READ_FROM_MEMORY: begin
                    read_rq <= `WRAP_SIM(#1) 1'b1;
                    state <= `WRAP_SIM(#1) READ_MEMORY_WAIT;
                end
                READ_MEMORY_WAIT: begin
                    if (read_ack) begin
                        state <= `WRAP_SIM(#1) READ_FROM_MEMORY_CYC;
                        mem_rd_en <= `WRAP_SIM(#1) 1'b1;
                        read_counter <= `WRAP_SIM(#1) 'd0;
                        frame_addr_counter <= `WRAP_SIM(#1) adder_out[20:0];
                    end
                end
                READ_FROM_MEMORY_CYC: begin
                    mem_rd_en <= `WRAP_SIM(#1) 1'b0;
                    if (rd_data_valid && read_counter !== BURST_CYCLES)
                        read_counter <= `WRAP_SIM(#1) read_counter_next;
                    else if (read_counter === BURST_CYCLES) begin
                        state <= `WRAP_SIM(#1) QUEUE_UPLOAD_CYC;
                        col_inc <= `WRAP_SIM(#1) col_inc_o;
                        cache_addr <= `WRAP_SIM(#1) 'd0;
                        cache_out_en <= `WRAP_SIM(#1) 1'b1;
                        read_rq <= `WRAP_SIM(#1) 1'b0;
                    end
                end
                QUEUE_UPLOAD_CYC: begin
                    if (queue_full)
                        ; // Do nothing
                    else if (col_counter !== FRAME_WIDTH && cache_addr !== CACHE_SIZE) begin
                        wr_en <= `WRAP_SIM(#1) 1'b1;
                            
                        state <= `WRAP_SIM(#1) CACHE_COUNTER_INCREMENT;
                    end else begin
                        wr_en <= `WRAP_SIM(#1) 1'b0;
                        state <= `WRAP_SIM(#1) QUEUE_UPLOAD_DONE;
                    end
                end
                CACHE_COUNTER_INCREMENT: begin
                    wr_en <= `WRAP_SIM(#1) 1'b0;
                    col_counter <= `WRAP_SIM(#1) col_counter + 1'b1;
                    cache_addr <= `WRAP_SIM(#1) cache_addr_next;
                    
                    state <= `WRAP_SIM(#1) QUEUE_UPLOAD_CYC;
                end
                QUEUE_UPLOAD_DONE: begin
                    wr_en <= `WRAP_SIM(#1) 1'b0;
                    cache_out_en <= `WRAP_SIM(#1) 1'b0;
                    frame_addr_inc <= `WRAP_SIM(#1) cache_addr;
                    adder_ce <= `WRAP_SIM(#1) 1'b1;

                    state <= `WRAP_SIM(#1) READ_ROW_CYC;
                end
                ADJUST_ROW_ADDRESS: begin
                    if (ENABLE_RESIZE) begin
                        if (row_inc === 'd1) begin
                            frame_addr_counter <= `WRAP_SIM(#1) adder_out[20:0];

                            state <= `WRAP_SIM(#1) START_READ_CYC;
                        end else if (row_inc === 'd0)
                            state <= `WRAP_SIM(#1) START_READ_CYC;
                        else begin
                            frame_addr_counter <= `WRAP_SIM(#1) adder_out[20:0];

                            state <= `WRAP_SIM(#1) SKIP_ROW;
                        end
                    end else begin
                        frame_addr_counter <= `WRAP_SIM(#1) adder_out[20:0];

                        state <= `WRAP_SIM(#1) START_READ_CYC;
                    end
                end
                SKIP_ROW: begin
                    if (row_inc === 'd1)
                        state <= `WRAP_SIM(#1) START_READ_CYC;
                    else begin
                        logic [21:0] tmp;

                        tmp = frame_addr_counter + ORIG_FRAME_WIDTH;
                        frame_addr_counter <= `WRAP_SIM(#1) tmp[20:0];
                        row_inc <= `WRAP_SIM(#1) row_inc - 1'b1;
                    end
                end
                FRAME_PROCESSING_DONE: begin
                    download_done <= `WRAP_SIM(#1) 1'b1;
                    state <= `WRAP_SIM(#1) FRAME_PROCESSING_START_WAIT;
                end
            endcase
        end
    end
endmodule
