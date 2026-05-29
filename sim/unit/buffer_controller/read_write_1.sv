`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

reg clk, reset_n;
reg fb_clk;

wire memory_clk;
wire pll_lock;

reg init_done_0;
reg read_rdy = 1'b0;
reg read_finalize = 1'b0;
reg write_rdy = 1'b0;
reg write_finalize = 1'b0;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wire buffer_data_valid;
wire [1:0] buffer_data;

logic frame_checking_complete;

task WriteTask(input integer expected_buffer_id);
    repeat(1) @(posedge fb_clk);

    write_rdy <= #1 1'b1;
    while (!buffer_data_valid)
        repeat(1) @(posedge fb_clk);

    if (expected_buffer_id !== buffer_data) begin
        logger.error(module_name, "Invalid write buffer index returned");
        `TEST_FAIL
    end
    write_rdy <= #1 1'b0;
    repeat(1) @(posedge fb_clk);

    while (buffer_data_valid)
        repeat(1) @(posedge fb_clk);
endtask

task WriteFinalizeTask;
    repeat(1) @(posedge fb_clk);

    write_finalize <= #1 1'b1;
    repeat(1) @(posedge fb_clk);

    write_finalize <= #1 1'b0;
    repeat(1) @(posedge fb_clk);
endtask

BufferController
#(
    .LOG_LEVEL(LOG_LEVEL)
)
buffer_controller
(
    .clk(fb_clk),
    .reset_n(reset_n),
    .write_rq_rdy(write_rdy),
    .finalize_wr(write_finalize),
    .read_rq_rdy(read_rdy),
    .finalize_rd(read_finalize),
    .buffer_id_valid(buffer_data_valid),
    .buffer_id(buffer_data)
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
    frame_checking_complete = 1'b0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");

    WriteTask('d1);

    repeat(1) @(posedge fb_clk);
    for (i = 0; i < 10; i = i + 1) begin
        read_rdy <= #1 1'b1;
        while (!buffer_data_valid)
            repeat(1) @(posedge fb_clk);

        if (i == 0) begin
            if (2'd0 !== buffer_data) begin
                logger.error(module_name, "Invalid read buffer index returned");
                `TEST_FAIL
            end
        end else begin
            if (2'd1 !== buffer_data) begin
                logger.error(module_name, "Invalid read buffer index returned");
                `TEST_FAIL
            end
        end
        read_rdy <= #1 1'b0;
        repeat(1) @(posedge fb_clk);

        while (buffer_data_valid)
            repeat(1) @(posedge fb_clk);

        read_finalize <= #1 1'b1;
        repeat(1) @(posedge fb_clk);

        read_finalize <= #1 1'b0;
        repeat(1) @(posedge fb_clk);

        WriteFinalizeTask;
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
