`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// I2C register READ test.
//
// The deployed control FSM (`i2c_control_fsm`) only ever writes -- its
// `recv_data` path is incomplete and exposes no read-data port, and the design
// ties `recv_data`/`load_data` to 0. So register reads are exercised at the
// level that actually implements them: the opencores `i2c_master_top` SCCB
// core. This TB is a small WISHBONE BFM that drives the core through the
// standard SCCB read sequence against the behavioural `i2c_slave_model`:
//
//   set pointer : START, slave-addr+W, sub-addr, STOP
//   read        : START, slave-addr+R, read 1 byte + NACK, STOP  -> RXR
//
// The slave memory is pre-seeded; the test checks the byte read back through
// the core matches. (Registers 0..3 only -- the model's 4-byte memory ACKs
// addresses <= 15.)

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam [6:0]  DEV_ADDR = 7'h21;
// 100 kHz SCL at 27 MHz: 27e6/(5*100e3)-1 = 53. The behavioural slave model
// needs realistic (slow) SCL timing -- a tiny prescaler makes it misbehave.
localparam [15:0] PRESCALE = 16'd53;

// opencores i2c register map / bits
localparam [2:0] PRER_LO = 3'h0, PRER_HI = 3'h1, CTR = 3'h2, TXR = 3'h3,
                 RXR = 3'h3, CR = 3'h4, SR = 3'h4;
localparam [7:0] CTR_EN = 8'h80;
localparam [7:0] CMD_STA_WR = 8'h90,   // STA | WR
                 CMD_WR_STO = 8'h50,   // WR  | STO
                 CMD_RD_NACK_STO = 8'h68; // RD | STO | ACK(=NACK on read)
localparam [7:0] SR_TIP = 8'h02, SR_RXACK = 8'h80;

reg clk, rst_n;

// ---- WISHBONE master interface (driven by this TB) ----
reg        wb_we, wb_stb, wb_cyc;
reg [2:0]  wb_adr;
reg [7:0]  wb_dat_i;
wire [7:0] wb_dat_o;
wire       wb_ack;

// ---- open-drain SCCB bus ----
wire scl, sda;
wire scl_m_o, sda_m_o, scl_m_oen, sda_m_oen;
assign scl = scl_m_oen ? 1'bz : scl_m_o;
assign sda = sda_m_oen ? 1'bz : sda_m_o;
pullup p_scl(scl);
pullup p_sda(sda);

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

i2c_master_top i2c_master(
    .wb_clk_i(clk), .wb_rst_i(1'b0), .arst_i(rst_n),
    .wb_dat_i(wb_dat_i), .wb_adr_i(wb_adr), .wb_we_i(wb_we),
    .wb_stb_i(wb_stb), .wb_cyc_i(wb_cyc),
    .wb_dat_o(wb_dat_o), .wb_ack_o(wb_ack), .wb_inta_o(),
    .scl_pad_i(scl), .scl_pad_o(scl_m_o), .scl_padoen_o(scl_m_oen),
    .sda_pad_i(sda), .sda_pad_o(sda_m_o), .sda_padoen_o(sda_m_oen)
);

i2c_slave_model #(.I2C_ADR(DEV_ADDR)) slave(.scl(scl), .sda(sda));

always #5 clk = ~clk;

// ---- WISHBONE register access ----
// The core latches a register write when (wb_we_i & wb_ack_o) is sampled at a
// clock edge, which is the edge AFTER ack first asserts -- so the write signals
// must be held through that edge, not dropped as soon as ack is seen.
task automatic wb_write(input [2:0] a, input [7:0] d);
    begin
        @(negedge clk);
        wb_adr = a; wb_dat_i = d; wb_we = 1'b1; wb_stb = 1'b1; wb_cyc = 1'b1;
        @(posedge clk); #2;
        while (!wb_ack) begin @(posedge clk); #2; end
        @(posedge clk); #2;          // hold through the register-latch edge
        @(negedge clk);
        wb_we = 1'b0; wb_stb = 1'b0; wb_cyc = 1'b0;
    end
endtask

task automatic wb_read(input [2:0] a, output [7:0] d);
    begin
        @(negedge clk);
        wb_adr = a; wb_we = 1'b0; wb_stb = 1'b1; wb_cyc = 1'b1;
        @(posedge clk); #2;
        while (!wb_ack) begin @(posedge clk); #2; end
        d = wb_dat_o;
        @(negedge clk);
        wb_stb = 1'b0; wb_cyc = 1'b0;
    end
endtask

// Wait for a command to finish: poll the status register until TIP asserts
// (transfer started) and then clears (transfer done).
task automatic wait_tip_done;
    logic [7:0] st;
    begin
        st = 8'h00;
        while (!(st & SR_TIP)) wb_read(SR, st);   // wait for transfer to start
        while (  st & SR_TIP ) wb_read(SR, st);   // wait for it to finish
    end
endtask

// Full SCCB read of sub-address `sub`.
task automatic sccb_read(input [7:0] sub, output [7:0] val);
    begin
        // set address pointer: START, slave-addr+W, sub-addr, STOP
        wb_write(TXR, {DEV_ADDR, 1'b0});
        wb_write(CR,  CMD_STA_WR);
        wait_tip_done;
        wb_write(TXR, sub);
        wb_write(CR,  CMD_WR_STO);
        wait_tip_done;
        // read: START, slave-addr+R, read 1 byte + NACK + STOP
        wb_write(TXR, {DEV_ADDR, 1'b1});
        wb_write(CR,  CMD_STA_WR);
        wait_tip_done;
        wb_write(CR,  CMD_RD_NACK_STO);
        wait_tip_done;
        wb_read(RXR, val);
    end
endtask

integer i, errors;
logic [7:0] seed [0:3];
logic [7:0] got;
string str;

initial begin
    errors   = 0;
    wb_we    = 1'b0;
    wb_stb   = 1'b0;
    wb_cyc   = 1'b0;
    wb_adr   = 3'h0;
    wb_dat_i = 8'h00;
    clk      = 1'b0;
    rst_n    = 1'b1;
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");

    // pre-seed the slave's register memory
    seed[0] = 8'h12; seed[1] = 8'hAB; seed[2] = 8'h5A; seed[3] = 8'hE7;
    for (i = 0; i < 4; i = i + 1) slave.mem[i] = seed[i];

    // reset (arst_i active low)
    #2 rst_n = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    // bring up the core: prescaler then enable
    wb_write(PRER_LO, PRESCALE[7:0]);
    wb_write(PRER_HI, PRESCALE[15:8]);
    wb_write(CTR, CTR_EN);
    logger.info(module_name, "I2C core enabled");

    for (i = 0; i < 4; i = i + 1) begin
        sccb_read(i[7:0], got);
        if (got !== seed[i]) begin
            $sformat(str, "Register %0d read mismatch: got %0h, expected %0h",
                     i, got, seed[i]);
            logger.error(module_name, str);
            errors = errors + 1;
        end else begin
            $sformat(str, "Read reg %0d => %0h", i, got);
            logger.info(module_name, str);
        end
    end

    if (errors == 0) begin
        logger.info(module_name, "All register reads matched the slave memory");
        `TEST_PASS
    end else
        `TEST_FAIL
end

initial begin
    #80000000;
    logger.error(module_name, "Watchdog timeout -- I2C read appears to hang");
    `TEST_FAIL
end

endmodule
