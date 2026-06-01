`ifdef __ICARUS__
`include "timescale.v"
`include "psram_utils.vh"
`else
`include "../timescale.v"
`include "../psram_utils.vh"
`endif

`default_nettype wire

// Ping-pong (double-buffered) row prefetch cache for the PSRAM download path.
//
//     PSRAM  --read bursts-->  DownloadRowCache  --pixel stream-->  FrameDownloader
//
// FrameDownloader seeds the *initial* row address (base_addr) on `start`; the
// cache then autonomously walks the frame, reading FRAME_WIDTH pixels per output
// row in MEMORY_BURST chunks and auto-incrementing the source-row base address
// after each row. It fills one of two `sdpb_1kx32` banks while the other bank is
// drained out the read port, swapping banks per row (mirrors the upload-side
// row_a/row_b ping-pong in cam_pixel_processor.sv).
//
// Vertical resize: when ENABLE_RESIZE, the per-row source advance is variable --
// position_increment (1..2 source rows) from the same PositionScaler_vert DDA
// kernel FrameDownloader used to drive, so source-row selection is bit-identical
// to the pre-prefetch design. When ENABLE_RESIZE = 0 the advance is a constant
// ORIG_FRAME_WIDTH (1 source row per output row, leftmost-480 crop).
//
// Back-pressure: when both banks are full and FrameDownloader has not yet
// released one, the cache stalls its PSRAM reads (no read_rq) until a release.
// Over-read is bounded by MAX_ROWS (= FRAME_HEIGHT output rows): the cache fetches
// exactly that many rows from base_addr and then idles, so it never reads past
// the frame into the next buffer region.
//
// Read/drain port: FrameDownloader drives `rd_pix_addr` (pixel index within the
// front row) and reads `rd_pix_data` CACHE_DELAY (=2) cycles later. The
// sdpb_1kx32 output is registered (READ_MODE=1, 2-cycle latency); because the
// consumer holds rd_pix_addr stable across those 2 cycles, the high/low 16-bit
// half-select is purely combinational on the held rd_pix_addr[0]. `row_avail`
// signals the front bank holds a complete row; `row_release` (pulse) frees it
// and advances to the next filled bank.

