`include "timescale.v"
`include "camera_control_defs.vh"

`ifdef __ICARUS__
`include "svlogger.sv"
`endif

`default_nettype wire

// Pillarbox horizontal processor.
//
//     FrameDownloader -> HorizontalResizer -> q_cam_data_out FIFO -> LCD
//
// For each input row it emits: row-start token, BORDER_SIZE black pixels, the
// ACTIVE_WIDTH leftmost source pixels (1:1, no downscale), BORDER_SIZE black
// pixels. Command tokens (bit 16 = 1) pass through untouched.
//
// Crucially, the LEFT border is emitted WITHOUT consuming input (in_full held
// high) so the active region starts at source column 0 -- there is no crop on
// the left. The unused right-hand source pixels (INPUT_WIDTH - ACTIVE_WIDTH of
// them) are then drained (consumed and dropped) while/after the right border
// is emitted, so the row stays aligned for the next row-start.
//
// Because borders produce-without-consuming and the drain consumes-without-
// producing, the block is no longer 1:1; it is a small stream FSM with
// decoupled input/output flow control. Back-pressure is still honoured on both
// sides (no data is dropped except the intended right-hand crop). ENABLE = 0
// makes the block a bit-exact pass-through (no-resize build/test path).
//
// INPUT_WIDTH (e.g. 480) is what FrameDownloader emits per row; OUTPUT_WIDTH
// equals it (the LCD width). The active band is centred: BORDER_SIZE =
// (OUTPUT_WIDTH - ACTIVE_WIDTH)/2.

module HorizontalResizer
#(
    parameter integer INPUT_WIDTH  = 480,   // data pixels FrameDownloader emits per row
    parameter integer ACTIVE_WIDTH = 362,   // left-aligned 1:1 source pixels shown
    parameter integer ENABLE       = 1
)
(
    input  wire        clk,
    input  wire        reset_n,

    // Upstream (FrameDownloader store interface)
    input  wire        in_wr_en,
    input  wire [16:0] in_data,
    output reg         in_full,

    // Downstream (store FIFO)
    output reg         out_wr_en,
    output reg  [16:0] out_data,
    input  wire        out_full
);

    localparam integer OUTPUT_WIDTH = INPUT_WIDTH;
    localparam integer BORDER_SIZE  = (OUTPUT_WIDTH - ACTIVE_WIDTH) / 2;

    localparam [16:0] TOKEN_ROW_START = 17'h10001;
    localparam [16:0] PIXEL_BLACK     = 17'h00000;

    localparam [1:0] S_PASS   = 2'd0,   // forward tokens, wait for row-start
                     S_LEFT   = 2'd1,   // emit left border, stall input
                     S_ACTIVE = 2'd2,   // 1:1 pass the ACTIVE_WIDTH source pixels
                     S_RIGHT  = 2'd3;   // emit right border + drain leftover input

    reg [1:0]  state;
    reg [10:0] ob;   // output column emitted within the row
    reg [10:0] ic;   // input data pixels consumed within the row

    // ---- combinational flow control / output data ----
    always @* begin
        // default = transparent pass-through (also the ENABLE = 0 path)
        out_data  = in_data;
        out_wr_en = in_wr_en;
        in_full   = out_full;

        if (ENABLE != 0) begin
            case (state)
                S_LEFT: begin
                    out_data  = PIXEL_BLACK;          // left border
                    out_wr_en = 1'b1;
                    in_full   = 1'b1;                 // delay input row processing
                end
                S_RIGHT: begin
                    out_data  = PIXEL_BLACK;          // right border
                    out_wr_en = (ob < OUTPUT_WIDTH);  // until the output row is full
                    in_full   = (ic >= INPUT_WIDTH);  // drain leftover input (drop), even if out_full
                end
                default: begin                        // S_PASS / S_ACTIVE: 1:1
                    out_data  = in_data;
                    out_wr_en = in_wr_en;
                    in_full   = out_full;
                end
            endcase
        end
    end

    // ---- sequential state / counters ----
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= `WRAP_SIM(#1) S_PASS;
            ob    <= `WRAP_SIM(#1) 'd0;
            ic    <= `WRAP_SIM(#1) 'd0;
        end else if (ENABLE != 0) begin
            case (state)
                S_PASS:
                    if (in_wr_en && !out_full && in_data == TOKEN_ROW_START) begin
                        ob    <= `WRAP_SIM(#1) 'd0;
                        ic    <= `WRAP_SIM(#1) 'd0;
                        state <= `WRAP_SIM(#1) S_LEFT;
                    end
                S_LEFT:
                    if (!out_full) begin              // black border accepted
                        ob <= `WRAP_SIM(#1) ob + 1'b1;
                        if (ob == BORDER_SIZE - 1)
                            state <= `WRAP_SIM(#1) S_ACTIVE;
                    end
                S_ACTIVE:
                    if (in_wr_en && !out_full) begin  // 1:1 source pixel accepted
                        ob <= `WRAP_SIM(#1) ob + 1'b1;
                        ic <= `WRAP_SIM(#1) ic + 1'b1;
                        if (ic == ACTIVE_WIDTH - 1)
                            state <= `WRAP_SIM(#1) S_RIGHT;
                    end
                S_RIGHT: begin
                    logic [10:0] ob_n, ic_n;
                    ob_n = ob;
                    ic_n = ic;
                    if (ob < OUTPUT_WIDTH && !out_full) ob_n = ob + 1'b1;  // emit black
                    if (ic < INPUT_WIDTH  && in_wr_en)  ic_n = ic + 1'b1;  // drain/drop
                    ob <= `WRAP_SIM(#1) ob_n;
                    ic <= `WRAP_SIM(#1) ic_n;
                    if (ob_n >= OUTPUT_WIDTH && ic_n >= INPUT_WIDTH)
                        state <= `WRAP_SIM(#1) S_PASS;
                end
            endcase
        end
    end

endmodule
