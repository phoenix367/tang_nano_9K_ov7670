`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

import FrameUploaderTypes::*;

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam MAX_VAR_LEN = 16;
localparam NUM_ITEMS_BATCH = 16;

// Camera timing parameters
localparam CAM_PIXEL_CLK = 2;
localparam CAM_FRAME_WIDTH = 640;
localparam CAM_FRAME_HEIGHT = 480;
localparam LCD_FRAME_WIDTH = 23;
localparam LCD_FRAME_HEIGHT = 17;

localparam READ_BASE_ADDR = 1 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 1 * 32;

reg clk, reset_n;
reg fb_clk;
reg [16:0] cam_data_in;
reg cam_data_in_wr_en;

wire memory_clk;

wire queue_load_rd_en;
wire [16:0] cam_data_queue_out;
wire [16:0] cam_data_queue_out_d;
wire queue_load_empty;
wire queue_load_full;
wire queue_load_empty_d;
wire queue_load_clk;

assign #1 queue_load_empty_d = queue_load_empty;
assign #1 cam_data_queue_out_d = cam_data_queue_out;

reg init_done_0;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wire mem_cmd;
wire mem_cmd_en;

wire [20:0] mem_addr;
wire [31:0] mem_w_data;

reg [31:0] mem_r_data;
reg mem_r_data_valid;

FIFO_cam q_cam_data_in(
    .Data(cam_data_in), //input [16:0] Data
    .WrReset(~reset_n), //input WrReset
    .RdReset(~reset_n), //input RdReset
    .WrClk(clk), //input WrClk
    .RdClk(queue_load_clk), //input RdClk
    .WrEn(cam_data_in_wr_en), //input WrEn
    .RdEn(queue_load_rd_en), //input RdEn
    .Q(cam_data_queue_out), //output [16:0] Q
    .Empty(queue_load_empty), //output Empty
    .Full(queue_load_full) //output Full
);

logic[15:0] data_items[3 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 3 * 32];
logic upload_done;

initial begin
    integer i;
    logic error;
    string str;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    error = 1'b0;
    $sformat(module_name, "%m");

    $sformat(str, "Initial write address: %0h", READ_BASE_ADDR);
    logger.info(module_name, str);

    logger.info(module_name, " << Starting the Simulation >>");
    // initially values
    for (i = 0; i < $size(data_items); i = i + 1) begin
        data_items[i] = $urandom();
    end

    clk = 1'b0;

    cam_data_in_wr_en = 1'b0;
    init_done_0 = 1'b0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");

    repeat(1) @(posedge pll_lock);
    repeat(1) @(posedge clk);

    init_done_0 = 1'b1;

    if (error)
        `TEST_FAIL
    else begin
        string str;
        $sformat(str, "Pushed to FIFO %0d pixels", i);
        logger.info(module_name, str);

        repeat(1) @(posedge upload_done);
        logger.info(module_name, "Received upload done signal");

        `TEST_PASS
    end
end

always #18.519 clk=~clk;

initial begin
    logic error;
    integer download_pixels;

    error = 1'b0;
    upload_done = 1'b0;
    download_pixels = 0;

    mem_r_data = 'd0;
    mem_r_data_valid = 1'b0;

    repeat(1) @(posedge init_done_0);
    logger.info(module_name, "System initialized");

    while (download_pixels != LCD_FRAME_WIDTH * LCD_FRAME_HEIGHT && !error) begin
        repeat(1) @(posedge mem_cmd_en);
        if (mem_cmd == 1'b0) begin
            integer j;

            for (j = 0; j < 4; j = j + 1)
                repeat(1) @(posedge fb_clk);

            for (j = 0; j < 8; j = j + 1) begin
                repeat(1) @(posedge fb_clk);
                mem_r_data_valid = 1'b1;
            end

            repeat(1) @(posedge fb_clk);
            mem_r_data_valid = 1'b0;
        end
    end

    if (error)
        `TEST_FAIL
    else begin
        repeat(1) @(posedge frame_buffer.uploading_finished);
        upload_done = 1'b1;
    end
end

SDRAM_rPLL sdram_clock(.reset(~reset_n), .clkin(clk), .clkout(memory_clk), .lock(pll_lock));

VideoController #(
.MEMORY_BURST(32),
.INPUT_IMAGE_WIDTH(CAM_FRAME_WIDTH),
.INPUT_IMAGE_HEIGHT(CAM_FRAME_HEIGHT),
.OUTPUT_IMAGE_WIDTH(LCD_FRAME_WIDTH),
.OUTPUT_IMAGE_HEIGHT(LCD_FRAME_HEIGHT)
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
                      .rd_data(mem_r_data),
                      .rd_data_valid(),
                      .error(),
                      .data_mask(),

                      .load_clk_o(),
                      .load_rd_en(),
                      .load_queue_empty(1'b1),
                      .load_queue_data('d0),

                      .store_clk_o(),
                      .store_wr_en(),
                      .store_queue_full(1'b1),
                      .store_queue_data()
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

always #900000 begin
    logger.error(module_name, "System hangs");

    `TEST_FAIL
end

endmodule
