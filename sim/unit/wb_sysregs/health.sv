`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test: the health watchdog status (wd_health) is exposed over wb_sysregs
// at Modbus register 0xF9.
//
// wd_health is sourced by the `watchdog` instance in VGA_timing and threaded
// through camera_control -> the Wishbone bus -> wb_sysregs, which returns it on a
// read of 0xF9 as {11'd0, wd_health}. The bit layout is
//   [4] monitoring  [3] any_hang  [2] cam  [1] mem  [0] lcd.
//
// This test drives wb_sysregs' wd_health input directly and, for each pattern,
// reads 0xF9 over a Wishbone classic-standard cycle and checks:
//   * dat_r == {11'd0, wd_health} (each of the 5 bits maps through, upper 11 = 0);
//   * the read is non-destructive (a re-read returns the same value);
//   * a live change to wd_health is reflected on the next read (combinational).

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam [15:0] ADDR_HEALTH = 16'h00F9;

reg         clk, reset_n;
reg  [15:0] adr, dat_w;
reg         we, stb, cyc;
wire [15:0] dat_r;
wire        ack;
wire        cam_reinit;
reg  [4:0]  wd_health;

integer errors;
string  module_name, str;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wb_sysregs #(.UPTIME_DIV(8)) dut (
    .clk(clk), .reset_n(reset_n),
    .wb_adr_i(adr), .wb_dat_i(dat_w), .wb_dat_o(dat_r),
    .wb_we_i(we), .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack),
    .cam_reinit(cam_reinit), .wd_health(wd_health)
);

always #5 clk = ~clk;

// Single Wishbone classic-standard access (drive on negedge, poll ack).
task automatic wb_access(input wv, input [15:0] a, input [15:0] wd, output [15:0] rd);
    begin
        @(negedge clk);
        adr = a; dat_w = wd; we = wv; cyc = 1'b1; stb = 1'b1;
        @(posedge clk); #2;
        while (!ack) begin @(posedge clk); #2; end
        rd = dat_r;
        @(negedge clk);
        cyc = 1'b0; stb = 1'b0; we = 1'b0;
    end
endtask

task automatic wb_read(input [15:0] a, output [15:0] rd);
    begin wb_access(1'b0, a, 16'h0000, rd); end
endtask

// Drive wd_health, read 0xF9, confirm it equals {11'd0, expected}.
task automatic check_health(input [4:0] expected, input string label);
    reg [15:0] rd;
    begin
        wd_health = expected;       // drive the DUT input, let it settle
        @(negedge clk);
        wb_read(ADDR_HEALTH, rd);
        if (rd !== {11'd0, expected}) begin
            $sformat(str, "%s: 0xF9 = %h, expected %h", label, rd, {11'd0, expected});
            logger.error(module_name, str); errors = errors + 1;
        end
    end
endtask

reg [15:0] rd1, rd2;
integer i;

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk = 0; reset_n = 1; adr = 0; dat_w = 0; we = 0; stb = 0; cyc = 0;
    wd_health = 5'd0; errors = 0;

    #2 reset_n = 0;
    repeat (3) @(posedge clk);
    reset_n = 1;
    @(negedge clk);

    // 1) all-clear and all-set extremes
    check_health(5'b00000, "all clear");
    check_health(5'b11111, "all set");

    // 2) each bit individually (confirms exact bit mapping, no aliasing)
    for (i = 0; i < 5; i = i + 1)
        check_health(5'b00001 << i[2:0], $sformatf("only bit %0d", i));

    // 3) representative real states
    check_health(5'b10000, "monitoring only");                 // [4] monitoring
    check_health(5'b11000, "monitoring + any_hang");           // [4][3]
    check_health(5'b11100, "cam stalled (mon+hang+cam)");      // [4][3][2]
    check_health(5'b11010, "mem stalled (mon+hang+mem)");      // [4][3][1]
    check_health(5'b11001, "lcd stalled (mon+hang+lcd)");      // [4][3][0]

    // 4) read is non-destructive: re-read returns the same value
    wd_health = 5'b10101; @(negedge clk);
    wb_read(ADDR_HEALTH, rd1);
    wb_read(ADDR_HEALTH, rd2);
    if (rd1 !== rd2 || rd1 !== 16'h0015) begin
        $sformat(str, "non-destructive read: rd1=%h rd2=%h, expected 0015", rd1, rd2);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 5) a live change is reflected on the next read (combinational passthrough)
    wd_health = 5'b00001; @(negedge clk);
    wb_read(ADDR_HEALTH, rd1);
    wd_health = 5'b11110; @(negedge clk);
    wb_read(ADDR_HEALTH, rd2);
    if (rd1 !== 16'h0001 || rd2 !== 16'h001E) begin
        $sformat(str, "live update: before=%h after=%h, expected 0001 then 001E", rd1, rd2);
        logger.error(module_name, str); errors = errors + 1;
    end

    if (errors == 0) begin
        logger.info(module_name, "wb_sysregs exposes wd_health on 0xF9 (bit layout + passthrough correct)");
        `TEST_PASS
    end else
        `TEST_FAIL
end

always #2000000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
