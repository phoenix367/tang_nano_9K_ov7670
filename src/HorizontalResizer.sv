`include "timescale.v"
`include "camera_control_defs.vh"

`ifdef __ICARUS__
`include "svlogger.sv"
`endif

`default_nettype wire

// Pillarbox horizontal processor with downscale.
//
//     FrameDownloader -> HorizontalResizer -> q_cam_data_out FIFO -> LCD
//
// FrameDownloader emits INPUT_WIDTH (e.g. 480) source pixels per row. For each
// row this block emits: row-start token, BORDER_SIZE black pixels, the row
// horizontally downscaled to ACTIVE_WIDTH pixels, BORDER_SIZE black pixels.
// Command tokens (bit 16 = 1) pass through untouched. OUTPUT_WIDTH = INPUT_WIDTH
// (the LCD width); the active band is centred: BORDER_SIZE = (OUTPUT_WIDTH -
// ACTIVE_WIDTH)/2.
//
// The downscale is done by the PositionScaler_horz DDA kernel: every input
// column is streamed through it (one resize_en per consumed column) and kept
// only when write_enable is high, so exactly ACTIVE_WIDTH of the INPUT_WIDTH
// columns reach the output. Because the kernel samples across the whole row,
// there is no left/right crop -- it is a true resize, not a window.
//
// Flow control is decoupled per phase:
//   - borders produce black without consuming input (in_full held high),
//   - the active phase consumes every input column: a kept column needs output
//     room (in_full = out_full), a dropped column is consumed freely.
// Back-pressure is honoured on both sides. ENABLE = 0 is a bit-exact
// pass-through (no-resize build/test path).

module HorizontalResizer
#(
    parameter integer INPUT_WIDTH  = 480,   // source pixels per row from FrameDownloader
    parameter integer ACTIVE_WIDTH = 362,   // downscaled active width
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
                     S_ACTIVE = 2'd2,   // downscale the row through the kernel
                     S_RIGHT  = 2'd3;   // emit right border, stall input

    reg [1:0]  state;
    reg [10:0] bc;   // border pixels emitted (left or right)
    reg [10:0] ic;   // input columns consumed in the active phase

    // ---- horizontal downscale kernel: keeps ACTIVE_WIDTH of INPUT_WIDTH ----
    wire krn_clear = (ENABLE != 0) && (state == S_PASS) &&
                     in_wr_en && !out_full && (in_data == TOKEN_ROW_START);
    reg  krn_resize_en;
    wire krn_keep;

    PositionScaler_horz #(
        .SOURCE_PIXELS(INPUT_WIDTH),
        .TARGET_PIXELS(ACTIVE_WIDTH)
    ) kernel (
        .clk(clk),
        .reset_n(reset_n),
        .clear_state(krn_clear),
        .resize_en(krn_resize_en),
        .write_enable(krn_keep)
    );

    // ---- combinational flow control / output data ----
    always @* begin
        // default = transparent pass-through (also the ENABLE = 0 path)
        out_data      = in_data;
        out_wr_en     = in_wr_en;
        in_full       = out_full;
        krn_resize_en = 1'b0;

        if (ENABLE != 0) begin
            case (state)
                S_LEFT, S_RIGHT: begin
                    out_data  = PIXEL_BLACK;       // border
                    out_wr_en = 1'b1;
                    in_full   = 1'b1;              // stall input while bordering
                end
                S_ACTIVE: begin
                    out_data      = in_data;                  // forward kept columns
                    out_wr_en     = in_wr_en && krn_keep;
                    in_full       = krn_keep ? out_full : 1'b0;   // dropped columns consumed freely
                    krn_resize_en = in_wr_en && !in_full;         // advance kernel per consumed column
                end
                default: begin                     // S_PASS: 1:1 token/pixel forward
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
            bc    <= `WRAP_SIM(#1) 'd0;
            ic    <= `WRAP_SIM(#1) 'd0;
        end else if (ENABLE != 0) begin
            case (state)
                S_PASS:
                    if (in_wr_en && !out_full && in_data == TOKEN_ROW_START) begin
                        bc    <= `WRAP_SIM(#1) 'd0;
                        ic    <= `WRAP_SIM(#1) 'd0;
                        state <= `WRAP_SIM(#1) S_LEFT;
                    end
                S_LEFT:
                    if (!out_full) begin                 // black border accepted
                        bc <= `WRAP_SIM(#1) bc + 1'b1;
                        if (bc == BORDER_SIZE - 1)
                            state <= `WRAP_SIM(#1) S_ACTIVE;
                    end
                S_ACTIVE:
                    if (krn_resize_en) begin             // one input column consumed
                        ic <= `WRAP_SIM(#1) ic + 1'b1;
                        if (ic == INPUT_WIDTH - 1) begin
                            bc    <= `WRAP_SIM(#1) 'd0;
                            state <= `WRAP_SIM(#1) S_RIGHT;
                        end
                    end
                S_RIGHT:
                    if (!out_full) begin                 // black border accepted
                        bc <= `WRAP_SIM(#1) bc + 1'b1;
                        if (bc == BORDER_SIZE - 1)
                            state <= `WRAP_SIM(#1) S_PASS;
                    end
            endcase
        end
    end

endmodule
