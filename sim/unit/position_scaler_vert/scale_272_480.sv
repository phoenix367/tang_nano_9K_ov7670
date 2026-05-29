`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for PositionScaler_vert.
//
// The module is a purely combinational ROM: it maps a source row index to
// the number of target rows that index advances by. Rather than hard-code
// the 272-entry LUT, this test re-derives the expected behaviour from the
// same algorithm scripts/scaler_generator.py uses, so it catches any drift
// between the committed RTL and the generator:
//
//   - every increment is 1 or 2 (272 -> 480 is a < 2x upscale),
//   - the running sum of increments after position p equals
//     round(SCALE * (p + 1)), and
//   - the increments sum to exactly TARGET_PIXELS over the whole source.
//
// For SCALE = 480/272 = 30*(p+1)/17 the product is never an exact .5, so
// banker's vs round-half-up rounding never disagree here and $rtoi(x+0.5)
// reproduces Python's round() exactly.

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

localparam SOURCE = 272;
localparam TARGET = 480;

reg  [10:0] source_position;
wire [1:0]  position_increment;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

PositionScaler_vert #(
    .SOURCE_PIXELS(SOURCE),
    .TARGET_PIXELS(TARGET)
) dut (
    .source_position(source_position),
    .position_increment(position_increment)
);

initial begin
    integer p;
    integer cum;
    integer exp_cum;
    real    scale;
    string  str;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    scale = real'(TARGET) / real'(SOURCE);
    cum = 0;

    for (p = 0; p < SOURCE; p = p + 1) begin
        source_position = p[10:0];
        #1;

        if (position_increment !== 2'd1 && position_increment !== 2'd2) begin
            $sformat(str, "increment at position %0d is %0d, expected 1 or 2",
                     p, position_increment);
            logger.error(module_name, str);
            `TEST_FAIL
        end

        cum = cum + position_increment;
        exp_cum = $rtoi(scale * (p + 1) + 0.5);

        if (cum !== exp_cum) begin
            $sformat(str, "cumulative target rows after source %0d is %0d, expected %0d",
                     p, cum, exp_cum);
            logger.error(module_name, str);
            `TEST_FAIL
        end
    end

    if (cum !== TARGET) begin
        $sformat(str, "total mapped target rows %0d, expected %0d", cum, TARGET);
        logger.error(module_name, str);
        `TEST_FAIL
    end

    // Positions beyond the declared source fall through to the default
    // (the always block clears the increment to 0 before the case).
    source_position = 11'd300;
    #1;
    if (position_increment !== 2'd0) begin
        logger.error(module_name, "out-of-range source position should give increment 0");
        `TEST_FAIL
    end

    logger.info(module_name, "vertical scaler LUT matches the scaling algorithm");
    `TEST_PASS
end

endmodule
