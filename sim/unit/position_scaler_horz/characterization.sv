`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Characterization test for PositionScaler_horz.
//
// Unlike PositionScaler_vert, the horizontal scaler is a clocked FSM and
// the committed RTL is hand-edited: instead of the full 480-entry table the
// generator emits, it uses `source_position % 3` to produce the repeating
// 1,2,1 increment pattern (sum 4 over 3 positions = the 640/480 = 4/3
// upscale ratio). This test pins that hand-edited behaviour with an
// independent lock-step reference so a future regeneration / refactor that
// changes the emitted write_enable stream is caught.
//
// Observable contract while resize_en is held (clear_state low):
//   - write_enable is high exactly on the cycles the FSM advances to the
//     next source position (position_increment == 1),
//   - a position whose increment is 2 inserts one extra stall cycle
//     (write_enable low) before advancing,
//   - so write_enable is high once per source position and the FSM walks
//     TARGET cycles to cross SOURCE positions.

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

localparam integer SOURCE = 480;
localparam integer TARGET = 640;
localparam integer CYCLES = 64;   // cycles of resize to characterize

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

// Reference model of the hand-edited increment pattern.
function automatic integer incr(input integer pos);
    case (pos % 3)
        0: incr = 1;
        1: incr = 2;
        2: incr = 1;
        default: incr = 0;
    endcase
endfunction

initial begin
    integer k;
    integer ref_pos;
    integer ref_pi;
    integer ref_we;
    integer we_count;
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

    // Out of reset, before any clear/resize, write_enable must stay low.
    repeat (3) @(posedge clk);
    #2;
    if (write_enable !== 1'b0) begin
        logger.error(module_name, "write_enable high before clear_state/resize_en");
        `TEST_FAIL
    end

    // Kick off: pulse clear_state with resize_en asserted, then hold
    // resize_en. The FSM walks IDLE -> STATE_CLEAR -> STATE_RESIZE.
    clear_state <= #1 1'b1;
    resize_en   <= #1 1'b1;
    @(posedge clk);
    #2;
    clear_state <= #1 1'b0;

    // Align to the first resize cycle: it is the first cycle write_enable
    // goes high (STATE_CLEAR presets increment to incr(0) = 1).
    k = 0;
    while (write_enable !== 1'b1 && k < 10) begin
        @(posedge clk);
        #2;
        k = k + 1;
    end
    if (write_enable !== 1'b1) begin
        logger.error(module_name, "FSM never produced the first write_enable pulse");
        `TEST_FAIL
    end

    // Lock-step compare. At the alignment point the reference is at
    // position 0 with increment incr(0) = 1, matching the FSM.
    ref_pos  = 0;
    ref_pi   = incr(0);
    we_count = 0;

    for (k = 0; k < CYCLES; k = k + 1) begin
        ref_we = (ref_pi == 1) ? 1 : 0;

        if (write_enable !== ref_we[0]) begin
            $sformat(str,
                "cycle %0d (source pos %0d): write_enable=%b, reference=%0d",
                k, ref_pos, write_enable, ref_we);
            logger.error(module_name, str);
            `TEST_FAIL
        end

        if (write_enable === 1'b1)
            we_count = we_count + 1;

        // Advance the reference exactly as the RTL does.
        if (ref_pi == 1) begin
            ref_pos = ref_pos + 1;
            ref_pi  = incr(ref_pos);
        end else begin
            ref_pi = ref_pi - 1;
        end

        @(posedge clk);
        #2;
    end

    // Over CYCLES cycles the FSM should have advanced exactly we_count
    // source positions (one write_enable pulse per advance) and that count
    // must equal the number of positions it actually crossed.
    if (we_count !== ref_pos) begin
        $sformat(str, "write_enable pulses %0d != source positions advanced %0d",
                 we_count, ref_pos);
        logger.error(module_name, str);
        `TEST_FAIL
    end

    logger.info(module_name, "horizontal scaler write_enable stream matches the reference model");
    `TEST_PASS
end

always #5 clk = ~clk;

always #100000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
