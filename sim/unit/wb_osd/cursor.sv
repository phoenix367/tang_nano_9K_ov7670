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

wire [10:0] osd_rb_addr;
reg  [7:0]  osd_rb_data;

wb_osd dut (
    .clk(clk), .reset_n(reset_n),
    .wb_adr_i(adr), .wb_dat_i(dat_w), .wb_dat_o(dat_r),
    .wb_we_i(we), .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack),
    .osd_enable(osd_enable), .osd_wr_en(osd_wr_en),
    .osd_wr_addr(osd_wr_addr), .osd_wr_data(osd_wr_data),
    .osd_rb_addr(osd_rb_addr), .osd_rb_data(osd_rb_data)
);

always #5 clk = ~clk;

// model OSDOverlay's char buffer: write port + registered (1-cycle) read-back,
// exactly as the RTL drives them, so 0xFD reads return what 0xFD writes stored.
reg [7:0] tb_charbuf [0:1019];
always @(posedge clk) begin
    if (osd_wr_en) tb_charbuf[osd_wr_addr] <= osd_wr_data;
    osd_rb_data <= tb_charbuf[osd_rb_addr];
end

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

    // 5) read-back: write a short run, then read it back over 0xFD. The cursor is
    //    shared, so set it, write the run, set it again, and stream reads.
    wb_write(16'h00FC, 16'd10);              // cursor = 10
    wb_write(16'h00FD, 16'h0048);            // 'H' at 10 -> cursor 11
    wb_write(16'h00FD, 16'h0049);            // 'I' at 11 -> cursor 12
    wb_write(16'h00FD, 16'h0021);            // '!' at 12 -> cursor 13
    wb_write(16'h00FC, 16'd10);              // rewind cursor to 10
    wb_read(16'h00FD, rd);                   // -> 'H', cursor 11
    if (rd !== 16'h0048) begin
        $sformat(str, "read-back[10] = %h, expected 0048 ('H')", rd);
        logger.error(module_name, str); errors = errors + 1;
    end
    wb_read(16'h00FD, rd);                   // -> 'I', cursor 12
    if (rd !== 16'h0049) begin
        $sformat(str, "read-back[11] = %h, expected 0049 ('I')", rd);
        logger.error(module_name, str); errors = errors + 1;
    end
    wb_read(16'h00FD, rd);                   // -> '!', cursor 13
    if (rd !== 16'h0021) begin
        $sformat(str, "read-back[12] = %h, expected 0021 ('!')", rd);
        logger.error(module_name, str); errors = errors + 1;
    end
    wb_read(16'h00FC, rd);                   // cursor advanced by the three reads
    if (rd !== 16'd13) begin
        $sformat(str, "cursor after read-back = %0d, expected 13", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 6) burst-read band: reads at OSD_STREAM band addresses (>=0x0800) behave
    // exactly like 0xFD reads (glyph at the cursor + auto-increment), so an FC03
    // burst over consecutive band addresses walks the buffer. Verify two adjacent
    // band addresses return consecutive cells.
    wb_write(16'h00FC, 16'd20);
    wb_write(16'h00FD, 16'h0058);            // 'X' at 20
    wb_write(16'h00FD, 16'h0059);            // 'Y' at 21
    wb_write(16'h00FC, 16'd20);              // rewind to 20
    wb_read(16'h0800, rd);                   // band read -> 'X', cursor 21
    if (rd !== 16'h0058) begin
        $sformat(str, "band read[20] = %h, expected 0058 ('X')", rd);
        logger.error(module_name, str); errors = errors + 1;
    end
    wb_read(16'h0801, rd);                   // next band addr -> 'Y', cursor 22
    if (rd !== 16'h0059) begin
        $sformat(str, "band read[21] = %h, expected 0059 ('Y')", rd);
        logger.error(module_name, str); errors = errors + 1;
    end
    wb_read(16'h00FC, rd);
    if (rd !== 16'd22) begin
        $sformat(str, "cursor after band reads = %0d, expected 22", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    if (errors == 0) begin
        logger.info(module_name, "wb_osd: enable/cursor/auto-inc/clear/read-back/burst-band all correct");
        `TEST_PASS
    end else
        `TEST_FAIL
end

always #5000000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
