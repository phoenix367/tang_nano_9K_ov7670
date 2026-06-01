`include "timescale.v"
`include "camera_control_defs.vh"
`include "psram_utils.vh"

`default_nettype wire

// Channel-1 PSRAM controller for the frame-grab feature.
//
// The video frame buffer uses PSRAM channel 0; channel 1 is exclusively this
// module's. Two operations, driven from the sys_clk side (Modbus) over a CDC:
//
//   * GRAB  -- capture the next complete camera frame into ch1. The frame is
//     already being written to ch0 by FrameUploader; we *tee* that write stream
//     (the pipelined ch0 IP inputs: cmd_en_0_p & cmd_0_p, wr_data0_p) onto the
//     ch1 pins for one frame (delimited by grab_active), laying the frame out
//     contiguously from ch1 address 0. ch1 shares the DQ PHY with ch0 but the IP
//     arbitrates the two channels (proven by the bring-up loopback running
//     concurrently with live video).
//
//   * READ  -- read one 32-bit ch1 word (the first word of the burst at rd_addr)
//     for the host to stream the captured frame back out.
//
// A watchdog bounds both so a never-arriving frame / hung read can't wedge busy.
// Burst sequencing replicates the proven ch0 path (one cmd_en pulse + WORDS
// words). Clock domains bridged by toggle handshakes (fb_clk <-> sclk).

