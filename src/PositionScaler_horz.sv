`include "timescale.v"
`include "camera_control_defs.vh"

`ifdef __ICARUS__
`include "svlogger.sv"
`endif

// Compact horizontal downscale kernel (Bresenham / DDA).
//
// As source columns stream past (one per `resize_en` while in STATE_RESIZE),
// `write_enable` selects exactly TARGET_PIXELS out of every SOURCE_PIXELS
// columns to keep -- e.g. 363 of 640 for the pillarbox downscale. The
// downstream stream block (HorizontalResizer) forwards a column when
// `write_enable` is high and drops it otherwise.
//
// This replaces the generated SOURCE_PIXELS-entry lookup table (a huge
// combinational mux that sat on the fb_clk critical path) with a single
// add + compare on an ~10-bit residual accumulator. `acc` holds
// (column * TARGET_PIXELS) mod SOURCE_PIXELS; a column is kept when adding
// TARGET_PIXELS crosses a SOURCE_PIXELS boundary, which happens exactly
// TARGET_PIXELS times over a full SOURCE_PIXELS-wide row. `write_enable` is
// combinational from `acc`, so it is valid for the current column in the same
// cycle (a registered output would lag the column by one and emit the wrong
// pixel).
//
// `clear_state` (pulsed at row start) reloads the accumulator; `resize_en`
// advances one source column.

module PositionScaler_horz
#(
    parameter SOURCE_PIXELS = 640,
    parameter TARGET_PIXELS = 363,
    parameter CACHE_SIZE    = 16    // unused; kept for instantiation compatibility
)
(
    input  wire clk,
    input  wire reset_n,
    input  wire clear_state,
    input  wire resize_en,
    output wire write_enable
);

    localparam integer ACC_WIDTH = $clog2(SOURCE_PIXELS + TARGET_PIXELS + 1);

    typedef enum bit [1:0] { IDLE, STATE_CLEAR, STATE_RESIZE } state_t;

    state_t              state = IDLE;
    reg [ACC_WIDTH-1:0]  acc    = 'd0;
    reg                  keep_q = 1'b0;   // registered keep(acc) -- held in lockstep with acc

    // "Keep this column" is a REGISTERED output (keep_q), so write_enable feeds
    // the downstream FIFO write logic from a flop -- the accumulate + compare
    // no longer sits in series with the store-FIFO Full/wptr path within one
    // fb_clk cycle (that was the fb_clk critical path). The recurrence below
    // (acc -> keep for the next column) is a register-to-register path with a
    // full cycle to settle. keep_q does NOT depend on resize_en; the consumer
    // reads write_enable to decide keep/drop and pulses resize_en to advance.
    assign write_enable = keep_q && (state == STATE_RESIZE);

    // Next accumulator value, using the registered keep_q (== keep(acc)).
    wire [ACC_WIDTH-1:0] acc_plus = acc + TARGET_PIXELS[ACC_WIDTH-1:0];
    wire [ACC_WIDTH-1:0] acc_adv  = keep_q ? (acc_plus - SOURCE_PIXELS[ACC_WIDTH-1:0])
                                           : acc_plus;
    // keep for that next accumulator value (registered into keep_q).
    wire keep_adv = ((acc_adv + TARGET_PIXELS[ACC_WIDTH-1:0]) >= SOURCE_PIXELS[ACC_WIDTH-1:0]);
    // keep for column 0 (acc = 0): only when not downscaling (TARGET >= SOURCE).
    localparam KEEP0 = (TARGET_PIXELS >= SOURCE_PIXELS);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            acc    <= `WRAP_SIM(#1) 'd0;
            keep_q <= `WRAP_SIM(#1) 1'b0;
            state  <= `WRAP_SIM(#1) IDLE;
        end else begin
            case (state)
                IDLE:
                    if (clear_state)
                        state <= `WRAP_SIM(#1) STATE_CLEAR;
                STATE_CLEAR: begin
                    acc    <= `WRAP_SIM(#1) 'd0;
                    keep_q <= `WRAP_SIM(#1) KEEP0[0];
                    state  <= `WRAP_SIM(#1) STATE_RESIZE;
                end
                STATE_RESIZE:
                    if (clear_state) begin
                        state  <= `WRAP_SIM(#1) STATE_CLEAR;
                    end else if (resize_en) begin
                        acc    <= `WRAP_SIM(#1) acc_adv;
                        keep_q <= `WRAP_SIM(#1) keep_adv;
                    end
            endcase
        end
    end

endmodule
