`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for wb_osd (Wishbone B4 classic-standard OSD-control slave).
//
// Drives single-cycle Wishbone accesses and checks:
//   * 0xFB bit0 sets/clears osd_enable (and reads it back);
//   * 0xFC sets the char-cell cursor and reads it back;
//   * 0xFD writes a glyph at the cursor via the char-buffer write port
//     (osd_wr_en/addr/data) and auto-increments the cursor;
//   * 0xFB bit1 triggers a clear sweep that writes 0x00 to all 60*17 cells and
//     homes the cursor.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam integer OSD_CELLS = 60 * 17;     // must match wb_osd

reg         clk, reset_n;
reg  [15:0] adr, dat_w;
reg         we, stb, cyc;
wire [15:0] dat_r;
wire        ack;
wire        osd_enable, osd_wr_en;
wire [10:0] osd_wr_addr;
wire [7:0]  osd_wr_data;

integer errors;
string  module_name, str;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wb_osd dut (
    .clk(clk), .reset_n(reset_n),
    .wb_adr_i(adr), .wb_dat_i(dat_w), .wb_dat_o(dat_r),
    .wb_we_i(we), .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack),
    .osd_enable(osd_enable), .osd_wr_en(osd_wr_en),
    .osd_wr_addr(osd_wr_addr), .osd_wr_data(osd_wr_data)
);

always #5 clk = ~clk;

// monitor the char-buffer write port
reg [10:0] last_addr;
reg [7:0]  last_data;
integer    wr_count;
reg [10:0] clear_min, clear_max;
always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
        wr_count <= 0; last_addr <= 0; last_data <= 0;
        clear_min <= 11'h7FF; clear_max <= 0;
    end else if (osd_wr_en) begin
        last_addr <= osd_wr_addr; last_data <= osd_wr_data;
        wr_count  <= wr_count + 1;
        if (osd_wr_data == 8'h00) begin
            if (osd_wr_addr < clear_min) clear_min <= osd_wr_addr;
            if (osd_wr_addr > clear_max) clear_max <= osd_wr_addr;
        end
    end

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

reg [15:0] rd;

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk = 0; reset_n = 1; adr = 0; dat_w = 0; we = 0; stb = 0; cyc = 0;
    errors = 0;

    #2 reset_n = 0;
    repeat (3) @(posedge clk);
    reset_n = 1;
    @(negedge clk);

    // 1) enable bit
    wb_write(16'h00FB, 16'h0001);            // enable
    wb_read(16'h00FB, rd);
    if (rd[0] !== 1'b1 || osd_enable !== 1'b1) begin
        logger.error(module_name, "osd_enable did not set"); errors = errors + 1;
    end
    wb_write(16'h00FB, 16'h0000);            // disable
    if (osd_enable !== 1'b0) begin
        logger.error(module_name, "osd_enable did not clear"); errors = errors + 1;
    end

    // 2) cursor set + read back
    wb_write(16'h00FC, 16'd5);
    wb_read(16'h00FC, rd);
    if (rd !== 16'd5) begin
        $sformat(str, "cursor = %0d, expected 5", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 3) data write deposits a glyph at the cursor and auto-increments
    wr_count = 0;
    wb_write(16'h00FD, 16'h0041);            // 'A' at cell 5
    repeat (4) @(posedge clk);
    if (last_addr !== 11'd5 || last_data !== 8'h41) begin
        $sformat(str, "char write: addr=%0d data=%h, expected 5/41", last_addr, last_data);
        logger.error(module_name, str); errors = errors + 1;
    end
    wb_read(16'h00FC, rd);
    if (rd !== 16'd6) begin
        $sformat(str, "cursor after write = %0d, expected 6 (auto-increment)", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 4) clear sweep: blanks every cell, homes the cursor
    wr_count = 0; clear_min = 11'h7FF; clear_max = 0;
    wb_write(16'h00FB, 16'h0002);            // bit1 = clear
    // wait for the sweep to finish (OSD_CELLS writes, one per cycle)
    repeat (OSD_CELLS + 50) @(posedge clk);
    if (wr_count !== OSD_CELLS) begin
        $sformat(str, "clear wrote %0d cells, expected %0d", wr_count, OSD_CELLS);
        logger.error(module_name, str); errors = errors + 1;
    end
    if (clear_min !== 11'd0 || clear_max !== OSD_CELLS - 1) begin
        $sformat(str, "clear span = %0d..%0d, expected 0..%0d", clear_min, clear_max, OSD_CELLS - 1);
        logger.error(module_name, str); errors = errors + 1;
    end
    wb_read(16'h00FC, rd);
    if (rd !== 16'd0) begin
        $sformat(str, "cursor after clear = %0d, expected 0 (homed)", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    if (errors == 0) begin
        logger.info(module_name, "wb_osd: enable/cursor/auto-increment/clear all correct");
        `TEST_PASS
    end else
        `TEST_FAIL
end

always #5000000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
