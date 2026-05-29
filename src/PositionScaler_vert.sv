`include "timescale.v"
`include "camera_control_defs.vh"

`default_nettype wire

// Compact vertical resize kernel (rounding DDA / Bresenham).
//
// Replaces the generated SOURCE_PIXELS-entry ROM (scaler_generator.py) with a
// single residual accumulator + compare -- the vertical analogue of the
// PositionScaler_horz kernel. For each output row the kernel emits
//
//     position_increment = round((p+1)*T/S) - round(p*T/S)
//
// i.e. how many source rows to advance to reach the next output row. It is
// bit-identical to the old LUT for the 272 -> 480 downscale (and any
// 1 < T/S < 2, where the increment is always 1 or 2).
//
//   clear   : pulse at frame start (output row 0) -- reloads the residual.
//   advance : pulse once per finished output row  -- steps the DDA to row p+1.
//
// position_increment is combinational from the residual register, so it is
// valid for the current row in the same cycle the FrameDownloader FSM latches
// it -- exactly how the old combinational ROM output was consumed.
//
// Residual form: scale the round() bias by 2 so it is integer. With the
// half-scaled remainder resid = round(p*T/S)'s residue in [0, S):
//   increment(p) = ((resid + T) >= 2*S) ? 2 : 1
//   resid(p+1)   = (resid + T) - increment(p)*S
//   resid(0)     = S/2                      (the +0.5 rounding bias; S even here)

module PositionScaler_vert
#(
    parameter integer SOURCE_PIXELS = 272,
    parameter integer TARGET_PIXELS = 480
)
(
    input  wire       clk,
    input  wire       reset_n,
    input  wire       clear,      // frame start: reload residual (output row 0)
    input  wire       advance,    // one finished output row: step the DDA
    output wire [1:0] position_increment
);

    localparam integer ACC_W = $clog2(2*SOURCE_PIXELS + TARGET_PIXELS + 1);
    localparam [ACC_W-1:0] INIT = SOURCE_PIXELS / 2;   // round() bias, S even

    reg  [ACC_W-1:0] resid;

    wire [ACC_W-1:0] sum   = resid + TARGET_PIXELS[ACC_W-1:0];
    wire             take2 = (sum >= 2*SOURCE_PIXELS);
    assign position_increment = take2 ? 2'd2 : 2'd1;

    wire [ACC_W-1:0] resid_n = take2 ? (sum - 2*SOURCE_PIXELS)
                                     : (sum -   SOURCE_PIXELS);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)     resid <= `WRAP_SIM(#1) INIT;
        else if (clear)   resid <= `WRAP_SIM(#1) INIT;
        else if (advance) resid <= `WRAP_SIM(#1) resid_n;
    end

endmodule
