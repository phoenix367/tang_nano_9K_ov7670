`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Integration test for modbus_rtu_slave over the UART.
//
// A TB "master" UART is cross-wired to the slave's UART (master.tx -> slave.rx,
// slave.tx -> master.rx); modbus_rtu_slave sits on the slave UART. The TB builds
// RTU request frames (with CRC), sends them byte-by-byte through the master
// UART, lets the t3.5 silence frame them, and collects the slave's response
// bytes. Tiny CLKS_PER_BIT (=16) keeps the t3.5 interval a few hundred cycles.
//
// Scenarios: write single (0x06) + read-back (0x03), write multiple (0x10) +
// read-back, illegal address exception (0x83/0x02), illegal function exception
// (0x84/0x01), and a bad-CRC frame (silently dropped -> no response). Every
// response's full-frame CRC must be 0, and a known CRC vector is pinned.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam integer CLK_FREQ = 160;
localparam integer BAUD     = 10;
localparam integer CPB      = CLK_FREQ / BAUD;   // 16
localparam [7:0]   SLAVE    = 8'd7;

reg clk, reset_n;

// master UART (driven by the TB)
reg  [7:0] m_tx_data; reg m_tx_start; wire m_tx_busy; wire m_tx;
wire [7:0] m_rx_data; wire m_rx_valid;
wire       m_rx_line, s_rx_line;

// slave UART (driven by modbus)
wire [7:0] mb_tx_data; wire mb_tx_start; wire mb_tx_busy; wire s_tx;
wire [7:0] s_rx_data;  wire s_rx_valid; wire s_rx_perr;

assign s_rx_line = m_tx;   // master -> slave
assign m_rx_line = s_tx;   // slave  -> master

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

uart #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) master_uart(
    .clk(clk), .reset_n(reset_n),
    .tx_data(m_tx_data), .tx_start(m_tx_start), .tx_busy(m_tx_busy), .tx(m_tx),
    .rx(m_rx_line), .rx_data(m_rx_data), .rx_valid(m_rx_valid),
    .rx_parity_error(), .rx_frame_error()
);

uart #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) slave_uart(
    .clk(clk), .reset_n(reset_n),
    .tx_data(mb_tx_data), .tx_start(mb_tx_start), .tx_busy(mb_tx_busy), .tx(s_tx),
    .rx(s_rx_line), .rx_data(s_rx_data), .rx_valid(s_rx_valid),
    .rx_parity_error(s_rx_perr), .rx_frame_error()
);

modbus_rtu_slave #(
    .CLK_FREQ(CLK_FREQ), .BAUD(BAUD), .SLAVE_ADDR(SLAVE), .REG_COUNT(16)
) dut(
    .clk(clk), .reset_n(reset_n),
    .rx_data(s_rx_data), .rx_valid(s_rx_valid), .rx_parity_error(s_rx_perr),
    .tx_data(mb_tx_data), .tx_start(mb_tx_start), .tx_busy(mb_tx_busy),
    .reg_o(), .host_we(1'b0), .host_addr(8'h0), .host_wdata(16'h0)
);

always #5 clk = ~clk;

// capture every byte the master UART receives (the slave's response)
reg [7:0] rxq [0:255];
integer   rxn;
always @(posedge clk or negedge reset_n)
    if (!reset_n) rxn <= 0;
    else if (m_rx_valid) begin rxq[rxn] <= m_rx_data; rxn <= rxn + 1; end

function [15:0] crc_upd(input [15:0] c0, input [7:0] b);
    logic [15:0] c; integer i;
    begin
        c = c0 ^ {8'h00, b};
        for (i = 0; i < 8; i = i + 1)
            c = c[0] ? ((c >> 1) ^ 16'hA001) : (c >> 1);
        crc_upd = c;
    end
endfunction

reg [7:0]  req  [0:63];
reg [7:0]  resp [0:63];
integer    errors;
string     str;

task automatic send_byte(input [7:0] b);
    begin
        @(posedge clk); #2;
        while (m_tx_busy) begin @(posedge clk); #2; end
        @(negedge clk); m_tx_data = b; m_tx_start = 1'b1;
        @(negedge clk); m_tx_start = 1'b0;
    end
endtask

// send req[0..n-1] verbatim (caller supplies CRC) and collect the response
task automatic txn_raw(input integer n, output integer rn);
    integer i, base;
    begin
        base = rxn;
        for (i = 0; i < n; i = i + 1) send_byte(req[i]);
        repeat (8000) @(posedge clk);          // t3.5 frame + process + response
        rn = rxn - base;
        for (i = 0; i < rn && i < 64; i = i + 1) resp[i] = rxq[base + i];
    end
endtask

// send req[0..n-1] with an appended valid CRC, collect the response
task automatic txn(input integer n, output integer rn);
    integer i; reg [15:0] c;
    begin
        c = 16'hFFFF;
        for (i = 0; i < n; i = i + 1) c = crc_upd(c, req[i]);
        req[n]   = c[7:0];
        req[n+1] = c[15:8];
        txn_raw(n + 2, rn);
    end
endtask

function automatic resp_crc_ok(input integer n);
    integer i; reg [15:0] c;
    begin
        c = 16'hFFFF;
        for (i = 0; i < n; i = i + 1) c = crc_upd(c, resp[i]);
        resp_crc_ok = (c == 16'h0000);
    end
endfunction

task automatic check(input string label, input integer rn, input integer explen);
    begin
        if (rn != explen) begin
            $sformat(str, "%s: response length %0d, expected %0d", label, rn, explen);
            logger.error(module_name, str); errors = errors + 1;
        end else if (explen > 0 && !resp_crc_ok(rn)) begin
            $sformat(str, "%s: response CRC bad", label);
            logger.error(module_name, str); errors = errors + 1;
        end else begin
            $sformat(str, "%s OK", label);
            logger.info(module_name, str);
        end
    end
endtask

integer rn;
reg [15:0] cv;

initial begin
    errors = 0;
    m_tx_data = 0; m_tx_start = 0;
    clk = 0; reset_n = 1;
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");

    // pin the CRC against the canonical Modbus vector 01 03 00 00 00 01 -> 0x0A84
    cv = 16'hFFFF;
    cv = crc_upd(cv, 8'h01); cv = crc_upd(cv, 8'h03); cv = crc_upd(cv, 8'h00);
    cv = crc_upd(cv, 8'h00); cv = crc_upd(cv, 8'h00); cv = crc_upd(cv, 8'h01);
    if (cv !== 16'h0A84) begin
        $sformat(str, "CRC self-check failed: got %0h, expected 0A84", cv);
        logger.error(module_name, str); errors = errors + 1;
    end else
        logger.info(module_name, "CRC vector 01 03 00 00 00 01 = 0x0A84 OK");

    #2 reset_n = 0;
    repeat (4) @(posedge clk);
    reset_n = 1;
    repeat (4) @(posedge clk);

    // 1) write single reg 5 = 0xBEEF -> echo
    req[0]=SLAVE; req[1]=8'h06; req[2]=8'h00; req[3]=8'h05; req[4]=8'hBE; req[5]=8'hEF;
    txn(6, rn);
    check("FC06 write reg5", rn, 8);
    if (rn==8 && (resp[3]!==8'h05 || resp[4]!==8'hBE || resp[5]!==8'hEF)) begin
        logger.error(module_name, "FC06 echo mismatch"); errors=errors+1; end

    // 2) read reg 5 -> 0xBEEF
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'h05; req[4]=8'h00; req[5]=8'h01;
    txn(6, rn);
    check("FC03 read reg5", rn, 7);
    if (rn==7 && (resp[2]!==8'h02 || resp[3]!==8'hBE || resp[4]!==8'hEF)) begin
        logger.error(module_name, "FC03 read value mismatch"); errors=errors+1; end

    // 3) write multiple regs 0..2 = 1111 2222 3333
    req[0]=SLAVE; req[1]=8'h10; req[2]=8'h00; req[3]=8'h00; req[4]=8'h00; req[5]=8'h03;
    req[6]=8'h06; req[7]=8'h11; req[8]=8'h11; req[9]=8'h22; req[10]=8'h22; req[11]=8'h33; req[12]=8'h33;
    txn(13, rn);
    check("FC10 write 3 regs", rn, 8);
    if (rn==8 && (resp[1]!==8'h10 || resp[5]!==8'h03)) begin
        logger.error(module_name, "FC10 response mismatch"); errors=errors+1; end

    // read regs 0..2 back
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'h00; req[4]=8'h00; req[5]=8'h03;
    txn(6, rn);
    check("FC03 read regs0-2", rn, 11);   // addr,func,bc=6,6 data,2 crc
    if (rn==11 && (resp[3]!==8'h11 || resp[4]!==8'h11 ||
                   resp[5]!==8'h22 || resp[6]!==8'h22 ||
                   resp[7]!==8'h33 || resp[8]!==8'h33)) begin
        logger.error(module_name, "FC10 read-back mismatch"); errors=errors+1; end

    // 3c) read regs 0..5 (qty 6) -> exercises the BSRAM payload walk past the
    //     written regs (0..2 = 1111/2222/3333), the zero gap (3,4), and reg5=BEEF.
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'h00; req[4]=8'h00; req[5]=8'h06;
    txn(6, rn);
    check("FC03 read regs0-5", rn, 17);   // addr,func,bc=12,12 data,2 crc
    if (rn==17 && (resp[3]!==8'h11  || resp[4]!==8'h11  ||
                   resp[7]!==8'h33  || resp[8]!==8'h33  ||
                   resp[9]!==8'h00  || resp[10]!==8'h00 ||
                   resp[13]!==8'hBE || resp[14]!==8'hEF)) begin
        logger.error(module_name, "FC03 6-reg payload mismatch"); errors=errors+1; end

    // 4) illegal data address (reg 20 of 16) -> 0x83 0x02
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'h14; req[4]=8'h00; req[5]=8'h01;
    txn(6, rn);
    check("FC03 illegal addr", rn, 5);
    if (rn==5 && (resp[1]!==8'h83 || resp[2]!==8'h02)) begin
        logger.error(module_name, "exception (addr) mismatch"); errors=errors+1; end

    // 5) illegal function 0x04 -> 0x84 0x01
    req[0]=SLAVE; req[1]=8'h04; req[2]=8'h00; req[3]=8'h00; req[4]=8'h00; req[5]=8'h01;
    txn(6, rn);
    check("illegal function", rn, 5);
    if (rn==5 && (resp[1]!==8'h84 || resp[2]!==8'h01)) begin
        logger.error(module_name, "exception (func) mismatch"); errors=errors+1; end

    // 6) bad CRC -> no response
    req[0]=SLAVE; req[1]=8'h06; req[2]=8'h00; req[3]=8'h05; req[4]=8'hBE; req[5]=8'hEF;
    req[6]=8'h00; req[7]=8'h00;                 // deliberately wrong CRC
    txn_raw(8, rn);
    if (rn != 0) begin
        $sformat(str, "Bad-CRC frame should be dropped, got %0d response bytes", rn);
        logger.error(module_name, str); errors=errors+1;
    end else
        logger.info(module_name, "Bad-CRC frame dropped");

    if (errors == 0)
        `TEST_PASS
    else
        `TEST_FAIL
end

initial begin
    #20000000;
    logger.error(module_name, "Watchdog timeout -- modbus test hung");
    `TEST_FAIL
end

endmodule
