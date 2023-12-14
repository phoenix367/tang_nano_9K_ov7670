`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

localparam FRAME_WIDTH = 23;
localparam FRAME_HEIGHT = 17;

reg clk, reset_n;
reg fb_clk;
reg [16:0] cam_data_in;
reg cam_data_in_wr_en;

wire memory_clk;
wire screen_clk;

wire queue_load_rd_en;
wire [16:0] cam_data_queue_out;
wire [16:0] cam_data_queue_out_d;
wire queue_load_empty;
wire queue_load_empty_d;
wire queue_load_full;
wire queue_load_full_d;
wire queue_load_clk;

assign #1 queue_load_empty_d = queue_load_empty;
assign #1 queue_load_full_d = queue_load_full;
assign #1 cam_data_queue_out_d = cam_data_queue_out;

reg init_done_0;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

assign cam_clk = clk;

wire mem_cmd;
wire mem_cmd_en;

wire [20:0] mem_addr;
wire [31:0] mem_w_data;

FIFO_cam q_cam_data_in(
    .Data(cam_data_in), //input [16:0] Data
    .WrReset(~reset_n), //input WrReset
    .RdReset(~reset_n), //input RdReset
    .WrClk(fb_clk), //input WrClk
    .RdClk(queue_load_clk), //input RdClk
    .WrEn(cam_data_in_wr_en), //input WrEn
    .RdEn(queue_load_rd_en), //input RdEn
    .Q(cam_data_queue_out), //output [16:0] Q
    .Empty(queue_load_empty), //output Empty
    .Full(queue_load_full) //output Full
);

LCD_Controller
#(
`ifdef __ICARUS__
    .LOG_LEVEL(LOG_LEVEL)
`endif
)
lcd_controller
(
    .clk(fb_clk),
    .reset_n(reset_n),
    .queue_data_in(cam_data_queue_out),
    .queue_empty(queue_load_empty_d),

    .queue_rd_en(queue_load_rd_en),
    .queue_clk(queue_load_clk),

    .LCD_DE(),
    .LCD_HSYNC(),
    .LCD_VSYNC(),

	.LCD_B(),
	.LCD_G(),
	.LCD_R()
);

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
    init_done_0 = 1'b0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");

    @(posedge clk);

    @(posedge clk);

    // Write start frame command
    write_to_queue(1, 17'h10000);

    init_done_0 = 1'b1;

    repeat(1) @(posedge queue_load_rd_en);
    if (cam_data_queue_out_d != 17'h10000) begin
        logger.error(module_name, "Incorrect queue output");
        error = 1'b1;
    end

    repeat(1) @(posedge fb_clk);
    repeat(1) @(negedge fb_clk);

    if (queue_load_empty != 1'b1) begin
        logger.error(module_name, "Queue is not empty");
        error = 1'b1;
    end

    if (error)
        `TEST_FAIL
end

always #18.519 clk=~clk;

SDRAM_rPLL sdram_clock(
    .reset(~reset_n), 
    .clkin(clk), 
    .clkout(memory_clk), 
    .clkoutd(screen_clk),
    .lock(pll_lock)
);

always @(posedge memory_clk or negedge reset_n) begin
    if (!reset_n)
        fb_clk <= #1 1'b0;
    else if (pll_lock)
        fb_clk <= #1 ~fb_clk;
end

task write_to_queue(input integer delay, input reg[16:0] data_i);
    begin
		// wait initial delay
		repeat(delay) @(posedge clk);

        #1;
        cam_data_in = data_i;
        cam_data_in_wr_en = 1'b1;

        @(posedge clk);

        #1;
        cam_data_in_wr_en = 1'b0;
    end
endtask

always #60000 begin
    `TEST_PASS
end

endmodule
