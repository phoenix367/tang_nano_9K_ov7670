`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for PositionScaler_vert (stateful rounding-DDA kernel).
//
// The kernel emits, for each output row p, the number of source rows to
// advance: increment(p) = round(SCALE*(p+1)) - round(SCALE*p). Rather than
// hard-code the 272-entry sequence, this test re-derives the expected values
// from the same algorithm scripts/scaler_generator.py uses, so it catches any
// drift between the committed RTL and the generator:
//
//   - every increment is 1 or 2 (272 -> 480 is a < 2x advance),
//   - the running sum after row p equals round(SCALE*(p+1)), and
//   - the increments sum to exactly TARGET_PIXELS over the whole frame.
//
// It also checks `clear` re-inits the kernel to row 0. position_increment is
// combinational from the residual register; `advance` (pulsed once per row,
// as FrameDownloader does at each row-end) steps the DDA.
//
// For SCALE = 480/272 = 30*(p+1)/17 the product is never an exact .5, so
// banker's vs round-half-up rounding never disagree here and $rtoi(x+0.5)
// reproduces Python's round() exactly.

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

localparam SOURCE = 272;
localparam TARGET = 480;

reg         clk, reset_n;
reg         clear, advance;
wire [1:0]  position_increment;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

PositionScaler_vert #(
    .SOURCE_PIXELS(SOURCE),
    .TARGET_PIXELS(TARGET)
) dut (
    .clk(clk),
    .reset_n(reset_n),
    .clear(clear),
    .advance(advance),
    .position_increment(position_increment)
);

always #5 clk = ~clk;

// Walk all SOURCE output rows, checking each increment and the running sum.
task automatic walk_frame;
    integer p, cum, inc, exp_inc, exp_cum;
    string  str;
    begin
        cum = 0;
        for (p = 0; p < SOURCE; p = p + 1) begin
            #2;   // let the combinational output settle past the NBA
            inc     = position_increment;
            exp_inc = $rtoi(real'(TARGET)/real'(SOURCE) * (p + 1) + 0.5)
                    - $rtoi(real'(TARGET)/real'(SOURCE) *  p      + 0.5);

            if (inc !== 2'd1 && inc !== 2'd2) begin
                $sformat(str, "increment at row %0d is %0d, expected 1 or 2", p, inc);
                logger.error(module_name, str); `TEST_FAIL
            end
            if (inc !== exp_inc) begin
                $sformat(str, "increment at row %0d is %0d, expected %0d", p, inc, exp_inc);
                logger.error(module_name, str); `TEST_FAIL
            end

            cum     = cum + inc;
            exp_cum = $rtoi(real'(TARGET)/real'(SOURCE) * (p + 1) + 0.5);
            if (cum !== exp_cum) begin
                $sformat(str, "cumulative source rows after row %0d is %0d, expected %0d",
                         p, cum, exp_cum);
                logger.error(module_name, str); `TEST_FAIL
            end

            // Hold the pulse #2 past the edge so the DUT samples advance=1
            // before we deassert it (avoids the @posedge / same-edge race).
            advance = 1'b1; @(posedge clk); #2; advance = 1'b0;   // step to row p+1
        end

        if (cum !== TARGET) begin
            $sformat(str, "total mapped source rows %0d, expected %0d", cum, TARGET);
            logger.error(module_name, str); `TEST_FAIL
        end
    end
endtask

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk = 1'b0; clear = 1'b0; advance = 1'b0;
    reset_n = 1'b1; #2; reset_n = 1'b0;     // async reset -> residual = INIT (row 0)
    repeat (2) @(posedge clk); reset_n = 1'b1;
    @(posedge clk);

    // First pass from the reset state (residual already at row 0).
    walk_frame();

    // `clear` must re-init to row 0 regardless of the left-over residual.
    clear = 1'b1; @(posedge clk); #2; clear = 1'b0;
    @(posedge clk); #2;
    walk_frame();

    logger.info(module_name, "vertical scaler kernel matches the scaling algorithm");
    `TEST_PASS
end

always #2000000 begin
    logger.error(module_name, "System hangs"); `TEST_FAIL
end

endmodule
