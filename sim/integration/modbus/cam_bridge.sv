`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// End-to-end test for the Modbus -> OV7670 register bridge (Direct 1:1 mapping).
//
// Stack under test (mirrors the real CameraControl_TOP post-init path):
//   TB master UART  <->  slave UART  ->  modbus_rtu_slave (EXTERNAL_BACKEND=1)
//        be_* handshake  ->  modbus_cam_backend  ->  i2c_control_fsm
//        ->  i2c_master_top  ->  i2c_slave_model (4-byte memory, OV7670 stand-in)
//
// A Modbus master frame (built + CRC'd by the TB) drives a live SCCB transaction:
// FC06/FC10 writes store into the slave model's memory; FC03 reads fetch it back
// (returned as {8'h00, reg_byte}). cam_init_complete is tied high so the bridge
// owns the SCCB bus (the "post-init" path). The slave model's memory is only 4
// bytes deep, so the test uses register addresses 0..3.
//
// Scenarios: FC06 write+read-back, FC10 write-multiple + FC03 read-back, and an
// illegal address (>= REG_COUNT) -> exception 0x83/0x02. Every response CRC is
// checked.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam integer CLK_FREQ = 160;       // UART/Modbus timing only (small => fast sim)
localparam integer BAUD     = 10;        // CLKS_PER_BIT = 16
localparam [7:0]   SLAVE    = 8'd7;
localparam integer REG_COUNT = 243;      // 0x00..0xC9 camera + 0xF0..0xF2 status
localparam [6:0]   DEV_ADDR = 7'h21;     // OV7670 SCCB address

reg clk, reset_n;
reg cam_init;                            // backend gate (1 = post-init)

// ---- master UART (driven by the TB) <-> slave UART (modbus) ----
reg  [7:0] m_tx_data; reg m_tx_start; wire m_tx_busy; wire m_tx;
wire [7:0] m_rx_data; wire m_rx_valid;
wire       m_rx_line, s_rx_line;

wire [7:0] mb_tx_data; wire mb_tx_start; wire mb_tx_busy; wire s_tx;
wire [7:0] s_rx_data;  wire s_rx_valid; wire s_rx_perr;

assign s_rx_line = m_tx;   // master -> slave
assign m_rx_line = s_tx;   // slave  -> master

// ---- register backend handshake (slave <-> bridge) ----
wire        be_req, be_we, be_ready;
wire [15:0] be_addr, be_wdata, be_rdata;

// ---- bridge -> i2c controller ----
wire        be_store_data, be_send_data, be_recv_data;
wire [7:0]  be_din;
wire        i2c_device_rdy, i2c_data_valid;
wire [7:0]  i2c_data_out;
wire        i2c_init_done, i2c_error;

// ---- i2c controller <-> master core ----
wire       tx_en, rx_en;
wire [7:0] wr_data, rd_data;
wire [2:0] wr_addr, rd_addr;
wire       cmd_ack;
wire       cyc      = tx_en | rx_en;
wire [2:0] reg_addr = tx_en ? wr_addr : rd_addr;

// ---- open-drain SCCB bus ----
wire scl, sda;
wire scl_m_o, sda_m_o, scl_m_oen, sda_m_oen;
assign scl = scl_m_oen ? 1'bz : scl_m_o;
assign sda = sda_m_oen ? 1'bz : sda_m_o;
pullup p_scl(scl);
pullup p_sda(sda);

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
    .CLK_FREQ(CLK_FREQ), .BAUD(BAUD), .SLAVE_ADDR(SLAVE),
    .REG_COUNT(REG_COUNT), .MAX_FRAME(32), .EXTERNAL_BACKEND(1)
) dut(
    .clk(clk), .reset_n(reset_n),
    .rx_data(s_rx_data), .rx_valid(s_rx_valid), .rx_parity_error(s_rx_perr),
    .tx_data(mb_tx_data), .tx_start(mb_tx_start), .tx_busy(mb_tx_busy),
    .reg_o(), .host_we(1'b0), .host_addr(8'h0), .host_wdata(16'h0),
    .be_req(be_req), .be_we(be_we), .be_addr(be_addr), .be_wdata(be_wdata),
    .be_ready(be_ready), .be_rdata(be_rdata)
);

modbus_cam_backend #(.UPTIME_DIV(64)) cam_bridge(   // fast uptime tick for sim
    .clk(clk), .reset_n(reset_n),
    .cam_init_complete(cam_init),
    .be_req(be_req), .be_we(be_we), .be_addr(be_addr), .be_wdata(be_wdata),
    .be_ready(be_ready), .be_rdata(be_rdata),
    .store_data(be_store_data), .send_data(be_send_data), .recv_data(be_recv_data),
    .i2c_din(be_din),
    .device_rdy(i2c_device_rdy), .data_valid(i2c_data_valid), .i2c_dout(i2c_data_out),
    .busy()
);

i2c_control_fsm i2c_ctrl(
    .clk(clk), .rst_n(reset_n), .device_addr(DEV_ADDR),
    .init_done(i2c_init_done),
    .store_data(be_store_data), .load_data(1'b0),
    .send_data(be_send_data), .recv_data(be_recv_data), .data_in(be_din),
    .device_rdy(i2c_device_rdy), .error_o(i2c_error),
    .data_out(i2c_data_out), .data_valid(i2c_data_valid),
    .tx_en(tx_en), .rx_en(rx_en), .wr_data(wr_data), .wr_addr(wr_addr),
    .rd_data(rd_data), .rd_addr(rd_addr), .cmd_ack_i(cmd_ack)
);

i2c_master_top i2c_master(
    .wb_clk_i(clk), .wb_rst_i(1'b0), .arst_i(reset_n),
    .wb_dat_i(wr_data), .wb_adr_i(reg_addr), .wb_we_i(tx_en),
    .wb_stb_i(1'b1), .wb_cyc_i(cyc),
    .wb_dat_o(rd_data), .wb_ack_o(cmd_ack), .wb_inta_o(),
    .scl_pad_i(scl), .scl_pad_o(scl_m_o), .scl_padoen_o(scl_m_oen),
    .sda_pad_i(sda), .sda_pad_o(sda_m_o), .sda_padoen_o(sda_m_oen)
);

i2c_slave_model #(.I2C_ADR(DEV_ADDR)) slave(.scl(scl), .sda(sda));

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

// Send req[0..n-1] verbatim and collect the response. Unlike the pure-slave
// test, a response can be many thousand cycles away (live SCCB transaction), so
// wait for the first response byte (capped), then drain until the byte stream
// goes quiet.
task automatic txn_raw(input integer n, output integer rn);
    integer i, base, waited, idle, last;
    begin
        base = rxn;
        for (i = 0; i < n; i = i + 1) send_byte(req[i]);
        waited = 0;
        while (rxn == base && waited < 400000) begin @(posedge clk); waited = waited + 1; end
        last = rxn; idle = 0;
        while (idle < 4000) begin
            @(posedge clk);
            if (rxn != last) begin last = rxn; idle = 0; end
            else idle = idle + 1;
        end
        rn = rxn - base;
        for (i = 0; i < rn && i < 64; i = i + 1) resp[i] = rxq[base + i];
    end
endtask

// Send req[0..n-1] with an appended valid CRC, collect the response.
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
reg [15:0] u1, u2;

initial begin
    errors = 0;
    m_tx_data = 0; m_tx_start = 0;
    cam_init = 1;
    clk = 0; reset_n = 1;
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");

    #2 reset_n = 0;
    repeat (4) @(posedge clk);
    reset_n = 1;

    // wait for the i2c controller's internal init (prescale setup) to finish
    @(posedge clk); #2;
    while (!i2c_init_done) begin @(posedge clk); #2; end
    logger.info(module_name, "i2c controller init_done");

    // 1) FC06 write reg 0x01 = 0x00AB -> echo; slave.mem[1] := 0xAB
    req[0]=SLAVE; req[1]=8'h06; req[2]=8'h00; req[3]=8'h01; req[4]=8'h00; req[5]=8'hAB;
    txn(6, rn);
    check("FC06 write reg1=0x00AB", rn, 8);
    if (rn==8 && (resp[3]!==8'h01 || resp[4]!==8'h00 || resp[5]!==8'hAB)) begin
        logger.error(module_name, "FC06 echo mismatch"); errors=errors+1; end
    if (slave.mem[1] !== 8'hAB) begin
        $sformat(str, "SCCB write: slave.mem[1]=%0h, expected AB", slave.mem[1]);
        logger.error(module_name, str); errors=errors+1; end

    // 2) FC03 read reg 0x01 -> 0x00AB
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'h01; req[4]=8'h00; req[5]=8'h01;
    txn(6, rn);
    check("FC03 read reg1", rn, 7);
    if (rn==7 && (resp[2]!==8'h02 || resp[3]!==8'h00 || resp[4]!==8'hAB)) begin
        logger.error(module_name, "FC03 read value mismatch"); errors=errors+1; end

    // 3) FC10 write regs 0..2 = 0x0011,0x0022,0x0033 -> mem[0..2] := 11,22,33
    req[0]=SLAVE; req[1]=8'h10; req[2]=8'h00; req[3]=8'h00; req[4]=8'h00; req[5]=8'h03;
    req[6]=8'h06; req[7]=8'h00; req[8]=8'h11; req[9]=8'h00; req[10]=8'h22; req[11]=8'h00; req[12]=8'h33;
    txn(13, rn);
    check("FC10 write regs0-2", rn, 8);
    if (rn==8 && (resp[1]!==8'h10 || resp[5]!==8'h03)) begin
        logger.error(module_name, "FC10 response mismatch"); errors=errors+1; end
    if (slave.mem[0]!==8'h11 || slave.mem[1]!==8'h22 || slave.mem[2]!==8'h33) begin
        $sformat(str, "FC10 SCCB writes: mem[0..2]=%0h,%0h,%0h expected 11,22,33",
                 slave.mem[0], slave.mem[1], slave.mem[2]);
        logger.error(module_name, str); errors=errors+1; end

    // 4) FC03 read regs 0..2 -> 00 11 00 22 00 33
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'h00; req[4]=8'h00; req[5]=8'h03;
    txn(6, rn);
    check("FC03 read regs0-2", rn, 11);
    if (rn==11 && (resp[3]!==8'h00 || resp[4]!==8'h11 ||
                   resp[5]!==8'h00 || resp[6]!==8'h22 ||
                   resp[7]!==8'h00 || resp[8]!==8'h33)) begin
        logger.error(module_name, "FC03 multi read-back mismatch"); errors=errors+1; end

    // 5) illegal data address (reg 243, past 0x00..0xF2) -> 0x83 0x02
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'hF3; req[4]=8'h00; req[5]=8'h01;
    txn(6, rn);
    check("FC03 illegal addr", rn, 5);
    if (rn==5 && (resp[1]!==8'h83 || resp[2]!==8'h02)) begin
        logger.error(module_name, "exception (addr) mismatch"); errors=errors+1; end

    // 6) status magic 0xF0 -> 0x00A5 (served directly, no SCCB)
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'hF0; req[4]=8'h00; req[5]=8'h01;
    txn(6, rn);
    check("FC03 read magic", rn, 7);
    if (rn==7 && (resp[3]!==8'h00 || resp[4]!==8'hA5)) begin
        logger.error(module_name, "status magic mismatch (expected 0x00A5)"); errors=errors+1; end

    // 7) uptime 0xF1..0xF2 increments (free-running) -> reset detector
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'hF1; req[4]=8'h00; req[5]=8'h02;
    txn(6, rn);
    check("FC03 read uptime #1", rn, 9);
    u1 = {resp[4], resp[6]};
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'hF1; req[4]=8'h00; req[5]=8'h02;
    txn(6, rn);
    u2 = {resp[4], resp[6]};
    if (!(u2 > u1)) begin
        $sformat(str, "uptime did not advance: #1=%0d #2=%0d", u1, u2);
        logger.error(module_name, str); errors=errors+1;
    end else begin
        $sformat(str, "uptime advanced %0d -> %0d", u1, u2);
        logger.info(module_name, str);
    end

    // 8) reserved gap (0xCA, above camera, below status) -> reads 0, not an exception
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'hCA; req[4]=8'h00; req[5]=8'h01;
    txn(6, rn);
    check("FC03 reserved 0xCA", rn, 7);
    if (rn==7 && (resp[1]!==8'h03 || resp[3]!==8'h00 || resp[4]!==8'h00)) begin
        logger.error(module_name, "reserved 0xCA should read 0x0000"); errors=errors+1; end

    // 9) status is served even while camera init blocks camera registers
    cam_init = 1'b0;
    repeat (4) @(posedge clk);
    req[0]=SLAVE; req[1]=8'h03; req[2]=8'h00; req[3]=8'hF0; req[4]=8'h00; req[5]=8'h01;
    txn(6, rn);
    check("FC03 magic during init", rn, 7);
    if (rn==7 && (resp[3]!==8'h00 || resp[4]!==8'hA5)) begin
        logger.error(module_name, "status not served during init"); errors=errors+1; end
    cam_init = 1'b1;

    if (errors == 0) begin
        logger.info(module_name, "Modbus <-> OV7670 bridge: all scenarios passed");
        `TEST_PASS
    end else
        `TEST_FAIL
end

initial begin
    #200000000;
    logger.error(module_name, "Watchdog timeout -- modbus cam bridge appears to hang");
    `TEST_FAIL
end

endmodule
