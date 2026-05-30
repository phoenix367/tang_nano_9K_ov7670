`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Integration test for the I2C controller's READ capability.
//
// Exercises the recv_data path added to `i2c_control_fsm`: the TB stores a
// register index (store_data, like camera_control does for a write), pulses
// recv_data, and the FSM runs the SCCB read (set pointer, then read byte) on
// `i2c_master_top` against `i2c_slave_model`, returning the byte on data_out
// (with data_valid). The slave memory is pre-seeded; the test checks each byte
// read back. Registers 0..3 only (the slave model's 4-byte memory).

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam [6:0] DEV_ADDR = 7'h21;
localparam integer NUM_REGS = 4;

reg clk, rst_n;

// controller command interface
reg        store_data, send_data, recv_data;
reg [7:0]  data_in;
wire       init_done, device_rdy, error_o, data_valid;
wire [7:0] data_out;

// controller <-> master register interface
wire       tx_en, rx_en;
wire [7:0] wr_data, rd_data;
wire [2:0] wr_addr, rd_addr;
wire       cmd_ack;
wire       cyc      = tx_en | rx_en;
wire [2:0] reg_addr = tx_en ? wr_addr : rd_addr;

// open-drain SCCB bus
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
    .send_data(send_data), .recv_data(recv_data), .data_in(data_in),
    .device_rdy(device_rdy), .error_o(error_o),
    .data_out(data_out), .data_valid(data_valid),
    .tx_en(tx_en), .rx_en(rx_en), .wr_data(wr_data), .wr_addr(wr_addr),
    .rd_data(rd_data), .rd_addr(rd_addr), .cmd_ack_i(cmd_ack)
);

i2c_slave_model #(.I2C_ADR(DEV_ADDR)) slave(.scl(scl), .sda(sda));

always #5 clk = ~clk;

// Read one register through the FSM: store the index byte, pulse recv_data,
// wait for the controller to return to idle, then sample data_out.
task automatic fsm_read(input [7:0] raddr, output [7:0] val);
    begin
        @(posedge clk); #2;
        while (!device_rdy) begin @(posedge clk); #2; end

        @(negedge clk); store_data = 1'b1; data_in = raddr;  // memory_buffer[0]
        @(negedge clk); store_data = 1'b0;
        @(negedge clk); recv_data  = 1'b1;
        @(negedge clk); recv_data  = 1'b0;

        repeat (4) @(posedge clk);                           // let device_rdy drop
        @(posedge clk); #2;
        while (!device_rdy) begin @(posedge clk); #2; end    // back to WAIT_COMMAND
        val = data_out;
    end
endtask

integer i, errors;
logic [7:0] seed [0:NUM_REGS-1];
logic [7:0] got;
string str;

initial begin
    errors     = 0;
    store_data = 1'b0;
    send_data  = 1'b0;
    recv_data  = 1'b0;
    data_in    = 8'h00;
    clk        = 1'b0;
    rst_n      = 1'b1;
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");

    seed[0] = 8'h3D; seed[1] = 8'h7E; seed[2] = 8'hC4; seed[3] = 8'h01;
    for (i = 0; i < NUM_REGS; i = i + 1) slave.mem[i] = seed[i];

    #2 rst_n = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    @(posedge clk); #2;
    while (!init_done) begin @(posedge clk); #2; end
    logger.info(module_name, "Controller reported init_done");

    for (i = 0; i < NUM_REGS; i = i + 1) begin
        fsm_read(i[7:0], got);
        if (!data_valid) begin
            $sformat(str, "Register %0d: data_valid not asserted", i);
            logger.error(module_name, str);
            errors = errors + 1;
        end
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
        logger.info(module_name, "All FSM register reads matched the slave memory");
        `TEST_PASS
    end else
        `TEST_FAIL
end

initial begin
    #80000000;
    logger.error(module_name, "Watchdog timeout -- I2C FSM read appears to hang");
    `TEST_FAIL
end

endmodule
