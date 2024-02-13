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
localparam CAM_FRAME_WIDTH = 640;
localparam CAM_FRAME_HEIGHT = 480;
localparam LCD_FRAME_WIDTH = 480;
localparam LCD_FRAME_HEIGHT = 20;

localparam READ_BASE_ADDR = 0;

reg clk, reset_n;
reg fb_clk;
reg [16:0] cam_data_in;
reg cam_data_in_wr_en;

wire memory_clk;
wire cam_clk_o;
wire cam_wr_en;

wire queue_load_rd_en;
wire [16:0] cam_data_out;
wire cam_out_full;
wire cam_out_full_d;

assign #1 cam_out_full_d = cam_out_full;

reg init_done_0;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wire mem_cmd;
wire mem_cmd_en;
wire lcd_clock;
wire pll_lock;

wire [20:0] mem_addr;
wire [31:0] mem_w_data;
wire [16:0] queue_data_out;
wire [16:0] queue_data_out_d;
wire queue_empty_o;

assign #1 queue_data_out_d = queue_data_out;

reg [31:0] mem_r_data;
reg mem_r_data_valid;
reg queue_rd_en;

reg frame_end_signal;
reg [10:0] source_row_counter;
wire [1:0] row_inc_o;

logic[15:0] data_items[3 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 3 * 32];

FIFO_cam q_cam_data_out(
    .Data(cam_data_out), //input [16:0] Data
    .WrReset(~reset_n), //input WrReset
    .RdReset(~reset_n), //input RdReset
    .WrClk(cam_clk_o), //input WrClk
    .RdClk(lcd_clock), //input RdClk
    .WrEn(cam_wr_en), //input WrEn
    .RdEn(queue_rd_en), //input RdEn
    .Q(queue_data_out), //output [16:0] Q
    .Empty(queue_empty_o), //output Empty
    .Full(cam_out_full) //output Full
);

initial begin
    integer i;
    logic error;
    string str;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    error = 1'b0;
    queue_rd_en = 1'b0;
    $sformat(module_name, "%m");

    $sformat(str, "Initial read address: %0h", READ_BASE_ADDR);
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

        repeat(1) @(posedge frame_end_signal);
        logger.info(module_name, "Received frame download done signal");

        `TEST_PASS
    end
end

always #18.519 clk=~clk;

initial begin
    logic error;
    integer download_pixels;

    error = 1'b0;
    download_pixels = 0;

    mem_r_data = 'd0;
    mem_r_data_valid = 1'b0;
    frame_end_signal = 1'b0;

    repeat(1) @(posedge init_done_0);
    logger.info(module_name, "System initialized");

    while (download_pixels != LCD_FRAME_WIDTH * LCD_FRAME_HEIGHT && !error) begin
        repeat(1) @(posedge mem_cmd_en);
        if (mem_cmd == 1'b0) begin
            integer j, base_addr;
            string str;

            $sformat(str, "Mem read command received. Read base address %0h", mem_addr);
            logger.debug(module_name, str);

            base_addr = mem_addr;
            for (j = 0; j < 4; j = j + 1)
                repeat(1) @(posedge fb_clk);

            for (j = 0; j < 8; j = j + 1) begin
                repeat(1) @(posedge fb_clk);
                mem_r_data_valid = #1 1'b1;
                mem_r_data = {data_items[base_addr + 2 * j + 1], data_items[base_addr + 2 * j]};
            end

            repeat(1) @(posedge fb_clk);
            mem_r_data_valid = #1 1'b0;
        end
    end

    if (error)
        `TEST_FAIL
end

SDRAM_rPLL sdram_clock(.reset(~reset_n), .clkin(clk), .clkout(memory_clk), .lock(pll_lock),
                       .clkoutd(lcd_clock));

