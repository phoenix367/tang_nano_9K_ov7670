`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for serv_wb_cdc: SERV's ext-bus access (mcu_clk 30 MHz) crossing to
// the register backend (sys_clk 27 MHz). SERV presents a WORD-aligned address +
// byte-enables; the CDC must resolve the register = word_addr + lane_offset(sel),
// extract the written value from that lane, and place read data at that lane --
// across the two independent (async) clocks. Covers word and byte-lane accesses
// (the latter is how SERV reaches the non-word-aligned OSD regs 0xFB/0xFD).

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;

reg mcu_clk = 0; always #16.667 mcu_clk = ~mcu_clk;   // 30 MHz
reg sys_clk = 0; always #18.518 sys_clk = ~sys_clk;   // 27 MHz

reg        mcu_rst, sys_rst_n;
reg        s_stb, s_we; reg [15:0] s_adr; reg [31:0] s_dat; reg [3:0] s_sel;
wire       s_ack; wire [31:0] s_rdt;
wire       m_req, m_we; wire [15:0] m_addr, m_wdata;
reg        m_ready; reg [15:0] m_rdata;

integer errors; string module_name, str;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

serv_wb_cdc dut(
    .mcu_clk(mcu_clk), .mcu_rst(mcu_rst),
    .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr), .s_dat(s_dat), .s_sel(s_sel),
    .s_ack(s_ack), .s_rdt(s_rdt),
    .sys_clk(sys_clk), .sys_rst_n(sys_rst_n),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_ready(m_ready), .m_rdata(m_rdata));

// ---- stubbed register-backend slave (sys domain), programmable ack latency ----
reg [15:0] regmem [0:255];
integer    latency, lat_cnt;
always @(posedge sys_clk or negedge sys_rst_n)
    if (!sys_rst_n) begin m_ready <= 0; lat_cnt <= 0; m_rdata <= 0; end
    else if (m_req && !m_ready) begin
        if (lat_cnt >= latency) begin
            lat_cnt <= 0; m_ready <= 1'b1;
            if (m_we) regmem[m_addr[7:0]] <= m_wdata;
            m_rdata <= m_we ? m_wdata : regmem[m_addr[7:0]];
        end else lat_cnt <= lat_cnt + 1;
    end else begin m_ready <= 0; lat_cnt <= 0; end

// ---- a SERV ext access: word-aligned address `wa`, byte-enables `sel`, store
//      data `d32`. Returns the 32-bit read data. ----
task automatic xact(input wv, input [15:0] wa, input [3:0] sl, input [31:0] d32,
                    output [31:0] rd);
    begin
        @(negedge mcu_clk);
        s_stb = 1'b1; s_we = wv; s_adr = wa; s_sel = sl; s_dat = d32;
        @(posedge mcu_clk); #1;
        while (!s_ack) begin @(posedge mcu_clk); #1; end
        rd = s_rdt;
        @(negedge mcu_clk);
        s_stb = 1'b0; s_we = 1'b0;
        repeat (2) @(posedge mcu_clk);
    end
endtask

task automatic check(input cond, input string msg);
    if (!cond) begin logger.error(module_name, msg); errors = errors + 1; end
endtask

reg [31:0] rd; integer i;

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");
    mcu_rst = 1'b1; sys_rst_n = 1'b0;
    s_stb = 0; s_we = 0; s_adr = 0; s_sel = 4'b1111; s_dat = 0;
    latency = 0; errors = 0;
    repeat (4) @(posedge sys_clk);
    mcu_rst = 1'b0; sys_rst_n = 1'b1;
    repeat (4) @(posedge mcu_clk);

    // 1) word round-trip (sel=1111) at word-aligned registers, several latencies
    for (i = 0; i < 5; i = i + 1) begin
        latency = i;
        xact(1'b1, 16'h00E0 + i[15:0]*4, 4'b1111, 32'hA000 + i[15:0], rd);  // write
        xact(1'b0, 16'h00E0 + i[15:0]*4, 4'b1111, 32'h0, rd);              // read back
        check(rd[15:0] === (16'hA000 + i[15:0]),
              $sformatf("word rd[%0d]=%h, expected %h", i, rd[15:0], 16'hA000 + i[15:0]));
    end

    // 2) byte lane 1 (the OSD 0xFD case): word addr 0xFC + sel 0010 -> register
    //    0xFD; value lives in dat[15:8]; a byte read at lane 1 returns it in rd[15:8].
    latency = 1;
    xact(1'b1, 16'h00FC, 4'b0010, 32'h0000_AB00, rd);   // write 0xAB to reg 0xFD
    xact(1'b0, 16'h00FC, 4'b0010, 32'h0, rd);
    check(rd[15:8] === 8'hAB, $sformatf("lane-1 byte rd=%h, expected AB in [15:8]", rd));

    // 3) byte lane 3 (the OSD 0xFB case): word addr 0xF8 + sel 1000 -> register
    //    0xFB; value in dat[31:24]; byte read at lane 3 returns it in rd[31:24].
    xact(1'b1, 16'h00F8, 4'b1000, 32'hCD00_0000, rd);   // write 0xCD to reg 0xFB
    xact(1'b0, 16'h00F8, 4'b1000, 32'h0, rd);
    check(rd[31:24] === 8'hCD, $sformatf("lane-3 byte rd=%h, expected CD in [31:24]", rd));

    // 4) the two byte writes landed at DISTINCT registers (0xFD and 0xFB), not the
    //    shared word address 0xFC/0xF8 -- the lane offset is applied to the address
    xact(1'b0, 16'h00FC, 4'b0010, 32'h0, rd);  check(rd[15:8] === 8'hAB, "reg 0xFD retained");
    xact(1'b0, 16'h00F8, 4'b1000, 32'h0, rd);  check(rd[31:24] === 8'hCD, "reg 0xFB retained");

    if (errors == 0) begin
        logger.info(module_name, "serv_wb_cdc: word + byte-lane register access crosses 30->27 MHz correctly");
        `TEST_PASS
    end else `TEST_FAIL
end

always #5000000 begin
    logger.error(module_name, "System hangs (CDC deadlock?)"); `TEST_FAIL
end

endmodule
