`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for wb_gpio (Wishbone B4 classic-standard 4-pin bidirectional GPIO).
//
// Drives single-cycle Wishbone accesses and checks:
//   * reset default: gpio_dir = 0 (all inputs), 0xEA reads 0;
//   * 0xEA write sets the direction register (read-back matches, gpio_dir tracks);
//   * 0xEB write sets the output latch (gpio_out tracks);
//   * 0xEB read returns the live pad level after the 2-FF input synchroniser;
//   * single-cycle ack (ack high exactly when addressed).

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;

reg         clk, reset_n;
reg  [15:0] adr, dat_w;
reg         we, stb, cyc;
wire [15:0] dat_r;
wire        ack;
wire [3:0]  gpio_dir, gpio_out;
reg  [3:0]  gpio_in;

integer errors;
string  module_name, str;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wb_gpio dut (
    .clk(clk), .reset_n(reset_n),
    .wb_adr_i(adr), .wb_dat_i(dat_w), .wb_dat_o(dat_r),
    .wb_we_i(we), .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack),
    .gpio_dir(gpio_dir), .gpio_out(gpio_out), .gpio_in(gpio_in)
);

always #5 clk = ~clk;

task automatic wb_access(input wv, input [15:0] a, input [15:0] wd, output [15:0] rd);
    begin
        @(negedge clk);
        adr = a; dat_w = wd; we = wv; cyc = 1'b1; stb = 1'b1;
        @(posedge clk); #2;
        if (!ack) begin                 // single-cycle slave: ack must be immediate
            logger.error(module_name, "wb_gpio ack not asserted in the access cycle");
            errors = errors + 1;
        end
        while (!ack) begin @(posedge clk); #2; end
        rd = dat_r;
        @(negedge clk);
        cyc = 1'b0; stb = 1'b0; we = 1'b0;
    end
endtask

task automatic wb_read(input [15:0] a, output [15:0] rd);
    begin wb_access(1'b0, a, 16'h0000, rd); end
endtask
task automatic wb_write(input [15:0] a, input [15:0] wd);
    reg [15:0] dummy;
    begin wb_access(1'b1, a, wd, dummy); end
endtask

task automatic check(input [15:0] got, input [15:0] exp, input string what);
    begin
        if (got !== exp) begin
            $sformat(str, "%s = %h, expected %h", what, got, exp);
            logger.error(module_name, str); errors = errors + 1;
        end
    end
endtask

reg [15:0] rd;

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk = 0; reset_n = 1; adr = 0; dat_w = 0; we = 0; stb = 0; cyc = 0;
    gpio_in = 4'h0; errors = 0;

    #2 reset_n = 0;
    repeat (3) @(posedge clk);
    reset_n = 1;
    @(negedge clk);

    // 1) reset default: all pins inputs
    check({12'd0, gpio_dir}, 16'h0000, "gpio_dir at reset");
    wb_read(16'h00EA, rd);  check(rd, 16'h0000, "0xEA (DIR) at reset");

    // 2) direction register write + read-back (pins 0 and 2 -> outputs)
    wb_write(16'h00EA, 16'h0005);
    check({12'd0, gpio_dir}, 16'h0005, "gpio_dir after DIR<=5");
    wb_read(16'h00EA, rd);  check(rd, 16'h0005, "0xEA read-back");

    // 3) output latch write
    wb_write(16'h00EB, 16'h000F);
    check({12'd0, gpio_out}, 16'h000F, "gpio_out after DATA<=F");

    // 4) input read-back through the 2-FF synchroniser
    gpio_in = 4'hA;
    repeat (3) @(posedge clk);               // let the synchroniser settle
    wb_read(16'h00EB, rd);  check(rd, 16'h000A, "0xEB read = live pins (0xA)");
    gpio_in = 4'h3;
    repeat (3) @(posedge clk);
    wb_read(16'h00EB, rd);  check(rd, 16'h0003, "0xEB read tracks pins (0x3)");

    // 5) a write to another slave's address must not disturb GPIO state
    wb_write(16'h00F0, 16'h0001);            // unowned here -> ignored
    check({12'd0, gpio_dir}, 16'h0005, "gpio_dir unchanged by foreign write");
    check({12'd0, gpio_out}, 16'h000F, "gpio_out unchanged by foreign write");

    if (errors == 0) begin
        logger.info(module_name, "wb_gpio: direction/output/input + ack all correct");
        `TEST_PASS
    end else
        `TEST_FAIL
end

always #2000000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
