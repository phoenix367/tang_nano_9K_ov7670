`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

import ColorUtilities::*;

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;
localparam FRAME_WIDTH = 640;
localparam FRAME_HEIGHT = 480;

localparam NUM_COLOR_BARS = 10;
localparam Colorbar_width = FRAME_WIDTH / NUM_COLOR_BARS;

reg clk, reset_n;
reg fb_clk;
reg [16:0] cam_data_in;
reg cam_data_in_wr_en;

wire memory_clk;

reg init_done_0;
reg lcd_queue_rd_en;
reg recv_rdy = 1'b0;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wire [16:0] lcd_queue_data_in;
wire [16:0] lcd_queue_data_out;
wire lcd_queue_wr_en;
wire lcd_queue_empty;
wire lcd_queue_full;
wire pll_lock;

logic [15:0] bar_colors[NUM_COLOR_BARS];
integer row_counter, col_counter, total_pixels;

initial begin
    logic [3:0] i;
    logic [15:0] c;

    for (i = 0; i < NUM_COLOR_BARS; i = i + 1) begin
        c = get_rgb_color(i);
        bar_colors[i] = c;
    end
end

function logic [15:0] get_pixel_color(input logic [10:0] column_index);
    integer i;
    logic exit;

    get_pixel_color = 16'h0000;
    exit = 1'b0;
    for (i = 0; i < NUM_COLOR_BARS && !exit; i = i + 1)
        if (column_index < (i + 1) * Colorbar_width) begin
            get_pixel_color = bar_colors[i];
            exit = 1'b1;
        end
endfunction


DebugPatternGenerator2
#(
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT)
)

pattern_generator
(
    .clk_cam(clk),
    .clk_mem(fb_clk),
    .reset_n(reset_n),
    .init(pll_lock),
    .mem_controller_rdy(recv_rdy)
);

logic frame_checking_complete;

initial begin
    integer i;
    logic error;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    error = 1'b0;
    $sformat(module_name, "%m");

    logger.info(module_name, " << Starting the Simulation >>");
    // initially values
    clk = 0;
    cam_data_in_wr_en = 1'b0;
    frame_checking_complete = 1'b0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");

    repeat(1) @(posedge frame_checking_complete);

    if (total_pixels != FRAME_WIDTH * FRAME_HEIGHT) begin
        logger.error(module_name, "Incorrect total number of received pixels");
        `TEST_FAIL
    end

    if (row_counter != FRAME_HEIGHT) begin
        logger.error(module_name, "Incorrect total number of received frame rows");
        `TEST_FAIL
    end

    `TEST_PASS
end

always #18.519 clk=~clk;

SDRAM_rPLL sdram_clock(.reset(~reset_n), .clkin(clk), .clkout(memory_clk), .lock(pll_lock));

always @(posedge memory_clk or negedge reset_n) begin
    if (!reset_n)
        fb_clk <= #1 1'b0;
    else if (pll_lock)
        fb_clk <= #1 ~fb_clk;
end


always #500000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