VideoController #(
.MEMORY_BURST(32),
.INPUT_IMAGE_WIDTH(CAM_FRAME_WIDTH),
.INPUT_IMAGE_HEIGHT(CAM_FRAME_HEIGHT),
.OUTPUT_IMAGE_WIDTH(LCD_FRAME_WIDTH),
.OUTPUT_IMAGE_HEIGHT(LCD_FRAME_HEIGHT),
.ENABLE_OUTPUT_RESIZE(1)
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
                      .rd_data_valid(mem_r_data_valid),
                      .error(),
                      .data_mask(),

                      .load_clk_o(),
                      .load_read_rdy(),
                      .load_command_valid(1'b0),
                      .load_pixel_data('d0),
                      .load_mem_addr(),
                      .load_command_data(2'd0),

                      .store_clk_o(cam_clk_o),
                      .store_wr_en(cam_wr_en),
                      .store_queue_full(cam_out_full_d),
                      .store_queue_data(cam_data_out)
                  );

always @(posedge memory_clk or negedge reset_n) begin
    if (!reset_n)
        fb_clk <= #1 1'b0;
    else if (pll_lock)
        fb_clk <= #1 ~fb_clk;
end

reg [10:0] row_index;

PositionScaler_vert position_scaler_vert(
    .source_position(row_index), 
    .position_increment(row_inc_o)
);

reg [10:0] column_index;
reg [10:0] source_column_counter;
wire [1:0] col_inc_o;

PositionScaler_horz position_scaler_horz(
    .source_position(column_index), 
    .position_increment(col_inc_o)
);

initial begin
    integer col_counter, row_counter, i;
    integer cycles_to_wait, base_address;
    string str;

    col_counter = 0;
    row_counter = 0;
    base_address = 0;
    source_row_counter = 'd0;
    row_index = 'd0;
    column_index = 'd0;

    $sformat(str, "Downloaded frame base address %0h", base_address);
    logger.info(module_name, str);

    repeat(1) @(posedge cam_out_full);
    cycles_to_wait = ($urandom() % 10) + 1;

    for (i = 0; i != cycles_to_wait; i = i + 1)
        repeat(1) @(posedge lcd_clock);

    queue_rd_en = #1 1'b1;
    repeat(1) @(posedge lcd_clock);

    if (queue_data_out_d !== 17'h10000) begin
        logger.error(module_name, "Frame start sequence not found");

        `TEST_FAIL
    end else
        logger.info(module_name, "Frame start sequence received");

    for (row_index = 0; row_index < LCD_FRAME_HEIGHT; row_index = row_index + 1) begin
        integer j, delay_cycles;

        repeat(1) @(posedge lcd_clock);

        if (queue_data_out_d !== 17'h10001) begin
            logger.error(module_name, "Row start sequence not found");

            `TEST_FAIL
        end

        delay_cycles = ($urandom() % 10) + 1;
        queue_rd_en = 1'b0;
        for (j = 0; j < LCD_FRAME_WIDTH; j = j + 1)
            repeat(1) @(posedge lcd_clock);
        queue_rd_en = 1'b1;
        source_column_counter = 'd0;

        for (column_index = 0; column_index < LCD_FRAME_WIDTH; column_index = column_index + 1) begin
            logic [16:0] pixel_value;
            integer read_address;

            repeat(1) @(posedge lcd_clock);

            read_address = base_address + source_row_counter * CAM_FRAME_WIDTH + source_column_counter;
            pixel_value = data_items[read_address];
            if (pixel_value !== {1'b0, queue_data_out_d}) begin
                string str;

                $sformat(str, "Invalid pixel value. Got %0h, expected %0h (row %0d, column %0d, addr %0h)", 
                    queue_data_out_d, pixel_value, source_row_counter, source_column_counter, read_address);
                logger.error(module_name, str);
                `TEST_FAIL
            end

            source_column_counter = source_column_counter + col_inc_o;
        end

        $display("%0d => %0d", row_index, source_row_counter);
        source_row_counter = source_row_counter + row_inc_o;
    end

    repeat(1) @(posedge lcd_clock);

    if (queue_data_out_d != 17'h1FFFF) begin
        logger.error(module_name, "Frame stop sequence not found");

        `TEST_FAIL
    end else begin
        logger.info(module_name, "Frame end");
        frame_end_signal = 1'b1;
    end
end

initial begin
    repeat(1) @(posedge lcd_clock);

    #1;
    repeat(1) @(posedge queue_empty_o);
    if (!frame_end_signal) begin
        logger.error(module_name, "Output queue emitted unexpected empty signal");

        `TEST_FAIL
    end
end

always #9000000 begin
    logger.error(module_name, "System hangs");

    `TEST_FAIL
end

endmodule
