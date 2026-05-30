`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Integration test for the I2C controller (`i2c_control_fsm`) driving the
// opencores `i2c_master_top` SCCB core, with the behavioural `i2c_slave_model`
// as the OV7670-like target on the bus.
//
//   i2c_control_fsm  --reg r/w (tx_en/rx_en/wr_addr/...)-->  i2c_master_top
//        ^ store_data/send_data/data_in (this TB plays camera_control)
//                                                  scl/sda (open-drain) --> i2c_slave_model
//
// The TB issues register writes the same way camera_control's sequencer does:
// store the register address byte, store the value byte, then pulse send_data
// and wait for `device_rdy` to come back. It then checks the slave model
// captured each write (mem[reg] == value) and that no spurious NACK was raised.
//
// The slave model only ACKs memory addresses <= 15 and has a 4-byte memory, so
// the test writes registers 0..3 -- enough to exercise the full address-byte +
// data-byte write transaction (start, slave-addr, mem-addr, data, stop) end to
// end over real SCCB bit timing.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam [6:0] DEV_ADDR = 7'h21;   // OV7670 SCCB address (matches OV7670_ADDR)
localparam integer NUM_REGS = 4;

reg clk, rst_n;

// ---- controller command interface (driven by this TB) ----
reg        store_data, send_data;
reg [7:0]  data_in;
wire       init_done, device_rdy, error_o;

// ---- controller <-> master register interface ----
wire       tx_en, rx_en;
wire [7:0] wr_data, rd_data;
wire [2:0] wr_addr, rd_addr;
wire       cmd_ack;

// glue, identical to camera_control.v
wire       cyc      = tx_en | rx_en;
wire [2:0] reg_addr = tx_en ? wr_addr : rd_addr;

// ---- open-drain SCCB bus (master + slave + pull-ups) ----
wire scl, sda;
wire scl_m_o, sda_m_o, scl_m_oen, sda_m_oen;
assign scl = scl_m_oen ? 1'bz : scl_m_o;   // master pulls low when oen=0
assign sda = sda_m_oen ? 1'bz : sda_m_o;
pullup p_scl(scl);
pullup p_sda(sda);

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

i2c_master_top i2c_master(
    .wb_clk_i(clk), .wb_rst_i(1'b0), .arst_i(rst_n),
    .wb_dat_i(wr_data), .wb_adr_i(reg_addr), .wb_we_i(tx_en),
    .wb_stb_i(1'b1), .wb_cyc_i(cyc),
    .wb_dat_o(rd_data), .wb_ack_o(cmd_ack), .wb_inta_o(),
    .scl_pad_i(scl), .scl_pad_o(scl_m_o), .scl_padoen_o(scl_m_oen),
    .sda_pad_i(sda), .sda_pad_o(sda_m_o), .sda_padoen_o(sda_m_oen)
);

i2c_control_fsm dut(
    .clk(clk), .rst_n(rst_n), .device_addr(DEV_ADDR),
    .init_done(init_done),
    .store_data(store_data), .load_data(1'b0),
    .send_data(send_data), .recv_data(1'b0), .data_in(data_in),
    .device_rdy(device_rdy), .error_o(error_o),
    .tx_en(tx_en), .rx_en(rx_en), .wr_data(wr_data), .wr_addr(wr_addr),
    .rd_data(rd_data), .rd_addr(rd_addr), .cmd_ack_i(cmd_ack)
);

i2c_slave_model #(.I2C_ADR(DEV_ADDR)) slave(.scl(scl), .sda(sda));

always #5 clk = ~clk;

// Write one OV7670 register: store addr byte, store value byte, send, wait done.
task automatic i2c_write(input [7:0] raddr, input [7:0] rval);
    begin
        // wait until the controller is idle/ready (WAIT_COMMAND)
        @(posedge clk); #2;
        while (!device_rdy) begin @(posedge clk); #2; end

        @(negedge clk); store_data = 1'b1; data_in = raddr;   // -> memory_buffer[0]
        @(negedge clk); store_data = 1'b1; data_in = rval;    // -> memory_buffer[1]
        @(negedge clk); store_data = 1'b0;                    // back to WAIT_COMMAND
        @(negedge clk); send_data  = 1'b1;                    // launch transaction
        @(negedge clk); send_data  = 1'b0;

        // let device_rdy drop (transaction started), then wait for completion
        repeat (4) @(posedge clk);
        @(posedge clk); #2;
        while (!device_rdy && !error_o) begin @(posedge clk); #2; end
    end
endtask

integer i, errors;
logic [7:0] expected [0:NUM_REGS-1];
string str;

initial begin
    errors     = 0;
    store_data = 1'b0;
    send_data  = 1'b0;
    data_in    = 8'h00;
    clk        = 1'b0;
    rst_n      = 1'b1;
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");

    // reset
    #2 rst_n = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    // wait for the controller to finish prescaler init
    @(posedge clk); #2;
    while (!init_done) begin @(posedge clk); #2; end
    logger.info(module_name, "Controller reported init_done");

    expected[0] = 8'hA5;
    expected[1] = 8'h3C;
    expected[2] = 8'h00;
    expected[3] = 8'hF1;

    for (i = 0; i < NUM_REGS; i = i + 1) begin
        i2c_write(i[7:0], expected[i]);
        if (error_o) begin
            $sformat(str, "Unexpected NACK while writing register %0d", i);
            logger.error(module_name, str);
            errors = errors + 1;
        end else begin
            $sformat(str, "Wrote reg %0d <= %0h", i, expected[i]);
            logger.info(module_name, str);
        end
    end

    // verify the slave captured every register write
    for (i = 0; i < NUM_REGS; i = i + 1) begin
        if (slave.mem[i] !== expected[i]) begin
            $sformat(str, "Register %0d mismatch: slave got %0h, expected %0h",
                     i, slave.mem[i], expected[i]);
            logger.error(module_name, str);
            errors = errors + 1;
        end
    end

    if (errors == 0) begin
        logger.info(module_name, "All register writes verified at the slave");
        `TEST_PASS
    end else
        `TEST_FAIL
end

// Watchdog -- SCCB is slow; a hang (lost ACK / stuck FSM) trips this.
initial begin
    #80000000;
    logger.error(module_name, "Watchdog timeout -- I2C controller appears to hang");
    `TEST_FAIL
end

endmodule
