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
    reg [ACC_WIDTH-1:0]  acc   = 'd0;

    wire [ACC_WIDTH-1:0] acc_next = acc + TARGET_PIXELS[ACC_WIDTH-1:0];
    wire                 keep     = (acc_next >= SOURCE_PIXELS[ACC_WIDTH-1:0]);

    assign write_enable = keep && resize_en && (state == STATE_RESIZE);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            acc   <= `WRAP_SIM(#1) 'd0;
            state <= `WRAP_SIM(#1) IDLE;
        end else begin
            case (state)
                IDLE:
                    if (clear_state)
                        state <= `WRAP_SIM(#1) STATE_CLEAR;
                STATE_CLEAR: begin
                    acc   <= `WRAP_SIM(#1) 'd0;
                    state <= `WRAP_SIM(#1) STATE_RESIZE;
                end
                STATE_RESIZE:
                    if (clear_state)
                        state <= `WRAP_SIM(#1) STATE_CLEAR;
                    else if (resize_en)
                        acc <= `WRAP_SIM(#1) keep ? (acc_next - SOURCE_PIXELS[ACC_WIDTH-1:0])
                                                  : acc_next;
            endcase
        end
    end

endmodule
