`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Test for PositionScaler_horz, the compact DDA horizontal-downscale kernel.
//
// As source columns stream past (one per resize_en in STATE_RESIZE),
// write_enable selects exactly TARGET_PIXELS of every SOURCE_PIXELS columns
// to keep (640 -> 363). This test runs an independent lock-step DDA reference
// and checks per-column agreement plus the global invariant that exactly
// TARGET_PIXELS keeps occur over a SOURCE_PIXELS-wide row.

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

localparam integer SOURCE = 640;
localparam integer TARGET = 363;

reg  clk;
reg  reset_n;
reg  clear_state;
reg  resize_en;
wire write_enable;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

PositionScaler_horz #(
    .SOURCE_PIXELS(SOURCE),
    .TARGET_PIXELS(TARGET)
) dut (
    .clk(clk),
    .reset_n(reset_n),
    .clear_state(clear_state),
    .resize_en(resize_en),
    .write_enable(write_enable)
);

initial begin
    integer col;
    integer ref_acc;
    integer ref_keep;
    integer keeps;
    string  str;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk         = 1'b0;
    clear_state = 1'b0;
    resize_en   = 1'b0;

    reset_n = 1'b1;
    #2;
    reset_n = 1'b0;
    repeat (2) @(posedge clk);
    reset_n = 1'b1;

    // Idle: no keeps before clear/resize.
    repeat (3) @(posedge clk);
    #2;
    if (write_enable !== 1'b0) begin
        logger.error(module_name, "write_enable high before clear_state/resize_en");
        `TEST_FAIL
    end

    // Pulse clear_state with resize_en held: IDLE -> STATE_CLEAR -> STATE_RESIZE.
    clear_state <= #1 1'b1;
    resize_en   <= #1 1'b1;
    @(posedge clk);
    #2;
    clear_state <= #1 1'b0;
    @(posedge clk);
    #2;
    // Now in STATE_RESIZE with acc = 0 (source column 0).

    ref_acc = 0;
    keeps   = 0;

    for (col = 0; col < SOURCE; col = col + 1) begin
        ref_keep = ((ref_acc + TARGET) >= SOURCE) ? 1 : 0;

        if (write_enable !== ref_keep[0]) begin
            $sformat(str, "column %0d: write_enable=%b, model=%0d (acc=%0d)",
                     col, write_enable, ref_keep, ref_acc);
            logger.error(module_name, str);
            `TEST_FAIL
        end

        if (write_enable === 1'b1)
            keeps = keeps + 1;

        ref_acc = ref_keep ? (ref_acc + TARGET - SOURCE) : (ref_acc + TARGET);

        @(posedge clk);   // resize_en advances one source column
        #2;
    end

    if (keeps !== TARGET) begin
        $sformat(str, "kept %0d of %0d source columns, expected %0d", keeps, SOURCE, TARGET);
        logger.error(module_name, str);
        `TEST_FAIL
    end

    logger.info(module_name, "horizontal kernel keeps exactly TARGET columns and matches the DDA model");
    `TEST_PASS
end

always #5 clk = ~clk;

always #200000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
