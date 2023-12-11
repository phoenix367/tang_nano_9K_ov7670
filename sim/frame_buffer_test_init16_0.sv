`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

import FrameUploaderTypes::*;

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;
localparam NUM_ITEMS_CHECK = 16;

reg clk, reset_n;
reg fb_clk;
reg [16:0] cam_data_in;
reg cam_data_in_wr_en;

wire memory_clk;

wire queue_load_rd_en;
wire [16:0] cam_data_queue_out;
wire [16:0] cam_data_queue_out_d;
wire queue_load_empty;
wire queue_load_empty_d;

wire queue_load_clk;

assign #1 queue_load_empty_d = queue_load_empty;
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
    .WrClk(clk), //input WrClk
    .RdClk(queue_load_clk), //input RdClk
    .WrEn(cam_data_in_wr_en), //input WrEn
    .RdEn(queue_load_rd_en), //input RdEn
    .Q(cam_data_queue_out), //output [16:0] Q
    .Empty(queue_load_empty), //output Empty
    .Full() //output Full
);

logic[15:0] data_items[NUM_ITEMS_CHECK];

initial begin
    integer i;
    logic error;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    error = 1'b0;
    for (i = 0; i < NUM_ITEMS_CHECK; i = i + 1)
        data_items[i] = $random();

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

    for (i = 0; i < NUM_ITEMS_CHECK; i = i + 1)
        write_to_queue(1, {1'b0, data_items[i]});

    // Write start frame command
    write_to_queue(1, 17'h10000);

    init_done_0 = 1'b1;

    repeat(1) @(posedge mem_cmd_en);
    logger.info(module_name, "Received memory command");
    if (mem_cmd != 1'b1) begin
        logger.error(module_name, "Memory command invalid");
        error = 1'b1;
    end else begin
        if (mem_addr != 21'h096040) begin
            logger.error(module_name, "Invalid write address");
            error = 1'b1;
        end

        for (i = 0; i < 8 && error != 1'b1; i = i + 1) begin
            logic [31:0] expected_data;

            expected_data = {data_items[2 * i + 1], data_items[2 * i]};
            repeat(1) @(negedge fb_clk);

            if (mem_w_data != expected_data) begin
                string str;

                $sformat(str, "Write data is invalid. Got %0h, expected %0h", mem_w_data, expected_data);
                logger.error(module_name, str);
                error = 1'b1;
            end

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

        if (!error)
            logger.info(module_name, "Data sequence is ok");
    end

    repeat(1) @(posedge queue_load_rd_en);
    repeat(1) @(negedge fb_clk);

    if (cam_data_queue_out_d != 17'h10000) begin
        error = 1'b1;
        logger.error(module_name, "Unexpected FIFO output");
    end else if (queue_load_empty_d == 1'b1) begin
        error = 1'b1;
        logger.error(module_name, "Unexpected FIFO empty signal");
    end else begin
        repeat(1) @(negedge fb_clk);

        if (queue_load_empty_d == 1'b0) begin
            error = 1'b1;
            logger.error(module_name, "FIFO isn't empty");
        end else begin
            repeat(1) @(posedge frame_buffer.frame_uploader.upload_done);
            logger.info(module_name, "Received upload_done signal as expected");

            repeat(1) @(negedge fb_clk);

            if (queue_load_rd_en != 1'b0) begin
                error = 1'b1;
                logger.error(module_name, "FIFO read signal still set");
            end

            repeat(1) @(negedge fb_clk);
            if (frame_buffer.frame_uploader.upload_done != 1'b0) begin
                error = 1'b1;
                logger.error(module_name, "Unexpected uploading done signal value");
            end

            repeat(1) @(posedge frame_buffer.frame_uploader.start);
            repeat(1) @(posedge fb_clk);
            repeat(1) @(negedge fb_clk);

            if (frame_buffer.frame_uploader.start != 1'b0) begin
                error = 1'b1;
                logger.error(module_name, "Unexpected uploading start signal value");
            end

            if (mem_addr !== 21'h000000) begin
                error = 1'b1;
                logger.error(module_name, "Unexpected memory address value");
            end

            repeat(1) @(negedge fb_clk);
            if (frame_buffer.frame_uploader.state != CHECK_QUEUE) begin
                error = 1'b1;
                logger.error(module_name, "Unexpected uploading FSM state");
            end
        end
    end

    if (error)
        `TEST_FAIL
    else begin
        repeat(1) @(posedge mem_cmd_en);

        logger.error(module_name, "Unexpected cmd_en signal value");
        `TEST_FAIL
    end
end

always #18.519 clk=~clk;

SDRAM_rPLL sdram_clock(.reset(~reset_n), .clkin(clk), .clkout(memory_clk), .lock(pll_lock));

VideoController #(
.MEMORY_BURST(32)
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

always #60000 begin
    logger.info(module_name, "Memory command wasn't received");
    `TEST_PASS
end

endmodule
