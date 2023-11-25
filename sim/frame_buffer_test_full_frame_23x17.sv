`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam MAX_VAR_LEN = 16;
localparam NUM_ITEMS_BATCH = 16;

// Camera timing parameters
localparam CAM_PIXEL_CLK = 2;
localparam CAM_FRAME_WIDTH = 23;
localparam CAM_FRAME_HEIGHT = 17;

localparam WRITE_BASE_ADDR = 2 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 2 * 32;

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

logic[15:0] data_items[CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT];
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

    $sformat(str, "Initial write address: %0h", WRITE_BASE_ADDR);
    logger.info(module_name, str);

    logger.info(module_name, " << Starting the Simulation >>");
    // initially values
    for (i = 0; i < CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT; i = i + 1) begin
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

    write_to_queue(1, 17'h10000);

    for (i = 0; i < CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT && error != 1'b1; i = i + 1) begin
        logic [16:0] queue_data;

        queue_data = {1'b0, data_items[i]};
        write_to_queue(1, queue_data);

        if (queue_load_full == 1'b1) begin
            logger.error(module_name, "Unexpected queue full signal");
            error = 1'b1;
        end
    end

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
    integer upload_pixels;

    error = 1'b0;
    upload_done = 1'b0;
    upload_pixels = 0;

    repeat(1) @(posedge init_done_0);
    logger.info(module_name, "System initialized");

    while (upload_pixels < CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT && error != 1'b1) begin
        repeat(1) @(posedge mem_cmd_en);
        if (mem_cmd != 1'b1) begin
            error = 1'b1;
            logger.error(module_name, "Unexpected memory command value");
        end else begin
            integer valid_words, read_base;
            integer i;
            
            string str;

            // We use 16-bit word for memory addresation. So because
            // our pixels are also 16-bit we don't need to do any
            // adjustment for the address (convert word to byte etc.).
            valid_words = frame_buffer.frame_uploader.frame_addr_inc;
            read_base = mem_addr - WRITE_BASE_ADDR;
            if (mem_addr < WRITE_BASE_ADDR || read_base + valid_words > CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT) begin
                error = 1'b1;

                $sformat(str, "Invalid memory address: %0h", mem_addr);
                logger.error(module_name, str);
            end

            $sformat(str, "Received valid pixels: %0d", valid_words);
            logger.debug(module_name, str);
            for (i = 0; i < 8 && error != 1'b1; i = i + 1) begin
                logic [31:0] expected_data;

                repeat(1) @(negedge fb_clk);
                if (2 * i + 1 < valid_words) begin
                    expected_data = {data_items[read_base + 2 * i + 1], data_items[read_base + 2 * i]};

                    if (mem_w_data != expected_data) begin
                        string str;

                        $sformat(str, "Write data is invalid. Got %0h, expected %0h", mem_w_data, expected_data);
                        logger.error(module_name, str);
                        error = 1'b1;
                    end
                end else if (2 * i < valid_words) begin
                    expected_data = {16'h0000, data_items[read_base + 2 * i]};

                    if (mem_w_data[15:0] != expected_data[15:0]) begin
                        string str;

                        $sformat(str, "Write data is invalid. Got %0h, expected %0h", mem_w_data, expected_data);
                        logger.error(module_name, str);
                        error = 1'b1;
                    end
                end else begin
                    $sformat(str, "No check memory data %0h for base_addr = %0d", mem_w_data, 2 * i);
                    logger.debug(module_name, str);
                end

                $sformat(str, "Memory address: %0h, memory data: %0h <--> expected data: %0h", mem_addr, mem_w_data, expected_data);
                logger.debug(module_name, str);

                if (i == 0) begin
                    if (!mem_cmd_en) begin
                        logger.error(module_name, "CMD_EN signal in not set");
                        error = 1'b1;
                    end
                end else if (mem_cmd_en) begin
                    logger.error(module_name, "CMD_EN signal should not set");
                    error = 1'b1;
                end
            end

            upload_pixels = upload_pixels + valid_words;
        end
    end

    if (upload_pixels != CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT) begin
        error = 1'b1;
        logger.error(module_name, "Invalid upload plixes count");
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
.INPUT_IMAGE_HEIGHT(CAM_FRAME_HEIGHT)
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

                      .load_clk_o(queue_load_clk),
                      .load_rd_en(queue_load_rd_en),
                      .load_queue_empty(queue_load_empty_d),
                      .load_queue_data(cam_data_queue_out_d)
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
