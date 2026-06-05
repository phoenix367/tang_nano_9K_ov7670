`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for serv_wb_cdc: SERV's ext-bus handshake crossing mcu_clk (30 MHz)
// -> sys_clk (27 MHz). Drives SERV-side reads/writes against a stubbed bus slave
// at several ack latencies and confirms address/data/we cross intact, read data
// returns, and every transaction completes (no loss/duplication) across the two
// independent (async) clocks.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;

// 30 MHz (33.333 ns) and 27 MHz (37.037 ns) -- independent, drifting phases.
reg mcu_clk = 0; always #16.667 mcu_clk = ~mcu_clk;
reg sys_clk = 0; always #18.518 sys_clk = ~sys_clk;

reg        mcu_rst, sys_rst_n;
reg        s_stb, s_we; reg [15:0] s_adr, s_dat;
wire       s_ack; wire [15:0] s_rdt;
wire       m_req, m_we; wire [15:0] m_addr, m_wdata;
reg        m_ready; reg [15:0] m_rdata;

integer errors; string module_name, str;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

serv_wb_cdc dut(
    .mcu_clk(mcu_clk), .mcu_rst(mcu_rst),
    .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr), .s_dat(s_dat),
    .s_ack(s_ack), .s_rdt(s_rdt),
    .sys_clk(sys_clk), .sys_rst_n(sys_rst_n),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_ready(m_ready), .m_rdata(m_rdata));

// ---- stubbed bus slave (sys domain): a small RAM with programmable latency ----
reg [15:0] busmem [0:255];
integer    latency, lat_cnt;
always @(posedge sys_clk or negedge sys_rst_n)
    if (!sys_rst_n) begin m_ready <= 0; lat_cnt <= 0; m_rdata <= 0; end
    else if (m_req && !m_ready) begin
        if (lat_cnt >= latency) begin
            lat_cnt <= 0; m_ready <= 1'b1;
            if (m_we) busmem[m_addr[7:0]] <= m_wdata;
            m_rdata <= m_we ? m_wdata : busmem[m_addr[7:0]];
        end else lat_cnt <= lat_cnt + 1;
    end else begin m_ready <= 0; lat_cnt <= 0; end

// ---- SERV-side access task (mcu domain) ----
task automatic serv_access(input wv, input [15:0] a, input [15:0] wd, output [15:0] rd);
    begin
        @(negedge mcu_clk);
        s_stb = 1'b1; s_we = wv; s_adr = a; s_dat = wd;
        @(posedge mcu_clk); #1;
        while (!s_ack) begin @(posedge mcu_clk); #1; end
        rd = s_rdt;
        @(negedge mcu_clk);
        s_stb = 1'b0; s_we = 1'b0;
        repeat (2) @(posedge mcu_clk);     // let the handshake return to zero
    end
endtask

reg [15:0] rd;
integer i;

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");
    mcu_rst = 1'b1; sys_rst_n = 1'b0; s_stb = 0; s_we = 0; s_adr = 0; s_dat = 0;
    latency = 0; errors = 0;
    repeat (4) @(posedge sys_clk);
    mcu_rst = 1'b0; sys_rst_n = 1'b1;
    repeat (4) @(posedge mcu_clk);

    // 1) write then read back at several ack latencies
    for (i = 0; i < 6; i = i + 1) begin
        latency = i;                       // 0 = combinational-ish ack, up to 5
        serv_access(1'b1, 16'h00E0 + i[15:0], 16'hA000 + i[15:0], rd);  // write
        serv_access(1'b0, 16'h00E0 + i[15:0], 16'h0000, rd);           // read back
        if (rd !== (16'hA000 + i[15:0])) begin
            $sformat(str, "latency %0d: read %h, expected %h", i, rd, 16'hA000 + i[15:0]);
            logger.error(module_name, str); errors = errors + 1;
        end
    end

    // 2) write-data echo (the slave echoes wdata on a write) crosses correctly
    serv_access(1'b1, 16'h0042, 16'h1234, rd);
    if (rd !== 16'h1234) begin
        $sformat(str, "write echo = %h, expected 1234", rd);
        logger.error(module_name, str); errors = errors + 1;
    end

    // 3) back-to-back accesses don't lose/duplicate (full RTZ between them)
    latency = 1;
    serv_access(1'b1, 16'h0010, 16'hBEEF, rd);
    serv_access(1'b1, 16'h0011, 16'hCAFE, rd);
    serv_access(1'b0, 16'h0010, 16'h0000, rd);
    if (rd !== 16'hBEEF) begin logger.error(module_name, "RTZ: addr 0x10 corrupted"); errors = errors + 1; end
    serv_access(1'b0, 16'h0011, 16'h0000, rd);
    if (rd !== 16'hCAFE) begin logger.error(module_name, "RTZ: addr 0x11 corrupted"); errors = errors + 1; end

    if (errors == 0) begin
        logger.info(module_name, "serv_wb_cdc: 30->27 MHz handshake crosses correctly at all latencies");
        `TEST_PASS
    end else `TEST_FAIL
end

always #5000000 begin
    logger.error(module_name, "System hangs (CDC deadlock?)"); `TEST_FAIL
end

endmodule