module DownloadRowCache
#(
    parameter MEMORY_BURST     = 32,    // PSRAM burst, bytes (8 words, 16 px)
    parameter FRAME_WIDTH,              // pixels read/drained per row (no default)
    parameter FRAME_HEIGHT,             // output rows per frame, self-limit (no default)
    parameter ORIG_FRAME_WIDTH,         // source row pitch, pixel units (no default)
    parameter ENABLE_RESIZE    = 0      // vertical DDA downscale on/off
)
(
    input  clk,
    input  reset_n,

    // ---- control (from FrameDownloader) ----
    input         start,                // pulse: latch base_addr, reset banks, begin frame
    input  [20:0] base_addr,            // initial (top) row address, pixel units

    // ---- PSRAM (routed through FrameDownloader's external ports) ----
    output reg        read_rq,
    output     [20:0] read_addr,
    input             read_ack,
    output reg        mem_rd_en,
    input      [31:0] read_data,
    input             rd_data_valid,

    // ---- drain (to FrameDownloader) ----
    output            row_avail,        // front bank holds a complete row
    input      [9:0]  rd_pix_addr,      // pixel index within the front row
    output     [15:0] rd_pix_data,      // pixel at rd_pix_addr (CACHE_DELAY-cycle latency)
    input             row_release       // pulse: FD finished draining front bank
);
    import PSRAM_Utilities::*;

    localparam PIX_PER_BURST  = MEMORY_BURST / 2;             // 16
    localparam BURSTS_PER_ROW = FRAME_WIDTH / PIX_PER_BURST;  // 30
    localparam BURST_CYCLES   = burst_cycles(MEMORY_BURST);   // 8

    // Fill FSM
    localparam [2:0] F_IDLE = 3'd0,   // decide whether to start fetching a row
                     F_REQ  = 3'd1,   // assert read_rq, wait for grant
                     F_WAIT = 3'd2,   // wait read_ack, then launch the burst
                     F_DATA = 3'd3,   // collect BURST_CYCLES words into the fill bank
                     F_DONE = 3'd4;   // all MAX_ROWS rows fetched -> idle

    reg [2:0]  fstate;
    reg [20:0] cur_addr;       // current burst address (pixel units)
    reg [20:0] row_base;       // base address of the row currently being fetched
    reg [9:0]  wr_word;        // write word index within the fill bank (0..ROW_WORDS-1)
    reg [5:0]  read_counter;   // words collected in the current burst (0..BURST_CYCLES)
    reg [5:0]  burst_in_row;   // bursts done in the current row (0..BURSTS_PER_ROW-1)
    reg [10:0] rows_fetched;   // rows fetched so far (0..FRAME_HEIGHT)
    reg        fill_bank;      // bank currently being filled
    reg        front_bank;     // bank currently being drained
    reg [1:0]  bank_full;      // per-bank "holds a complete row" flag
    reg        active;         // a frame is in progress (gates prefetch). Cleared
                               // at reset and after F_DONE so the cache issues NO
                               // PSRAM reads until FrameDownloader pulses `start`
                               // -- never fetch from a stale base or during init.

    assign read_addr = cur_addr;
    assign row_avail = bank_full[front_bank];

    // ---- vertical resize DDA (kept bit-identical to FrameDownloader's prior use:
    //      default 272/480 params, cleared at frame start, advanced once per
    //      fetched output row). position_increment is combinational from the
    //      residual, so it is valid for the current row the cycle it is read. ----
    wire [1:0] row_inc_o;
    wire       row_done_fetch = (fstate == F_DATA) &&
                                (read_counter == BURST_CYCLES) &&
                                (burst_in_row == BURSTS_PER_ROW - 1);
    wire [1:0] stride_rows = (ENABLE_RESIZE != 0) ? row_inc_o : 2'd1;

    PositionScaler_vert position_scaler_vert(
        .clk(clk),
        .reset_n(reset_n),
        .clear(start),
        .advance(row_done_fetch),
        .position_increment(row_inc_o)
    );

    // write-enable into the fill bank: one word per rd_data_valid while collecting
    wire fill_we = (fstate == F_DATA) && rd_data_valid && (read_counter != BURST_CYCLES);
    wire b0_we   = fill_we && (fill_bank == 1'b0);
    wire b1_we   = fill_we && (fill_bank == 1'b1);

    // read (drain) address: pixel index -> 32-bit word index; half from bit 0
    wire [9:0]  rd_word = {1'b0, rd_pix_addr[9:1]};
    wire [31:0] b0_dout, b1_dout;
    wire [31:0] front_dout = front_bank ? b1_dout : b0_dout;
    assign rd_pix_data = rd_pix_addr[0] ? front_dout[31:16] : front_dout[15:0];

    sdpb_1kx32 bank0(
        .dout(b0_dout),
        .clka(clk), .cea(b0_we), .reseta(~reset_n),
        .clkb(clk), .ceb(1'b1),  .resetb(~reset_n), .oce(1'b1),
        .ada(wr_word), .din(read_data), .adb(rd_word)
    );

    sdpb_1kx32 bank1(
        .dout(b1_dout),
        .clka(clk), .cea(b1_we), .reseta(~reset_n),
        .clkb(clk), .ceb(1'b1),  .resetb(~reset_n), .oce(1'b1),
        .ada(wr_word), .din(read_data), .adb(rd_word)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fstate       <= `WRAP_SIM(#1) F_IDLE;
            cur_addr     <= `WRAP_SIM(#1) 'd0;
            row_base     <= `WRAP_SIM(#1) 'd0;
            wr_word      <= `WRAP_SIM(#1) 'd0;
            read_counter <= `WRAP_SIM(#1) 'd0;
            burst_in_row <= `WRAP_SIM(#1) 'd0;
            rows_fetched <= `WRAP_SIM(#1) 'd0;
            fill_bank    <= `WRAP_SIM(#1) 1'b0;
            front_bank   <= `WRAP_SIM(#1) 1'b0;
            bank_full    <= `WRAP_SIM(#1) 2'b00;
            read_rq      <= `WRAP_SIM(#1) 1'b0;
            mem_rd_en    <= `WRAP_SIM(#1) 1'b0;
            active       <= `WRAP_SIM(#1) 1'b0;
        end else if (start) begin
            // (Re)seed for a fresh frame. Drain side resets too: front_bank and
            // bank_full cleared so the first fetched row becomes front.
            fstate       <= `WRAP_SIM(#1) F_IDLE;
            cur_addr     <= `WRAP_SIM(#1) base_addr;
            row_base     <= `WRAP_SIM(#1) base_addr;
            wr_word      <= `WRAP_SIM(#1) 'd0;
            read_counter <= `WRAP_SIM(#1) 'd0;
            burst_in_row <= `WRAP_SIM(#1) 'd0;
            rows_fetched <= `WRAP_SIM(#1) 'd0;
            fill_bank    <= `WRAP_SIM(#1) 1'b0;
            front_bank   <= `WRAP_SIM(#1) 1'b0;
            bank_full    <= `WRAP_SIM(#1) 2'b00;
            read_rq      <= `WRAP_SIM(#1) 1'b0;
            mem_rd_en    <= `WRAP_SIM(#1) 1'b0;
            active       <= `WRAP_SIM(#1) 1'b1;
        end else begin
            // ---- drain side: free the front bank on release, advance front ----
            // (Separate `if` from the fill-side set below; the two never target
            //  the same bank, so single-block ownership of bank_full is race-free.)
            if (row_release) begin
                bank_full[front_bank] <= `WRAP_SIM(#1) 1'b0;
                front_bank            <= `WRAP_SIM(#1) ~front_bank;
            end

            // ---- fill side: autonomous prefetch into the free bank ----
            case (fstate)
                F_IDLE: begin
                    // Do nothing until `start` seeds a frame (active). This keeps
                    // the cache from issuing PSRAM reads after reset / between
                    // frames -- e.g. during the PSRAM controller's power-on
                    // calibration, before any buffer is assigned.
                    if (active) begin
                        if (rows_fetched == FRAME_HEIGHT) begin
                            active <= `WRAP_SIM(#1) 1'b0;
                            fstate <= `WRAP_SIM(#1) F_DONE;
                        end else if (!bank_full[fill_bank]) begin
                            row_base     <= `WRAP_SIM(#1) cur_addr;
                            wr_word      <= `WRAP_SIM(#1) 'd0;
                            burst_in_row <= `WRAP_SIM(#1) 'd0;
                            fstate       <= `WRAP_SIM(#1) F_REQ;
                        end
                        // else: both banks full -> stall here until row_release
                    end
                end
                F_REQ: begin
                    read_rq <= `WRAP_SIM(#1) 1'b1;
                    fstate  <= `WRAP_SIM(#1) F_WAIT;
                end
                F_WAIT: begin
                    if (read_ack) begin
                        mem_rd_en    <= `WRAP_SIM(#1) 1'b1;
                        read_counter <= `WRAP_SIM(#1) 'd0;
                        fstate       <= `WRAP_SIM(#1) F_DATA;
                    end
                    // cur_addr is held = this burst's address so the PSRAM command
                    // (issued while mem_rd_en is high) latches the right address;
                    // the advance to the next burst happens after F_DATA completes.
                end
                F_DATA: begin
                    mem_rd_en <= `WRAP_SIM(#1) 1'b0;
                    if (rd_data_valid && read_counter != BURST_CYCLES) begin
                        read_counter <= `WRAP_SIM(#1) read_counter + 1'b1;
                        wr_word      <= `WRAP_SIM(#1) wr_word + 1'b1;
                    end else if (read_counter == BURST_CYCLES) begin
                        read_rq <= `WRAP_SIM(#1) 1'b0;
                        if (burst_in_row == BURSTS_PER_ROW - 1) begin
                            // row complete: publish the bank, swap, step the source
                            // row base by the (resize-dependent) vertical stride.
                            // row_done_fetch == 1 this cycle -> the DDA advances too.
                            bank_full[fill_bank] <= `WRAP_SIM(#1) 1'b1;
                            fill_bank            <= `WRAP_SIM(#1) ~fill_bank;
                            rows_fetched         <= `WRAP_SIM(#1) rows_fetched + 1'b1;
                            cur_addr             <= `WRAP_SIM(#1) 21'(row_base + stride_rows * ORIG_FRAME_WIDTH);
                            fstate               <= `WRAP_SIM(#1) F_IDLE;
                        end else begin
                            burst_in_row <= `WRAP_SIM(#1) burst_in_row + 1'b1;
                            cur_addr     <= `WRAP_SIM(#1) 21'(cur_addr + PIX_PER_BURST);
                            fstate       <= `WRAP_SIM(#1) F_REQ;
                        end
                    end
                end
                F_DONE: begin
                    // all rows fetched; remain idle until next `start`
                    read_rq   <= `WRAP_SIM(#1) 1'b0;
                    mem_rd_en <= `WRAP_SIM(#1) 1'b0;
                end
                default: fstate <= `WRAP_SIM(#1) F_IDLE;
            endcase
        end
    end
endmodule
