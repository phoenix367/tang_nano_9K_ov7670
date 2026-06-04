`include "timescale.v"
`include "camera_control_defs.vh"

`default_nettype wire

// On-screen-display overlay for the LCD output.
//
// Sits between LCD_Controller and the LCD pins. It watches the controller's
// DE/VSYNC to reconstruct the active pixel position (x,y), looks the character
// cell up in a 60x17 character buffer, fetches the 8x16 glyph row from the font
// ROM, and paints glyph pixels white over the passing video. Glyph-off pixels
// pass the video through unchanged. The whole stream is delayed by the 3-cycle
// lookup pipeline (charbuf read -> font read -> output register), a constant
// few-pixel shift the panel doesn't care about.
//
// Clock domains: the overlay runs on the LCD pixel clock (`clk`). The character
// buffer is a dual-clock simple-dual-port RAM written from the host/sys_clk side
// (`wr_clk`) and read here — the RAM is the CDC primitive for the text. The
// single-bit `osd_enable` control is brought across with a CDC_Bit_Synchronizer.

module OSDOverlay #(
    parameter integer SCREEN_WIDTH  = 480,
    parameter integer SCREEN_HEIGHT = 272,
    parameter integer COLS = SCREEN_WIDTH / 8,    // 60 character columns
    parameter integer ROWS = (SCREEN_HEIGHT + 15) / 16   // 17 character rows
)
(
    input  wire        clk,        // LCD pixel clock (screen_clk)
    input  wire        reset_n,

    // video in (registered outputs of LCD_Controller)
    input  wire        de_in,
    input  wire        hsync_in,
    input  wire        vsync_in,
    input  wire [4:0]  r_in,
    input  wire [5:0]  g_in,
    input  wire [4:0]  b_in,

    // video out (delayed by the lookup pipeline, glyphs composited)
    output reg         de_out,
    output reg         hsync_out,
    output reg         vsync_out,
    output reg [4:0]   r_out,
    output reg [5:0]   g_out,
    output reg [4:0]   b_out,

    // control (sys_clk domain; synchronized internally)
    input  wire        osd_enable,

    // character-buffer write port (host / sys_clk domain)
    input  wire        wr_clk,
    input  wire        wr_en,
    input  wire [10:0] wr_addr,    // 0 .. COLS*ROWS-1  (row*COLS + col)
    input  wire [7:0]  wr_data,
    // character-buffer read-back port (host / wr_clk domain): registered read,
    // 1-cycle latency. Lets the host read back what it wrote (see wb_osd 0xFD read).
    input  wire [10:0] rb_addr,
    output reg  [7:0]  rb_data
);
    localparam integer CELLS = COLS * ROWS;

    // ---- osd_enable across sys_clk -> clk ----
    wire osd_en;
    CDC_Bit_Synchronizer #(.EXTRA_DEPTH(1)) en_sync (
        .receiving_clock(clk), .bit_in(osd_enable), .bit_out(osd_en)
    );

    // ---- font ROM: 256 glyphs x 16 rows, 8-bit row bitmap (MSB = leftmost) ----
    reg [7:0] font [0:4095];
    initial begin
`include "font8x16_init.vh"
    end

    // ---- character buffer: dual-clock SDP RAM (write wr_clk, read clk) ----
    reg [7:0] charbuf [0:CELLS-1];
    integer ci;
    initial for (ci = 0; ci < CELLS; ci = ci + 1) charbuf[ci] = 8'h00;
    always @(posedge wr_clk)
        if (wr_en) charbuf[wr_addr] <= `WRAP_SIM(#1) wr_data;

    // host read-back: registered read of the char buffer on the wr_clk side
    // (second read port; the render read below is on `clk`).
    always @(posedge wr_clk)
        rb_data <= `WRAP_SIM(#1) charbuf[rb_addr];

    // ---- reconstruct the active pixel position from DE / VSYNC ----
    reg [10:0] x, y;       // 0..SCREEN_WIDTH-1, 0..SCREEN_HEIGHT-1
    reg        de_prev;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            x <= 11'd0; y <= 11'd0; de_prev <= 1'b0;
        end else begin
            de_prev <= de_in;
            if (vsync_in) begin
                x <= 11'd0;
                y <= 11'd0;
            end else begin
                x <= de_in ? (x + 1'b1) : 11'd0;       // column of the current pixel
                if (de_prev && !de_in) y <= y + 1'b1;  // active line finished
            end
        end
    end

    wire [5:0]  col  = x[8:3];   // x / 8  (0..59)
    wire [4:0]  crow = y[8:4];   // y / 16 (0..16)
    wire [10:0] char_addr = 11'(crow * COLS + col);   // row*COLS + col

    // ---- stage 1: char-buffer read + position/video delay ----
    reg [7:0]  char_q;
    reg [3:0]  s1_grow;
    reg [2:0]  s1_gcol;
    reg        s1_de, s1_hs, s1_vs;
    reg [15:0] s1_rgb;
    always @(posedge clk) begin
        char_q  <= `WRAP_SIM(#1) charbuf[char_addr];
        s1_grow <= `WRAP_SIM(#1) y[3:0];
        s1_gcol <= `WRAP_SIM(#1) x[2:0];
        s1_de   <= `WRAP_SIM(#1) de_in;
        s1_hs   <= `WRAP_SIM(#1) hsync_in;
        s1_vs   <= `WRAP_SIM(#1) vsync_in;
        s1_rgb  <= `WRAP_SIM(#1) {r_in, g_in, b_in};
    end

    // ---- stage 2: font read + delay ----
    reg [7:0]  font_q;
    reg [2:0]  s2_gcol;
    reg        s2_de, s2_hs, s2_vs;
    reg [15:0] s2_rgb;
    always @(posedge clk) begin
        font_q  <= `WRAP_SIM(#1) font[{char_q, s1_grow}];
        s2_gcol <= `WRAP_SIM(#1) s1_gcol;
        s2_de   <= `WRAP_SIM(#1) s1_de;
        s2_hs   <= `WRAP_SIM(#1) s1_hs;
        s2_vs   <= `WRAP_SIM(#1) s1_vs;
        s2_rgb  <= `WRAP_SIM(#1) s1_rgb;
    end

    // ---- stage 3: composite + drive the pins ----
    wire pix_on = font_q[3'd7 - s2_gcol];
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            de_out <= 1'b0; hsync_out <= 1'b0; vsync_out <= 1'b0;
            r_out <= 5'd0; g_out <= 6'd0; b_out <= 5'd0;
        end else begin
            de_out    <= `WRAP_SIM(#1) s2_de;
            hsync_out <= `WRAP_SIM(#1) s2_hs;
            vsync_out <= `WRAP_SIM(#1) s2_vs;
            if (osd_en && s2_de && pix_on) begin
                r_out <= `WRAP_SIM(#1) 5'h1F;   // white glyph pixel
                g_out <= `WRAP_SIM(#1) 6'h3F;
                b_out <= `WRAP_SIM(#1) 5'h1F;
            end else begin
                r_out <= `WRAP_SIM(#1) s2_rgb[15:11];
                g_out <= `WRAP_SIM(#1) s2_rgb[10:5];
                b_out <= `WRAP_SIM(#1) s2_rgb[4:0];
            end
        end
    end

endmodule
