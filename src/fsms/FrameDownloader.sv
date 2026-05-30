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
        S_START_WAIT  = 8'd01,   // wait for frame `start`, seed the prefetch cache
        S_FRAME_START = 8'd02,   // emit frame-start token
        S_ROW_WAIT    = 8'd03,   // wait for the next prefetched row (or finish)
        S_ROW_START   = 8'd04,   // emit row-start token
        S_DRAIN_W1    = 8'd05,   // BRAM read latency cycle 1
        S_DRAIN_W2    = 8'd06,   // BRAM read latency cycle 2
        S_DRAIN_PUSH  = 8'd07,   // push one pixel to the queue (honours back-pressure)
        S_ROW_END     = 8'd08,   // release the drained bank
        S_ROW_GAP     = 8'd09,   // let the release register-update settle
        S_FRAME_END   = 8'd10,   // emit frame-end token
        S_DONE        = 8'd11    // pulse download_done
    } t_state;
endpackage

// FrameDownloader streams a frame out of PSRAM to the store interface
// (HorizontalResizer -> FIFO -> LCD). The PSRAM read path, the two ping-pong
// row banks and the source-row addressing (including the vertical-resize DDA)
// live in DownloadRowCache; this FSM is a pure sequencer + drain:
//
//   * on `start` it seeds the cache with base_addr and emits the frame-start
//     token, then for each of FRAME_HEIGHT output rows it waits for a prefetched
//     row, emits a row-start token and drains FRAME_WIDTH pixels to the queue,
//   * then emits the frame-end token and pulses download_done.
//
// The emitted token + pixel stream is identical to the previous (serial) design;
// only the PSRAM-read/drain timing changes (reads of the next row overlap the
// drain of the current one). External port list is unchanged: read_rq/read_addr/
// mem_rd_en are now driven straight from the cache.

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

        output reg [16:0] queue_data_o,
        output reg wr_en,
        output read_rq,
        output [20:0] read_addr,
        output mem_rd_en,
        output reg download_done
    );

    import FrameDownloaderTypes::*;

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    localparam [16:0] TOKEN_FRAME_START = 17'h10000;
    localparam [16:0] TOKEN_ROW_START   = 17'h10001;
    localparam [16:0] TOKEN_FRAME_END   = 17'h1FFFF;

    t_state state;

    reg [10:0] col_counter;   // pixels drained in the current row (0..FRAME_WIDTH)
    reg [10:0] row_counter;   // output rows emitted (0..FRAME_HEIGHT)

    // ---- prefetch cache interface ----
    reg        cache_start;   // 1-cycle pulse to (re)seed the cache for a frame
    reg  [9:0] rd_pix_addr;   // pixel index requested from the front bank
    reg        row_release;   // 1-cycle pulse: front bank fully drained
    wire        row_avail;    // front bank holds a complete row
    wire [15:0] rd_pix_data;  // pixel at rd_pix_addr (2-cycle latency)

    DownloadRowCache #(
        .MEMORY_BURST(MEMORY_BURST),
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT),
        .ORIG_FRAME_WIDTH(ORIG_FRAME_WIDTH),
        .ENABLE_RESIZE(ENABLE_RESIZE)
    ) row_cache (
        .clk(clk),
        .reset_n(reset_n),
        .start(cache_start),
        .base_addr(base_addr),
        // PSRAM (driven straight onto FrameDownloader's external ports)
        .read_rq(read_rq),
        .read_addr(read_addr),
        .read_ack(read_ack),
        .mem_rd_en(mem_rd_en),
        .read_data(read_data),
        .rd_data_valid(rd_data_valid),
        // drain
        .row_avail(row_avail),
        .rd_pix_addr(rd_pix_addr),
        .rd_pix_data(rd_pix_data),
        .row_release(row_release)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state         <= `WRAP_SIM(#1) S_START_WAIT;
            col_counter   <= `WRAP_SIM(#1) 'd0;
            row_counter   <= `WRAP_SIM(#1) 'd0;
            queue_data_o  <= `WRAP_SIM(#1) 'd0;
            wr_en         <= `WRAP_SIM(#1) 1'b0;
            download_done <= `WRAP_SIM(#1) 1'b0;
            cache_start   <= `WRAP_SIM(#1) 1'b0;
            rd_pix_addr   <= `WRAP_SIM(#1) 'd0;
            row_release   <= `WRAP_SIM(#1) 1'b0;
        end else begin
            // single-cycle defaults; states override as needed
            wr_en       <= `WRAP_SIM(#1) 1'b0;
            cache_start <= `WRAP_SIM(#1) 1'b0;
            row_release <= `WRAP_SIM(#1) 1'b0;

            case (state)
                S_START_WAIT: begin
                    download_done <= `WRAP_SIM(#1) 1'b0;
                    if (start) begin
`ifdef __ICARUS__
                        string str_msg;
                        $sformat(str_msg, "Start frame downloading at memory addr %0h", base_addr);
                        logger.info(module_name, str_msg);
`endif
                        cache_start <= `WRAP_SIM(#1) 1'b1;
                        row_counter <= `WRAP_SIM(#1) 'd0;
                        state       <= `WRAP_SIM(#1) S_FRAME_START;
                    end
                end
                S_FRAME_START: begin
                    if (!queue_full) begin
                        queue_data_o <= `WRAP_SIM(#1) TOKEN_FRAME_START;
                        wr_en        <= `WRAP_SIM(#1) 1'b1;
                        state        <= `WRAP_SIM(#1) S_ROW_WAIT;
                    end
                end
                S_ROW_WAIT: begin
                    if (row_counter == FRAME_HEIGHT) begin
                        state <= `WRAP_SIM(#1) S_FRAME_END;
                    end else if (row_avail) begin
                        state <= `WRAP_SIM(#1) S_ROW_START;
                    end
                end
                S_ROW_START: begin
                    if (!queue_full) begin
                        queue_data_o <= `WRAP_SIM(#1) TOKEN_ROW_START;
                        wr_en        <= `WRAP_SIM(#1) 1'b1;
                        col_counter  <= `WRAP_SIM(#1) 'd0;
                        rd_pix_addr  <= `WRAP_SIM(#1) 'd0;
                        state        <= `WRAP_SIM(#1) S_DRAIN_W1;
                    end
                end
                S_DRAIN_W1: state <= `WRAP_SIM(#1) S_DRAIN_W2;   // BRAM read latency
                S_DRAIN_W2: state <= `WRAP_SIM(#1) S_DRAIN_PUSH; // (CACHE_DELAY = 2)
                S_DRAIN_PUSH: begin
                    if (!queue_full) begin
                        queue_data_o <= `WRAP_SIM(#1) {1'b0, rd_pix_data};
                        wr_en        <= `WRAP_SIM(#1) 1'b1;
                        if (col_counter == FRAME_WIDTH - 1) begin
                            state <= `WRAP_SIM(#1) S_ROW_END;
                        end else begin
                            col_counter <= `WRAP_SIM(#1) col_counter + 1'b1;
                            rd_pix_addr <= `WRAP_SIM(#1) col_counter + 1'b1;
                            state       <= `WRAP_SIM(#1) S_DRAIN_W1;
                        end
                    end
                    // else: back-pressure -- hold rd_pix_addr, retry next cycle
                end
                S_ROW_END: begin
                    row_release <= `WRAP_SIM(#1) 1'b1;
                    row_counter <= `WRAP_SIM(#1) row_counter + 1'b1;
                    state       <= `WRAP_SIM(#1) S_ROW_GAP;
                end
                S_ROW_GAP: begin
                    // let the cache's registered front-bank swap / bank_full clear
                    // settle before S_ROW_WAIT re-samples row_avail
                    state <= `WRAP_SIM(#1) S_ROW_WAIT;
                end
                S_FRAME_END: begin
                    if (!queue_full) begin
`ifdef __ICARUS__
                        logger.info(module_name, "Finalized frame downloading");
`endif
                        queue_data_o <= `WRAP_SIM(#1) TOKEN_FRAME_END;
                        wr_en        <= `WRAP_SIM(#1) 1'b1;
                        state        <= `WRAP_SIM(#1) S_DONE;
                    end
                end
                S_DONE: begin
                    download_done <= `WRAP_SIM(#1) 1'b1;
                    state         <= `WRAP_SIM(#1) S_START_WAIT;
                end
                default: state <= `WRAP_SIM(#1) S_START_WAIT;
            endcase
        end
    end
endmodule
