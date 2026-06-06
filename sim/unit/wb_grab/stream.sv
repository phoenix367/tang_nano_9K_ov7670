`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for wb_grab (Wishbone B4 classic-standard frame-grab + stream slave).
//
// A small behavioural ch1 model stands in for psram_ch1: when grab_rd_req pulses
// it latches grab_rd_addr, raises grab_busy for a few cycles, then returns a burst
// whose 16 pixels are {base+0, base+1, ... base+15} so the streamed sequence is a
// simple ramp 0,1,2,... across bursts (base steps by 16).
//
// Checks:
//   * 0xF3 read returns {calib, busy}; write 1 pulses grab_arm, write 2 pulses
//     grab_rd_req (each exactly once);
//   * 0xF4/0xF5 load grab_rd_addr (observed on the next manual read trigger);
//   * 0xF6/0xF7 read back grab_rd_data hi/lo;
//   * a stream read (>= 0x1000) walks the ramp, crossing a burst boundary, and
//     0xF8 rewinds to pixel 0. The slave holds ack low during each burst fetch.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;

reg         clk, reset_n;
reg  [15:0] adr, dat_w;
reg         we, stb, cyc;
wire [15:0] dat_r;
wire        ack;
wire        grab_arm, grab_rd_req, grab_wr_req;
wire [31:0] grab_wr_data;
wire [20:0] grab_rd_addr;
reg         grab_busy;
reg  [255:0] grab_rd_data;
reg         grab_calib;

integer errors;
string  module_name, str;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wb_grab dut (
    .clk(clk), .reset_n(reset_n),
    .wb_adr_i(adr), .wb_dat_i(dat_w), .wb_dat_o(dat_r),
    .wb_we_i(we), .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack),
    .grab_arm(grab_arm), .grab_rd_req(grab_rd_req),
    .grab_wr_req(grab_wr_req), .grab_wr_data(grab_wr_data),
    .grab_rd_addr(grab_rd_addr),
    .grab_busy(grab_busy), .grab_rd_data(grab_rd_data), .grab_calib(grab_calib)
);

always #5 clk = ~clk;

// count the 1-cycle control pulses
integer arm_cnt, req_cnt, wr_cnt;
reg [20:0] req_addr;            // grab_rd_addr captured on a req pulse
reg [20:0] wr_addr;             // grab_rd_addr captured on a write-trigger pulse
reg [31:0] wr_val;              // grab_wr_data captured on a write-trigger pulse
always @(posedge clk or negedge reset_n)
    if (!reset_n) begin arm_cnt <= 0; req_cnt <= 0; wr_cnt <= 0;
                        req_addr <= 0; wr_addr <= 0; wr_val <= 0; end
    else begin
        if (grab_arm) arm_cnt <= arm_cnt + 1;
        if (grab_rd_req) begin req_cnt <= req_cnt + 1; req_addr <= grab_rd_addr; end
        if (grab_wr_req) begin wr_cnt <= wr_cnt + 1; wr_addr <= grab_rd_addr; wr_val <= grab_wr_data; end
    end

// behavioural ch1 model: enabled only during the stream phase so the manual
// 0xF6/0xF7 read-back test can drive grab_rd_data directly.
reg     model_en;
integer ftimer;
reg [20:0] base_l;
integer w;
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        grab_busy <= 0; ftimer <= 0; base_l <= 0;
    end else if (model_en) begin
        if (grab_rd_req && !grab_busy) begin
            base_l    <= grab_rd_addr;
            grab_busy <= 1'b1;
            ftimer    <= 4;
        end else if (grab_busy) begin
            if (ftimer > 0) ftimer <= ftimer - 1;
            else begin
                grab_busy <= 1'b0;
                for (w = 0; w < 8; w = w + 1)
                    grab_rd_data[w*32 +: 32] <=
                        {16'(base_l + 21'(2*w) + 21'd1), 16'(base_l + 21'(2*w))};
            end
        end
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
integer i;

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk = 0; reset_n = 1; adr = 0; dat_w = 0; we = 0; stb = 0; cyc = 0;
    grab_busy = 0; grab_rd_data = 0; grab_calib = 0; model_en = 0; errors = 0;

    #2 reset_n = 0;
    repeat (3) @(posedge clk);
    reset_n = 1;
    @(negedge clk);

    // 1) 0xF3 status read reflects calib/busy
    grab_calib = 1'b1;
    wb_read(16'h00F3, rd);
    if (rd[1] !== 1'b1 || rd[0] !== 1'b0) begin
        $sformat(str, "0xF3 status = %h, expected calib=1 busy=0", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 2) 0xF3 write 1 pulses grab_arm exactly once
    arm_cnt = 0;
    wb_write(16'h00F3, 16'h0001);
    repeat (4) @(posedge clk);
    if (arm_cnt !== 1) begin
        $sformat(str, "grab_arm pulsed %0d times, expected 1", arm_cnt);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 3) 0xF4/0xF5 load the read address; 0xF3 write 2 triggers a read at it
    wb_write(16'h00F4, 16'h0034);            // addr[15:0]
    wb_write(16'h00F5, 16'h0001);            // addr[20:16]
    req_cnt = 0;
    wb_write(16'h00F3, 16'h0002);            // read-trigger
    repeat (4) @(posedge clk);
    if (req_cnt !== 1 || req_addr !== 21'h10034) begin
        $sformat(str, "grab_rd_req cnt=%0d addr=%h, expected 1 / 10034", req_cnt, req_addr);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 4) 0xF6/0xF7 read back the burst hi/lo words
    grab_rd_data = 256'h0;
    grab_rd_data[31:0] = 32'hCAFE_B0BA;      // word 0
    wb_read(16'h00F6, rd);
    if (rd !== 16'hCAFE) begin
        $sformat(str, "0xF6 = %h, expected CAFE", rd);
        logger.error(module_name, str); errors = errors + 1;
    end
    wb_read(16'h00F7, rd);
    if (rd !== 16'hB0BA) begin
        $sformat(str, "0xF7 = %h, expected B0BA", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 5) stream walk: ramp 0,1,2,... across a burst boundary, then rewind
    model_en = 1'b1;
    wb_write(16'h00F8, 16'h0000);            // rewind to pixel 0
    for (i = 0; i < 20; i = i + 1) begin     // crosses the 16-pixel burst boundary
        wb_read(16'h1000, rd);
        if (rd !== i[15:0]) begin
            $sformat(str, "stream pixel %0d = %0d, expected %0d", i, rd, i);
            logger.error(module_name, str); errors = errors + 1;
        end
    end
    // rewind and confirm it restarts at 0
    wb_write(16'h00F8, 16'h0000);
    wb_read(16'h1000, rd);
    if (rd !== 16'd0) begin
        $sformat(str, "after rewind, pixel = %0d, expected 0", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 6) write path: 0xF6/0xF7 load the 32-bit write value, 0xF4/0xF5 the burst
    //    address, 0xF3 write 3 triggers grab_wr_req carrying both.
    wb_write(16'h00F6, 16'h1234);            // wr_data[31:16]
    wb_write(16'h00F7, 16'h5678);            // wr_data[15:0]
    wb_write(16'h00F4, 16'h00A0);            // addr[15:0]
    wb_write(16'h00F5, 16'h0002);            // addr[20:16]
    wr_cnt = 0;
    wb_write(16'h00F3, 16'h0003);            // write-trigger
    repeat (4) @(posedge clk);
    if (wr_cnt !== 1) begin
        $sformat(str, "grab_wr_req pulsed %0d times, expected 1", wr_cnt);
        logger.error(module_name, str); errors = errors + 1;
    end
    if (wr_val !== 32'h1234_5678) begin
        $sformat(str, "grab_wr_data = %h, expected 12345678", wr_val);
        logger.error(module_name, str); errors = errors + 1;
    end
    if (wr_addr !== 21'h200A0) begin
        $sformat(str, "write addr = %h, expected 200A0", wr_addr);
        logger.error(module_name, str); errors = errors + 1;
    end

    if (errors == 0) begin
        logger.info(module_name, "wb_grab: grab regs + stream ramp + rewind + write path all correct");
        `TEST_PASS
    end else
        `TEST_FAIL
end

always #20000000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
