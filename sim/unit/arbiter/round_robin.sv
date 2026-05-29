`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for the round-robin `arbiter` (Kendall Correll's tree arbiter,
// used in the design to mediate PSRAM access between FrameUploader and
// FrameDownloader). Exercised here in its smallest configuration (width 2,
// a single arbiter_node) where the behaviour is easiest to reason about:
//
//   - no request  -> no grant, valid low
//   - one request -> that lane is granted (select tracks it), valid high
//   - both held   -> the currently-granted lane keeps the resource
//                    (a held grant is not preempted); when it releases,
//                    the other lane is granted next (round-robin fairness)
//   - grant is always one-hot
//   - enable low masks the grant outputs
//
// Grants are registered and the node can take a couple of clocks to settle
// after the inputs change, so each check samples after several clocks.

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

reg        clk;
reg        reset;
reg        enable;
reg  [1:0] req;
wire [1:0] grant;
wire       select;
wire       valid;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

arbiter #(
    .width(2),
    .select_width(1)
) dut (
    .enable(enable),
    .req(req),
    .grant(grant),
    .select(select),
    .valid(valid),
    .clock(clk),
    .reset(reset)
);

task automatic settle();
    repeat (4) @(posedge clk);
    #2;
endtask

task automatic check_grant(input [1:0] expected, input string ctx);
    string s;
    if (grant !== expected) begin
        $sformat(s, "%s: grant=%b, expected %b", ctx, grant, expected);
        logger.error(module_name, s);
        `TEST_FAIL
    end
    if (grant == 2'b11) begin
        logger.error(module_name, "grant is not one-hot");
        `TEST_FAIL
    end
endtask

initial begin
    string s;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk    = 1'b0;
    enable = 1'b1;
    req    = 2'b00;

    reset = 1'b0;
    #2;
    reset = 1'b1;
    repeat (2) @(posedge clk);
    reset = 1'b0;

    // Idle: nothing requested.
    settle();
    check_grant(2'b00, "idle");
    if (valid !== 1'b0) begin
        logger.error(module_name, "valid asserted with no request");
        `TEST_FAIL
    end

    // Single requester on lane 0.
    req = 2'b01;
    settle();
    check_grant(2'b01, "req lane 0");
    if (select !== 1'b0) begin
        logger.error(module_name, "select != 0 while granting lane 0");
        `TEST_FAIL
    end
    if (valid !== 1'b1) begin
        logger.error(module_name, "valid low while a request is granted");
        `TEST_FAIL
    end

    // Lane 1 also requests: lane 0 holds the resource (not preempted).
    req = 2'b11;
    settle();
    check_grant(2'b01, "both asserted, lane 0 holds");

    // Lane 0 releases, lane 1 keeps requesting: lane 1 gets it next.
    req = 2'b10;
    settle();
    check_grant(2'b10, "lane 1 after lane 0 release");
    if (select !== 1'b1) begin
        logger.error(module_name, "select != 1 while granting lane 1");
        `TEST_FAIL
    end

    // Both again: now lane 1 holds.
    req = 2'b11;
    settle();
    check_grant(2'b10, "both asserted, lane 1 holds");

    // enable low masks the grant.
    enable = 1'b0;
    settle();
    check_grant(2'b00, "enable low masks grant");
    enable = 1'b1;

    // All requests dropped.
    req = 2'b00;
    settle();
    check_grant(2'b00, "all requests dropped");
    if (valid !== 1'b0) begin
        logger.error(module_name, "valid asserted after all requests dropped");
        `TEST_FAIL
    end

    logger.info(module_name, "arbiter grants, holds, masks and round-robins correctly");
    `TEST_PASS
end

always #5 clk = ~clk;

always #100000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
