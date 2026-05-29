`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for device_delay.
//
// device_delay counts MAIN_CLOCK_FREQUENCY/1000 * DELAY_MS clock cycles
// after coming out of reset, then raises delay_done and holds it. A
// synchronous syn_rst restarts the count. The frequency/delay parameters
// are shrunk here so the count (MAX = 100 cycles) finishes quickly in
// simulation while still exercising the real arithmetic.
//
// State walk: reset leaves the FSM in IDLE; the first clock moves it to
// COUNT (counter = 0); COUNT increments while counter < MAX and enters
// DONE on the cycle counter reaches MAX. delay_done (combinational on the
// state) therefore asserts MAX + 2 clocks after reset is released. The
// bounds below allow a couple of cycles of slack so the test pins the
// arithmetic without being brittle about the exact edge.

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

localparam integer FREQ     = 100_000;
localparam integer DELAY_MS = 1;
localparam integer MAX      = FREQ / 1000 * DELAY_MS;  // 100

reg  clk;
reg  rst_n;
reg  syn_rst;
wire delay_done;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

device_delay #(
    .MAIN_CLOCK_FREQUENCY(FREQ),
    .DELAY_MS(DELAY_MS)
) dut (
    .clk_i(clk),
    .rst_n(rst_n),
    .syn_rst(syn_rst),
    .delay_done(delay_done)
);

// Count posedges until delay_done asserts, with a hard cap to avoid hangs.
task automatic measure_assert_cycle(output integer cycles);
    cycles = 0;
    while (delay_done !== 1'b1 && cycles < MAX * 2) begin
        @(posedge clk);
        #2;
        cycles = cycles + 1;
    end
endtask

initial begin
    integer n;
    string  str;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk     = 1'b0;
    syn_rst = 1'b0;

    rst_n = 1'b1;
    #2;
    rst_n = 1'b0;
    repeat (2) @(posedge clk);
    rst_n = 1'b1;

    // From the first clock with reset released, delay_done must stay low
    // for at least MAX cycles, then assert within a few more.
    measure_assert_cycle(n);

    if (delay_done !== 1'b1) begin
        logger.error(module_name, "delay_done never asserted");
        `TEST_FAIL
    end
    if (n < MAX + 1 || n > MAX + 3) begin
        $sformat(str, "delay_done asserted at cycle %0d, expected ~%0d (MAX+2)", n, MAX + 2);
        logger.error(module_name, str);
        `TEST_FAIL
    end

    // syn_rst must clear delay_done and restart the count.
    syn_rst <= #1 1'b1;
    @(posedge clk);
    #2;
    syn_rst <= #1 1'b0;
    @(posedge clk);
    #2;

    if (delay_done !== 1'b0) begin
        logger.error(module_name, "delay_done not cleared by syn_rst");
        `TEST_FAIL
    end

    measure_assert_cycle(n);
    if (delay_done !== 1'b1) begin
        logger.error(module_name, "delay_done did not re-assert after syn_rst restart");
        `TEST_FAIL
    end
    if (n < MAX + 1 || n > MAX + 3) begin
        $sformat(str, "post-restart delay_done asserted at cycle %0d, expected ~%0d", n, MAX + 2);
        logger.error(module_name, str);
        `TEST_FAIL
    end

    logger.info(module_name, "device_delay counts the configured cycles and restarts on syn_rst");
    `TEST_PASS
end

always #5 clk = ~clk;

// Watchdog.
always #100000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
