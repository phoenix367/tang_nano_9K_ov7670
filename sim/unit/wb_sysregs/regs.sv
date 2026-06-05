`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for wb_sysregs (Wishbone B4 classic-standard system-status slave).
//
// Drives single-cycle Wishbone accesses and checks:
//   * 0xF0 reads the firmware magic 0x00A5;
//   * 0xF9 passes the watchdog health bits through;
//   * 0xFA write bit0 pulses cam_reinit for exactly one cycle;
//   * the uptime counter free-runs and advances, and a 0xF1 (hi) read latches the
//     counter so the following 0xF2 (lo) read returns a coherent pair;
//   * an owned-but-unwritten address (0xFA read) returns 0.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam integer UPTIME_DIV = 8;          // fast tick for sim

reg         clk, reset_n;
reg  [15:0] adr, dat_w;
reg         we, stb, cyc;
wire [15:0] dat_r;
wire        ack;
wire        cam_reinit;
wire        mcu_reset;
reg  [4:0]  wd_health;

integer errors;
string  module_name, str;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wb_sysregs #(.UPTIME_DIV(UPTIME_DIV)) dut (
    .clk(clk), .reset_n(reset_n),
    .wb_adr_i(adr), .wb_dat_i(dat_w), .wb_dat_o(dat_r),
    .wb_we_i(we), .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack),
    .cam_reinit(cam_reinit), .mcu_reset(mcu_reset), .wd_health(wd_health)
);

always #5 clk = ~clk;

// count cam_reinit assertions to confirm a single-cycle pulse
integer reinit_cnt;
always @(posedge clk or negedge reset_n)
    if (!reset_n) reinit_cnt <= 0;
    else if (cam_reinit) reinit_cnt <= reinit_cnt + 1;

// count mcu_reset assertions to confirm a single-cycle pulse (0xE2)
integer mcu_reset_cnt;
always @(posedge clk or negedge reset_n)
    if (!reset_n) mcu_reset_cnt <= 0;
    else if (mcu_reset) mcu_reset_cnt <= mcu_reset_cnt + 1;

// Single Wishbone classic-standard access. Drives on the negedge so the DUT
// samples cleanly on the posedge; polls ack (combinational or wait-stated).
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

task automatic wb_write(input [15:0] a, input [15:0] wd);
    reg [15:0] dummy;
    begin wb_access(1'b1, a, wd, dummy); end
endtask

reg [15:0] rd, hi1, lo1, hi2, lo2;

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk = 0; reset_n = 1; adr = 0; dat_w = 0; we = 0; stb = 0; cyc = 0;
    wd_health = 5'b10101; errors = 0;

    #2 reset_n = 0;
    repeat (3) @(posedge clk);
    reset_n = 1;
    @(negedge clk);

    // 1) firmware magic
    wb_read(16'h00F0, rd);
    if (rd !== 16'h00A5) begin
        $sformat(str, "magic 0xF0 = %h, expected 00A5", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 2) watchdog health passthrough
    wb_read(16'h00F9, rd);
    if (rd !== {11'd0, wd_health}) begin
        $sformat(str, "health 0xF9 = %h, expected %h", rd, {11'd0, wd_health});
        logger.error(module_name, str); errors = errors + 1;
    end

    // 3) reinit pulse on 0xFA bit0 (exactly one cycle)
    reinit_cnt = 0;
    wb_write(16'h00FA, 16'h0001);
    repeat (4) @(posedge clk);
    if (reinit_cnt !== 1) begin
        $sformat(str, "cam_reinit pulsed %0d times, expected exactly 1", reinit_cnt);
        logger.error(module_name, str); errors = errors + 1;
    end
    // a write WITHOUT bit0 must not pulse
    reinit_cnt = 0;
    wb_write(16'h00FA, 16'h0000);
    repeat (4) @(posedge clk);
    if (reinit_cnt !== 0) begin
        logger.error(module_name, "cam_reinit pulsed on a 0xFA write with bit0=0");
        errors = errors + 1;
    end
    // 0xFA reads back 0
    wb_read(16'h00FA, rd);
    if (rd !== 16'h0000) begin
        logger.error(module_name, "0xFA read should be 0"); errors = errors + 1;
    end

    // 4) uptime advances + coherent (hi-then-lo) pair
    wb_read(16'h00F1, hi1);   // latches uptime
    wb_read(16'h00F2, lo1);
    repeat (40) @(posedge clk);   // > 1 tick at UPTIME_DIV=8
    wb_read(16'h00F1, hi2);
    wb_read(16'h00F2, lo2);
    if (!({hi2[7:0], lo2[7:0]} > {hi1[7:0], lo1[7:0]})) begin
        $sformat(str, "uptime did not advance: #1=%0d #2=%0d",
                 {hi1[7:0], lo1[7:0]}, {hi2[7:0], lo2[7:0]});
        logger.error(module_name, str); errors = errors + 1;
    end else begin
        $sformat(str, "uptime advanced %0d -> %0d",
                 {hi1[7:0], lo1[7:0]}, {hi2[7:0], lo2[7:0]});
        logger.info(module_name, str);
    end

    // 5) heartbeat (0xE0): plain RW scratch (0 at reset, reads back what's written)
    wb_read(16'h00E0, rd);
    if (rd !== 16'h0000) begin
        $sformat(str, "heartbeat 0xE0 = %h at reset, expected 0000", rd);
        logger.error(module_name, str); errors = errors + 1;
    end
    wb_write(16'h00E0, 16'hBEEF);
    wb_read(16'h00E0, rd);
    if (rd !== 16'hBEEF) begin
        $sformat(str, "heartbeat 0xE0 = %h after write, expected BEEF", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 6) bootloader mailbox (0xE4 len/start, 0xE8 data/pending, 0xEC status)
    wb_read(16'h00EC, rd);                       // status: nothing yet
    if (rd[1] !== 1'b0 || rd[0] !== 1'b0) begin
        logger.error(module_name, "boot status nonzero before upload"); errors = errors + 1;
    end
    wb_write(16'h00E4, 16'd18);                  // host writes length -> start
    wb_read(16'h00EC, rd);                       // check start BEFORE consuming it
    if (rd[1] !== 1'b1) begin logger.error(module_name, "start not set after BOOT_LEN write"); errors = errors + 1; end
    wb_read(16'h00E4, rd);                        // SERV reads length -> consumes (clears start)
    if (rd !== 16'd18) begin logger.error(module_name, "boot_len readback wrong"); errors = errors + 1; end
    wb_read(16'h00EC, rd);
    if (rd[1] !== 1'b0) begin logger.error(module_name, "start not cleared by BOOT_LEN read (re-arm)"); errors = errors + 1; end
    wb_write(16'h00E8, 16'h1357);                // host writes a word -> pending
    wb_read(16'h00EC, rd);
    if (rd[0] !== 1'b1) begin logger.error(module_name, "pending not set after BOOT_DATA write"); errors = errors + 1; end
    wb_read(16'h00E8, rd);                        // SERV reads the word -> clears pending
    if (rd !== 16'h1357) begin logger.error(module_name, "boot_data readback wrong"); errors = errors + 1; end
    wb_read(16'h00EC, rd);
    if (rd[0] !== 1'b0) begin logger.error(module_name, "pending not cleared after BOOT_DATA read"); errors = errors + 1; end

    // 7) MCU reset pulse on 0xE2 bit0 (exactly one cycle), like 0xFA reinit
    mcu_reset_cnt = 0;
    wb_write(16'h00E2, 16'h0001);
    repeat (4) @(posedge clk);
    if (mcu_reset_cnt !== 1) begin
        $sformat(str, "mcu_reset pulsed %0d times, expected exactly 1", mcu_reset_cnt);
        logger.error(module_name, str); errors = errors + 1;
    end
    // a write WITHOUT bit0 must not pulse
    mcu_reset_cnt = 0;
    wb_write(16'h00E2, 16'h0000);
    repeat (4) @(posedge clk);
    if (mcu_reset_cnt !== 0) begin
        logger.error(module_name, "mcu_reset pulsed on a 0xE2 write with bit0=0");
        errors = errors + 1;
    end
    // 0xE2 reads back 0 (write-only)
    wb_read(16'h00E2, rd);
    if (rd !== 16'h0000) begin
        logger.error(module_name, "0xE2 read should be 0"); errors = errors + 1;
    end

    if (errors == 0) begin
        logger.info(module_name, "wb_sysregs: magic/health/reinit/mcu-reset/uptime/heartbeat/boot-mailbox all correct");
        `TEST_PASS
    end else
        `TEST_FAIL
end

always #2000000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
