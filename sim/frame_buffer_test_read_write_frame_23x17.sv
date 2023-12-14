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
localparam LCD_FRAME_WIDTH = 23;
localparam LCD_FRAME_HEIGHT = 17;
/*
localparam CAM_FRAME_WIDTH = 640;
localparam CAM_FRAME_HEIGHT = 480;
localparam LCD_FRAME_WIDTH = 480;
localparam LCD_FRAME_HEIGHT = 272;
*/
reg clk, reset_n;
reg fb_clk;
reg [16:0] cam_data_in;
reg cam_data_in_wr_en;

wire memory_clk;

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

wire [20:0] mem_addr;
wire [31:0] mem_w_data;
wire [16:0] queue_data_out;
wire [16:0] queue_data_out_d;
wire queue_empty_o;

wire [16:0] cam_data_queue_out;
wire [16:0] cam_data_queue_out_d;
wire queue_load_empty;
wire queue_load_full;
wire queue_load_empty_d;
wire queue_load_clk;

assign #1 queue_load_empty_d = queue_load_empty;
assign #1 cam_data_queue_out_d = cam_data_queue_out;

assign #1 queue_data_out_d = queue_data_out;

reg [31:0] mem_r_data;
reg mem_r_data_valid;
reg queue_rd_en;

reg frame_end_signal;
logic upload_done;

integer WRITE_BASE_ADDR;

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

initial begin
    integer i;
    logic error;
    string str;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    error = 1'b0;
    queue_rd_en = 1'b0;
    upload_done = 1'b0;
    $sformat(module_name, "%m");

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

    while (!error) begin
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

initial begin
    logic error;
    integer upload_pixels;

    upload_done = 1'b0;

    repeat(1) @(posedge init_done_0);

    while (1) begin
        error = 1'b0;
        upload_pixels = 0;
        while (upload_done != 1'b0) #1;
        
        while (upload_pixels < CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT && error != 1'b1) begin
            repeat(1) @(posedge mem_cmd_en);
            if (mem_cmd != 1'b1) begin
                // Do nothing with read command
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
end

initial begin
    logic error;
    integer i;
    string str;

    error = 1'b0;
    repeat(1) @(posedge init_done_0);

    for (i = 0; i < 5; i = i + 1) begin
        case (i)
            0: WRITE_BASE_ADDR = 2 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 2 * 32;
            1: WRITE_BASE_ADDR = 0;
            2: WRITE_BASE_ADDR = 1 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 1 * 32;
            3: WRITE_BASE_ADDR = 1 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 1 * 32;
            4: WRITE_BASE_ADDR = 2 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 2 * 32;
        endcase

        $sformat(str, "Initial write address: %0h", WRITE_BASE_ADDR);
        logger.info(module_name, str);

        send_frame_to_queue(error);
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
                      .rd_data_valid(mem_r_data_valid),
                      .error(),
                      .data_mask(),

                      .load_clk_o(queue_load_clk),
                      .load_rd_en(queue_load_rd_en),
                      .load_queue_empty(queue_load_empty_d),
                      .load_queue_data(cam_data_queue_out_d),

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

initial begin
    integer col_counter, row_counter, i, frame_counter;
    integer cycles_to_wait, base_address;
    string str;

    for (frame_counter = 0; frame_counter != 5; frame_counter = frame_counter + 1) begin
        col_counter = 0;
        row_counter = 0;

        case (frame_counter)
            0, 3, 4:
                base_address = 1 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 1 * 32;
            1:
                base_address = 2 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 2 * 32;
            2:
                base_address = 'd0;
            default: begin
                logger.error(module_name, "Unknown base address for specified frame");
                `TEST_FAIL
            end
        endcase

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

        for (i = 0; i < LCD_FRAME_HEIGHT; i = i + 1) begin
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
            

            for (j = 0; j < LCD_FRAME_WIDTH; j = j + 1) begin
                logic [16:0] pixel_value;
                repeat(1) @(posedge lcd_clock);

                pixel_value = data_items[base_address + i * CAM_FRAME_WIDTH + j];
                if (pixel_value !== {1'b0, queue_data_out_d}) begin
                    string str;

                    $sformat(str, "Invalid pixel value. Got %0h, expected %0h", queue_data_out_d, pixel_value);
                    logger.error(module_name, str);
                    `TEST_FAIL
                end
            end
        end

        repeat(1) @(posedge lcd_clock);

        if (queue_data_out_d != 17'h1FFFF) begin
            logger.error(module_name, "Frame stop sequence not found");

            `TEST_FAIL
        end else begin
            logger.info(module_name, "Frame end");
        end
        queue_rd_en = #1 1'b0;
    end

    frame_end_signal = 1'b1;
end

initial begin
    repeat(1) @(posedge lcd_clock);

    #1;
    repeat(1) @(posedge queue_empty_o);
    if (!frame_end_signal) begin
        //logger.error(module_name, "Output queue emitted unexpected empty signal");

        //`TEST_FAIL
    end
end

task send_frame_to_queue(output logic error);
    integer i;

    logger.info(module_name, "Start pushing frame to FIFO");
    error = 1'b0;
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

    if (!error) begin
        string str;
        $sformat(str, "Pushed to FIFO %0d pixels", i);
        logger.info(module_name, str);

        repeat(1) @(posedge upload_done);
        logger.info(module_name, "Received upload done signal");
        
        upload_done = #1 1'b0;
    end else
        `TEST_FAIL
endtask

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