module psram_ch1 #(
    parameter integer MEMORY_BURST = 32
)
(
    // ---- PSRAM IP channel-1 pins (fb_clk domain) ----
    input  wire        fb_clk,
    input  wire        fb_rst_n,
    input  wire        calib1,
    output reg         cmd1,
    output reg         cmd_en1,
    output reg [20:0]  addr1,
    output reg [31:0]  wr_data1,
    output reg [3:0]   data_mask1,
    input  wire [31:0] rd_data1,
    input  wire        rd_data_valid1,

    // ---- ch0 write tap for the grab-mirror (fb_clk domain) ----
    input  wire        tap_wr_cmd,    // cmd_en_0_p & cmd_0_p (a ch0 write this cycle)
    input  wire [31:0] tap_wr_data,   // wr_data0_p
    input  wire        grab_active,   // a camera frame is being written to ch0

    // ---- control / status (sys_clk domain) ----
    input  wire        sclk,
    input  wire        srst_n,
    input  wire        grab_arm,      // pulse: capture the next frame into ch1
    input  wire        rd_req,        // pulse: read the ch1 word at rd_addr
    input  wire [20:0] rd_addr,       // ch1 burst address (matches the grab layout)
    output reg         busy,          // high from arm/req until the op completes
    output reg [255:0] rd_data_o,     // last read burst (8 words; valid once busy clears)
    output reg         ch1_calib      // calib1 (ch1 calibrated), synced to sclk
);
    import PSRAM_Utilities::*;
    localparam [5:0]  WORDS  = burst_cycles(MEMORY_BURST);  // 8 for 32B
    localparam [20:0] BSTEP  = 21'd16;                      // ch0 addr increment per burst
    localparam [26:0] WD_MAX = 27'h7FF_FFFF;                // ~2 s watchdog at fb_clk

    // ------------------- CDC: sys_clk triggers -> fb_clk ---------------------
    reg        arm_tgl_s, rd_tgl_s;
    reg [20:0] rd_addr_s;
    always @(posedge sclk or negedge srst_n) begin
        if (!srst_n) begin arm_tgl_s <= 1'b0; rd_tgl_s <= 1'b0; rd_addr_s <= 21'd0; end
        else begin
            if (grab_arm) arm_tgl_s <= ~arm_tgl_s;
            if (rd_req)   begin rd_tgl_s <= ~rd_tgl_s; rd_addr_s <= rd_addr; end
        end
    end
    reg [2:0] arm_sync, rd_sync;
    always @(posedge fb_clk or negedge fb_rst_n) begin
        if (!fb_rst_n) begin arm_sync <= 3'b0; rd_sync <= 3'b0; end
        else begin arm_sync <= {arm_sync[1:0], arm_tgl_s}; rd_sync <= {rd_sync[1:0], rd_tgl_s}; end
    end
    wire grab_start = arm_sync[2] ^ arm_sync[1];
    wire rd_start   = rd_sync[2]  ^ rd_sync[1];

    // ------------------- fb_clk operation FSM --------------------------------
    localparam [2:0] S_IDLE = 3'd0, S_GWAIT = 3'd1, S_GCAP = 3'd2,
                     S_GDRAIN = 3'd3, S_RCMD = 3'd4, S_RDAT = 3'd5;
    reg [2:0]  state;
    reg [20:0] ch1_wptr;
    reg [5:0]  ridx;
    reg [2:0]  drain;
    reg [26:0] wd;
    reg        done_tgl_f;
    reg [255:0] rd_burst_f;            // full 8-word burst captured by a read
    reg        tap_cmd_q;
    reg [31:0] tap_data_q;
    reg        grab_active_q;     // for rising-edge detection (a fresh frame start)

    always @(posedge fb_clk or negedge fb_rst_n) begin
        if (!fb_rst_n) begin
            state <= S_IDLE; cmd1 <= 1'b0; cmd_en1 <= 1'b0; addr1 <= 21'd0;
            wr_data1 <= 32'd0; data_mask1 <= 4'd0;
            ch1_wptr <= 21'd0; ridx <= 6'd0; drain <= 3'd0; wd <= 27'd0;
            done_tgl_f <= 1'b0; rd_burst_f <= 256'd0; tap_cmd_q <= 1'b0; tap_data_q <= 32'd0;
            grab_active_q <= 1'b0;
        end else begin
            cmd_en1    <= `WRAP_SIM(#1) 1'b0;             // default: idle bus
            tap_cmd_q  <= `WRAP_SIM(#1) tap_wr_cmd;       // register the tap (1-cycle align)
            tap_data_q <= `WRAP_SIM(#1) tap_wr_data;
            grab_active_q <= `WRAP_SIM(#1) grab_active;   // for rising-edge detect
            if (state == S_IDLE) wd <= `WRAP_SIM(#1) 27'd0;
            else                 wd <= `WRAP_SIM(#1) wd + 1'b1;

            case (state)
                S_IDLE: begin
                    if (grab_start && calib1)
                        state <= `WRAP_SIM(#1) S_GWAIT;
                    else if (rd_start && calib1) begin
                        addr1 <= `WRAP_SIM(#1) rd_addr_s;
                        state <= `WRAP_SIM(#1) S_RCMD;
                    end
                end

                // ---- grab: wait for a fresh frame START (rising edge of
                //      grab_active), then mirror its writes. A level check would
                //      start mid-frame when armed while a frame is in flight,
                //      capturing only its tail. ----
                S_GWAIT: if (grab_active && !grab_active_q) begin
                    ch1_wptr <= `WRAP_SIM(#1) 21'd0;
                    state    <= `WRAP_SIM(#1) S_GCAP;
                end
                S_GCAP: begin
                    cmd1       <= `WRAP_SIM(#1) 1'b1;
                    data_mask1 <= `WRAP_SIM(#1) 4'h0;
                    wr_data1   <= `WRAP_SIM(#1) tap_data_q;
                    cmd_en1    <= `WRAP_SIM(#1) tap_cmd_q;
                    addr1      <= `WRAP_SIM(#1) ch1_wptr;
                    if (tap_cmd_q) ch1_wptr <= `WRAP_SIM(#1) ch1_wptr + BSTEP;
                    if (!grab_active) begin drain <= `WRAP_SIM(#1) 3'd0; state <= `WRAP_SIM(#1) S_GDRAIN; end
                end
                S_GDRAIN: begin                           // flush the registered tap
                    cmd1       <= `WRAP_SIM(#1) 1'b1;
                    data_mask1 <= `WRAP_SIM(#1) 4'h0;
                    wr_data1   <= `WRAP_SIM(#1) tap_data_q;
                    cmd_en1    <= `WRAP_SIM(#1) tap_cmd_q;
                    addr1      <= `WRAP_SIM(#1) ch1_wptr;
                    if (tap_cmd_q) ch1_wptr <= `WRAP_SIM(#1) ch1_wptr + BSTEP;
                    if (drain == 3'd5) begin
                        done_tgl_f <= `WRAP_SIM(#1) ~done_tgl_f;
                        state      <= `WRAP_SIM(#1) S_IDLE;
                    end else
                        drain <= `WRAP_SIM(#1) drain + 1'b1;
                end

                // ---- read one ch1 burst, capture word 0 ----
                S_RCMD: begin                             // addr1 already = rd_addr_s
                    cmd1    <= `WRAP_SIM(#1) 1'b0;
                    cmd_en1 <= `WRAP_SIM(#1) 1'b1;
                    ridx    <= `WRAP_SIM(#1) 6'd0;
                    state   <= `WRAP_SIM(#1) S_RDAT;
                end
                S_RDAT: if (rd_data_valid1) begin
                    rd_burst_f[ridx[2:0]*32 +: 32] <= `WRAP_SIM(#1) rd_data1;
                    if (ridx == WORDS - 1'b1) begin
                        done_tgl_f <= `WRAP_SIM(#1) ~done_tgl_f;
                        state      <= `WRAP_SIM(#1) S_IDLE;
                    end else
                        ridx <= `WRAP_SIM(#1) ridx + 1'b1;
                end

                default: state <= `WRAP_SIM(#1) S_IDLE;
            endcase

            // watchdog: never wedge busy
            if (state != S_IDLE && wd == WD_MAX) begin
                done_tgl_f <= `WRAP_SIM(#1) ~done_tgl_f;
                state      <= `WRAP_SIM(#1) S_IDLE;
            end
        end
    end

    // ------------------- CDC: fb_clk done/calib -> sys_clk -------------------
    reg [2:0] done_sync;
    reg [1:0] cal_sync;
    always @(posedge sclk or negedge srst_n) begin
        if (!srst_n) begin
            done_sync <= 3'b0; cal_sync <= 2'b0;
            busy <= 1'b0; rd_data_o <= 256'd0; ch1_calib <= 1'b0;
        end else begin
            done_sync <= {done_sync[1:0], done_tgl_f};
            cal_sync  <= {cal_sync[0], calib1};
            ch1_calib <= cal_sync[1];
            if (grab_arm || rd_req) busy <= 1'b1;
            if (done_sync[2] ^ done_sync[1]) begin
                busy      <= 1'b0;
                rd_data_o <= rd_burst_f;    // stable since before the done flip
            end
        end
    end

endmodule
