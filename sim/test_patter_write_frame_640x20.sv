`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

import ColorUtilities::*;

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;
localparam FRAME_WIDTH = 640;
localparam FRAME_HEIGHT = 20;

localparam NUM_COLOR_BARS = 10;
localparam Colorbar_width = FRAME_WIDTH / NUM_COLOR_BARS;

localparam TOTAL_MEMORY_SIZE = 1 << 21;

reg clk, reset_n;
reg fb_clk;
wire pll_lock;

wire memory_clk;
wire mem_cmd;
wire mem_cmd_en;
wire [20:0] mem_addr;
wire [31:0] mem_w_data;

reg init_done_0;
reg lcd_queue_rd_en;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wire mem_load_clk;
wire load_read_rdy;
wire load_command_valid;
wire [1:0] load_command_data;
wire [31:0] load_pixel_data;
wire [9:0] load_mem_addr;

wire [16:0] lcd_queue_data_in;
wire [16:0] lcd_queue_data_out;
wire lcd_queue_wr_en;
wire lcd_queue_empty;
wire lcd_queue_full;
wire queue_load_clk;

logic [15:0] bar_colors[NUM_COLOR_BARS];
integer row_counter, col_counter, total_pixels;

logic [15:0] memory_data[TOTAL_MEMORY_SIZE];

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
    .clk_mem(mem_load_clk),
    .reset_n(reset_n),
    .init(init_done_0),
    .pixel_data(load_pixel_data),
    .command_data_valid(load_command_valid),
    .mem_controller_rdy(load_read_rdy),
    .mem_addr(load_mem_addr),
    .command_data(load_command_data)
);

logic frame_checking_complete;

initial begin
    integer i;
    logic error;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    error = 1'b0;
    init_done_0 = 1'b0;
    $sformat(module_name, "%m");

    for (i = 0; i < TOTAL_MEMORY_SIZE; i = i + 1)
        memory_data[i] = 16'h0;

    logger.info(module_name, " << Starting the Simulation >>");
    // initially values
    clk = 0;
    frame_checking_complete = 1'b0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");
    repeat(1) @(posedge pll_lock);
    init_done_0 = 1'b1;

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

VideoController #(
.MEMORY_BURST(32),
.INPUT_IMAGE_WIDTH(FRAME_WIDTH),
.INPUT_IMAGE_HEIGHT(FRAME_HEIGHT)
`ifdef __ICARUS__
, .LOG_LEVEL(LOG_LEVEL)
`endif
) frame_buffer(
                      .clk(fb_clk),
                      .rst_n(reset_n), 
                      .init_done(init_done_0),
                      .cmd(mem_cmd),
                      .cmd_en(mem_cmd_en),
                      .addr(mem_addr),
                      .wr_data(mem_w_data),
                      .rd_data(),
                      .rd_data_valid(),
                      .error(),
                      .data_mask(),

                      .load_clk_o(mem_load_clk),
                      .load_read_rdy(load_read_rdy),
                      .load_command_valid(load_command_valid),
                      .load_pixel_data(load_pixel_data),
                      .load_mem_addr(load_mem_addr),
                      .load_command_data(load_command_data),

                      .store_clk_o(),
                      .store_wr_en(),
                      .store_queue_full(1'b1),
                      .store_queue_data()
                  );

always #700000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
