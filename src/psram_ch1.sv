`include "timescale.v"
`include "camera_control_defs.vh"
`include "psram_utils.vh"

`default_nettype wire

// Channel-1 PSRAM access engine + bring-up loopback self-test.
//
// The video frame buffer uses PSRAM channel 0 (via the arbiter / VideoController);
// channel 1 has always been tied off. This module drives the IP's channel-1
// command pins directly (no arbiter — ch1 is exclusively ours), replicating the
// burst sequencing the proven ch0 path uses (FrameUploader writes / DownloadRow-
// Cache reads): a one-cycle cmd_en pulse with cmd/addr, then MEMORY_BURST/4 words
// streamed on a write or collected on rd_data_valid for a read.
//
// Phase B (this file): a self-test that, on a request from the sys_clk side,
// writes a known burst to ch1 and reads it back, reporting the first word and a
// match flag. Confirms channel 1 is physically usable before the frame-grab
// feature is built on top. The write/read burst FSM here is the reusable core.
//
// Clock domains: the IP side runs on fb_clk (the IP's clk_out / clk_2); the
// control/result side is sys_clk. The two are bridged with toggle handshakes.

module psram_ch1 #(
    parameter integer MEMORY_BURST = 32     // bytes per burst (8 x 32-bit words)
)
(
    // ---- PSRAM IP channel-1 pins (fb_clk domain) ----
    input  wire        fb_clk,
    input  wire        fb_rst_n,
    input  wire        calib1,              // init_calib1 from the IP (ch1 ready)
    output reg         cmd1,                // 1 = write, 0 = read
    output reg         cmd_en1,
    output reg [20:0]  addr1,
    output reg [31:0]  wr_data1,
    output reg [3:0]   data_mask1,
    input  wire [31:0] rd_data1,
    input  wire        rd_data_valid1,

    // ---- loopback self-test control (sys_clk domain) ----
    input  wire        sclk,
    input  wire        srst_n,
    input  wire        test_req,            // 1-cycle pulse: run write+read loopback
    output reg         test_busy,           // high while a test is in flight
    output reg [31:0]  test_rdata,          // read-back first word
    output reg         test_match,          // read[0] == written[0]
    output reg         test_done,           // 1-cycle pulse on completion
    output reg         test_timeout,        // FSM hit the watchdog (never completed)
    output reg [2:0]   test_state,          // FSM state at completion/timeout (debug)
    output reg         test_calib           // calib1 (ch1 calibrated), synced to sclk
);
    import PSRAM_Utilities::*;
    localparam [5:0]  TCMD       = burst_delay(MEMORY_BURST);    // 19 for 32B
    localparam [5:0]  WORDS      = burst_cycles(MEMORY_BURST);   // 8  for 32B
    localparam [20:0] TEST_ADDR  = 21'd0;

    function [31:0] test_word(input [2:0] i);
        // distinct per word so a stuck/duplicated read is caught
        test_word = 32'hA5A5_0000 | {29'd0, i};
    endfunction

    // ----------------- CDC: sys_clk test_req -> fb_clk start -----------------
    reg req_tgl_s;
    always @(posedge sclk or negedge srst_n)
        if (!srst_n)      req_tgl_s <= 1'b0;
        else if (test_req) req_tgl_s <= ~req_tgl_s;

    reg [2:0] req_sync;
    always @(posedge fb_clk or negedge fb_rst_n)
        if (!fb_rst_n) req_sync <= 3'b0;
        else           req_sync <= {req_sync[1:0], req_tgl_s};
    wire start_pulse = req_sync[2] ^ req_sync[1];

    // ----------------- fb_clk burst engine + result regs ---------------------
    localparam [2:0] S_IDLE = 3'd0, S_WDAT = 3'd1, S_WWAIT = 3'd2,
                     S_RCMD = 3'd3, S_RDAT = 3'd4, S_DONE = 3'd5;
    reg [2:0]  state;
    reg [5:0]  cnt;
    reg [5:0]  widx, ridx;      // word index within a burst (0..WORDS-1)
    reg [31:0] first_write, first_read;
    reg        done_tgl_f;
    // watchdog so the FSM can't hang (e.g. a read burst that never returns or
    // ch1 never calibrating) -- forces completion with a timeout + stuck state.
    localparam [21:0] WD_MAX = 22'h3F_FFFF;       // ~62 ms at ~67.5 MHz fb_clk
    reg [21:0] wd_cnt;
    reg        timed_out_f;
    reg [2:0]  stuck_state_f;

    always @(posedge fb_clk or negedge fb_rst_n) begin
        if (!fb_rst_n) begin
            state <= S_IDLE; cmd1 <= 1'b0; cmd_en1 <= 1'b0; addr1 <= 21'd0;
            wr_data1 <= 32'd0; data_mask1 <= 4'd0;
            cnt <= 6'd0; widx <= 3'd0; ridx <= 3'd0;
            first_write <= 32'd0; first_read <= 32'd0; done_tgl_f <= 1'b0;
            wd_cnt <= 22'd0; timed_out_f <= 1'b0; stuck_state_f <= 3'd0;
        end else begin
            cmd_en1 <= 1'b0;                         // default: idle bus

            // watchdog: count while busy; reset in IDLE
            if (state == S_IDLE) wd_cnt <= `WRAP_SIM(#1) 22'd0;
            else                 wd_cnt <= `WRAP_SIM(#1) wd_cnt + 1'b1;

            case (state)
                S_IDLE: if (start_pulse && calib1) begin
                    timed_out_f <= `WRAP_SIM(#1) 1'b0;
                    // issue the write command + present word 0
                    cmd1       <= `WRAP_SIM(#1) 1'b1;
                    cmd_en1    <= `WRAP_SIM(#1) 1'b1;
                    addr1      <= `WRAP_SIM(#1) TEST_ADDR;
                    data_mask1 <= `WRAP_SIM(#1) 4'h0;
                    wr_data1   <= `WRAP_SIM(#1) test_word(3'd0);
                    first_write<= `WRAP_SIM(#1) test_word(3'd0);
                    widx       <= `WRAP_SIM(#1) 6'd1;
                    state      <= `WRAP_SIM(#1) S_WDAT;
                end
                S_WDAT: begin                        // stream words 1..WORDS-1
                    wr_data1 <= `WRAP_SIM(#1) test_word(widx[2:0]);
                    if (widx == WORDS - 1'b1) begin
                        cnt   <= `WRAP_SIM(#1) 6'd0;
                        state <= `WRAP_SIM(#1) S_WWAIT;
                    end else
                        widx <= `WRAP_SIM(#1) widx + 1'b1;
                end
                S_WWAIT: begin                       // write-burst completion delay
                    if (cnt == TCMD) state <= `WRAP_SIM(#1) S_RCMD;
                    else cnt <= `WRAP_SIM(#1) cnt + 1'b1;
                end
                S_RCMD: begin                        // issue read command
                    cmd1    <= `WRAP_SIM(#1) 1'b0;
                    cmd_en1 <= `WRAP_SIM(#1) 1'b1;
                    addr1   <= `WRAP_SIM(#1) TEST_ADDR;
                    ridx    <= `WRAP_SIM(#1) 6'd0;
                    state   <= `WRAP_SIM(#1) S_RDAT;
                end
                S_RDAT: begin                        // collect WORDS read words
                    if (rd_data_valid1) begin
                        if (ridx == 6'd0) first_read <= `WRAP_SIM(#1) rd_data1;
                        if (ridx == WORDS - 1'b1) state <= `WRAP_SIM(#1) S_DONE;
                        else ridx <= `WRAP_SIM(#1) ridx + 1'b1;
                    end
                end
                S_DONE: begin                        // publish result, flip handshake
                    done_tgl_f <= `WRAP_SIM(#1) ~done_tgl_f;
                    state      <= `WRAP_SIM(#1) S_IDLE;
                end
                default: state <= `WRAP_SIM(#1) S_IDLE;
            endcase

            // watchdog override (after the case so it wins): bail out of a hung
            // burst, recording where it stuck.
            if (state != S_IDLE && state != S_DONE && wd_cnt == WD_MAX) begin
                timed_out_f   <= `WRAP_SIM(#1) 1'b1;
                stuck_state_f <= `WRAP_SIM(#1) state;
                state         <= `WRAP_SIM(#1) S_DONE;
            end
        end
    end

    // ----------------- CDC: fb_clk done/calib -> sys_clk result --------------
    reg [2:0] done_sync;
    reg [1:0] calib_sync;
    always @(posedge sclk or negedge srst_n) begin
        if (!srst_n) begin
            done_sync <= 3'b0; calib_sync <= 2'b0;
            test_done <= 1'b0; test_busy <= 1'b0;
            test_rdata <= 32'd0; test_match <= 1'b0;
            test_timeout <= 1'b0; test_state <= 3'd0; test_calib <= 1'b0;
        end else begin
            done_sync  <= {done_sync[1:0], done_tgl_f};
            calib_sync <= {calib_sync[0], calib1};
            test_calib <= calib_sync[1];             // live ch1-calibrated status
            test_done  <= 1'b0;
            if (test_req) test_busy <= 1'b1;
            if (done_sync[2] ^ done_sync[1]) begin   // completion edge
                test_rdata   <= first_read;          // all stable since before the flip
                test_match   <= (first_read == first_write);
                test_timeout <= timed_out_f;
                test_state   <= stuck_state_f;
                test_done    <= 1'b1;
                test_busy    <= 1'b0;
            end
        end
    end

endmodule
