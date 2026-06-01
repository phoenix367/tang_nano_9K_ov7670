`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for the health watchdog.
//
// Drives the three activity heartbeats (LCD / memory / camera) and checks:
//   * while all three toggle, `hang` stays low past the startup grace and
//     several timeout windows, and `blink` keeps toggling;
//   * when one heartbeat stops, `hang` asserts within ~TIMEOUT cycles and is
//     sticky -- it stays high even though the other two remain active.
// STARTUP/TIMEOUT/BLINK are shrunk so the test runs in a few hundred cycles.

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;
localparam integer STARTUP = 30;
localparam integer TIMEOUT = 50;
localparam integer BLINK   = 3;

reg  clk, reset_n;
reg  lcd_beat, mem_beat, cam_beat;
wire hang, blink;
reg  lcd_en, mem_en, cam_en;
reg  blink_seen0, blink_seen1;
integer errors, tick;
string module_name;

DataLogger #(.verbosity(LOG_LEVEL)) logger();

watchdog #(.STARTUP(STARTUP), .TIMEOUT(TIMEOUT), .BLINK(BLINK)) dut (
    .clk(clk),
    .reset_n(reset_n),
    .beats({cam_beat, mem_beat, lcd_beat}),   // {camera, memory, lcd}
    .hang(hang),
    .blink(blink)
);

always #5 clk = ~clk;

// heartbeat generators: toggle each enabled beat every 8 clocks (< TIMEOUT)
always @(posedge clk or negedge reset_n)
    if (!reset_n)
        tick <= 0;
    else begin
        tick <= tick + 1;
        if (tick % 8 == 0) begin
            if (lcd_en) lcd_beat <= ~lcd_beat;
            if (mem_en) mem_beat <= ~mem_beat;
            if (cam_en) cam_beat <= ~cam_beat;
        end
    end

// record that blink visits both levels during operation
always @(posedge clk)
    if (reset_n) begin
        if (blink === 1'b0) blink_seen0 <= 1'b1;
        if (blink === 1'b1) blink_seen1 <= 1'b1;
    end

task automatic step(input integer n);
    begin
        repeat (n) @(posedge clk);
        #2;
    end
endtask

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk = 0; lcd_beat = 0; mem_beat = 0; cam_beat = 0;
    lcd_en = 1; mem_en = 1; cam_en = 1;
    errors = 0; blink_seen0 = 0; blink_seen1 = 0;

    reset_n = 1; #2; reset_n = 0;
    repeat (3) @(posedge clk);
    reset_n = 1;

    // --- healthy: hang must stay low past startup + several timeout windows ---
    step(STARTUP + TIMEOUT * 4);
    if (hang !== 1'b0) begin
        logger.error(module_name, "hang asserted while all subsystems were healthy");
        errors = errors + 1;
    end
    if (!(blink_seen0 && blink_seen1)) begin
        logger.error(module_name, "blink did not toggle during healthy operation");
        errors = errors + 1;
    end

    // --- stop the camera heartbeat: that monitor must time out ---
    cam_en = 1'b0;
    step(TIMEOUT + 30);
    if (hang !== 1'b1) begin
        logger.error(module_name, "hang did not assert after the camera heartbeat stopped");
        errors = errors + 1;
    end

    // --- sticky: lcd/mem still healthy, hang must stay asserted ---
    step(TIMEOUT * 2);
    if (hang !== 1'b1) begin
        logger.error(module_name, "hang not sticky -- cleared while a subsystem was still stalled");
        errors = errors + 1;
    end

    if (errors == 0) begin
        logger.info(module_name, "watchdog blinks when healthy and latches hang on a stalled subsystem");
        `TEST_PASS
    end else
        `TEST_FAIL
end

// test-harness watchdog: fail if the run never completes
always #200000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
