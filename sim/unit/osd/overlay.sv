`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// OSDOverlay functional test.
//
// Drives a small synthetic LCD frame (DE/HSYNC/VSYNC + a constant input color)
// through the overlay and checks the three behaviours that matter:
//   A. OSD disabled  -> pure passthrough, no white glyph pixels.
//   B. OSD enabled, every cell blank (0x00) -> still no white pixels.
//   C. OSD enabled, every cell a printable glyph ('A') -> some white pixels,
//      and every non-white active pixel still equals the input color.
//
// The screen is shrunk to 16x32 (COLS=2, ROWS=2, 4 cells) so a full frame is a
// handful of clocks while still exercising the 8x16 glyph addressing, the
// dual-clock character-buffer write port, and the osd_enable synchronizer.

module main();

localparam integer SW = 16;     // screen width  -> COLS = 2
localparam integer SH = 32;     // screen height -> ROWS = 2
localparam integer COLS  = SW / 8;
localparam integer ROWS  = (SH + 15) / 16;
localparam integer CELLS = COLS * ROWS;

localparam [15:0] INPUT_COLOR = {5'h05, 6'h0A, 5'h15};
localparam [15:0] WHITE       = {5'h1F, 6'h3F, 5'h1F};

reg clk, wr_clk, reset_n;
reg de_in, hsync_in, vsync_in;
reg [4:0] r_in, b_in;
reg [5:0] g_in;
reg osd_enable;
reg        wr_en;
reg [10:0] wr_addr;
reg [7:0]  wr_data;

wire de_out, hsync_out, vsync_out;
wire [4:0] r_out, b_out;
wire [5:0] g_out;

string module_name;
DataLogger #(.verbosity(`SVL_VERBOSE_INFO)) logger();

OSDOverlay #(
    .SCREEN_WIDTH(SW),
    .SCREEN_HEIGHT(SH)
) dut (
    .clk(clk),
    .reset_n(reset_n),
    .de_in(de_in),
    .hsync_in(hsync_in),
    .vsync_in(vsync_in),
    .r_in(r_in),
    .g_in(g_in),
    .b_in(b_in),
    .de_out(de_out),
    .hsync_out(hsync_out),
    .vsync_out(vsync_out),
    .r_out(r_out),
    .g_out(g_out),
    .b_out(b_out),
    .osd_enable(osd_enable),
    .wr_clk(wr_clk),
    .wr_en(wr_en),
    .wr_addr(wr_addr),
    .wr_data(wr_data)
);

// ---- output monitor: count white glyph pixels and verify passthrough ----
integer white_count, active_count;
reg     check_active, fail_flag;

always @(posedge clk) begin
    if (check_active && de_out) begin
        active_count = active_count + 1;
        if ({r_out, g_out, b_out} === WHITE)
            white_count = white_count + 1;
        else if ({r_out, g_out, b_out} !== INPUT_COLOR) begin
            string str;
            $sformat(str, "Active pixel neither white nor input color: got %0h",
                     {r_out, g_out, b_out});
            logger.error(module_name, str);
            fail_flag = 1'b1;
        end
    end
end

// ---- helpers ----
task write_cells(input [7:0] code);
    integer i;
    begin
        for (i = 0; i < CELLS; i = i + 1) begin
            @(posedge wr_clk);
            wr_en   = 1'b1;
            wr_addr = i[10:0];
            wr_data = code;
        end
        @(posedge wr_clk);
        wr_en = 1'b0;
        @(posedge wr_clk);     // let the last write settle before reads
    end
endtask

task drive_frame;
    integer line, px;
    begin
        @(posedge clk);
        vsync_in = 1'b1; de_in = 1'b0;
        @(posedge clk);
        vsync_in = 1'b0;
        for (line = 0; line < SH; line = line + 1) begin
            for (px = 0; px < SW; px = px + 1) begin
                de_in    = 1'b1;
                hsync_in = 1'b0;
                r_in = INPUT_COLOR[15:11];
                g_in = INPUT_COLOR[10:5];
                b_in = INPUT_COLOR[4:0];
                @(posedge clk);
            end
            de_in = 1'b0;
            repeat (4) @(posedge clk);     // horizontal blanking -> y increments
        end
        de_in = 1'b0;
        repeat (8) @(posedge clk);         // flush the lookup pipeline
    end
endtask

task run_phase(input osd_on, input [7:0] code, input string label);
    begin
        write_cells(code);
        osd_enable = osd_on;
        repeat (6) @(posedge clk);         // let osd_enable cross the synchronizer
        white_count  = 0;
        active_count = 0;
        check_active = 1'b1;
        drive_frame();
        check_active = 1'b0;
        begin
            string str;
            $sformat(str, "%s: active=%0d white=%0d", label, active_count, white_count);
            logger.info(module_name, str);
        end
        if (active_count != SW * SH) begin
            logger.error(module_name, "Wrong active-pixel count");
            fail_flag = 1'b1;
        end
    end
endtask

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk = 0; wr_clk = 0;
    de_in = 0; hsync_in = 0; vsync_in = 0;
    r_in = 0; g_in = 0; b_in = 0;
    osd_enable = 0; wr_en = 0; wr_addr = 0; wr_data = 0;
    check_active = 0; fail_flag = 0;

    reset_n = 1'b1;
    #2 reset_n = 1'b0;
    repeat (2) @(posedge clk);
    reset_n = 1'b1;
    repeat (2) @(posedge clk);

    // Phase A: disabled -> no white pixels, pure passthrough.
    run_phase(1'b0, 8'h41, "A disabled,'A'");
    if (white_count != 0) begin
        logger.error(module_name, "OSD disabled but white pixels emitted");
        fail_flag = 1'b1;
    end

    // Phase B: enabled, all cells blank -> still no white pixels.
    run_phase(1'b1, 8'h00, "B enabled,blank");
    if (white_count != 0) begin
        logger.error(module_name, "Blank glyph produced white pixels");
        fail_flag = 1'b1;
    end

    // Phase C: enabled, printable glyph -> some white pixels.
    run_phase(1'b1, 8'h41, "C enabled,'A'");
    if (white_count == 0) begin
        logger.error(module_name, "Printable glyph produced no white pixels");
        fail_flag = 1'b1;
    end

    if (fail_flag)
        `TEST_FAIL
    else
        `TEST_PASS
end

// watchdog
initial begin
    #2_000_000;
    logger.error(module_name, "Timeout");
    `TEST_FAIL
end

always #5  clk    = ~clk;
always #7  wr_clk = ~wr_clk;     // distinct clock to exercise the dual-clock RAM

endmodule
