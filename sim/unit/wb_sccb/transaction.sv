`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for wb_sccb (Wishbone B4 classic-standard SCCB-access slave).
//
// Wires the slave to the real SCCB stack (i2c_control_fsm -> i2c_master_top ->
// i2c_slave_model), exactly the post-init path of CameraControl_TOP. A Wishbone
// write turns into an SCCB register write; a Wishbone read into an SCCB read
// returning {8'h00, value}. The slave model's memory is 4 bytes, so registers
// 0..3 are used.
//
// Checks: WB write -> slave memory; WB read -> seeded value; and the init gate --
// while cam_init_complete is low, a camera access must NOT ack (the master would
// stall); once it is raised the access completes.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam [6:0]    DEV_ADDR = 7'h21;
localparam integer  NUM_REGS = 4;

reg         clk, reset_n;
reg         cam_init;

// Wishbone master side (TB drives)
reg  [15:0] adr, dat_w;
reg         we, stb, cyc;
wire [15:0] dat_r;
wire        ack, busy;

// wb_sccb <-> i2c_control_fsm
wire        store_data, send_data, recv_data;
wire [7:0]  i2c_din;
wire        device_rdy, data_valid, init_done, error_o;
wire [7:0]  i2c_dout;

// i2c_control_fsm <-> master core
wire        tx_en, rx_en;
wire [7:0]  wr_data, rd_data;
wire [2:0]  wr_addr, rd_addr;
wire        cmd_ack;
wire        i2c_cyc  = tx_en | rx_en;
wire [2:0]  reg_addr = tx_en ? wr_addr : rd_addr;

// open-drain SCCB bus
wire scl, sda;
wire scl_m_o, sda_m_o, scl_m_oen, sda_m_oen;
assign scl = scl_m_oen ? 1'bz : scl_m_o;
assign sda = sda_m_oen ? 1'bz : sda_m_o;
pullup p_scl(scl);
pullup p_sda(sda);

integer errors;
string  module_name, str;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wb_sccb dut (
    .clk(clk), .reset_n(reset_n), .cam_init_complete(cam_init),
    .wb_adr_i(adr), .wb_dat_i(dat_w), .wb_dat_o(dat_r),
    .wb_we_i(we), .wb_stb_i(stb), .wb_cyc_i(cyc), .wb_ack_o(ack),
    .store_data(store_data), .send_data(send_data), .recv_data(recv_data),
    .i2c_din(i2c_din),
    .device_rdy(device_rdy), .data_valid(data_valid), .i2c_dout(i2c_dout),
    .busy(busy)
);

i2c_control_fsm i2c_ctrl(
    .clk(clk), .rst_n(reset_n), .device_addr(DEV_ADDR),
    .init_done(init_done),
    .store_data(store_data), .load_data(1'b0),
    .send_data(send_data), .recv_data(recv_data), .data_in(i2c_din),
    .device_rdy(device_rdy), .error_o(error_o),
    .data_out(i2c_dout), .data_valid(data_valid),
    .tx_en(tx_en), .rx_en(rx_en), .wr_data(wr_data), .wr_addr(wr_addr),
    .rd_data(rd_data), .rd_addr(rd_addr), .cmd_ack_i(cmd_ack)
);

i2c_master_top i2c_master(
    .wb_clk_i(clk), .wb_rst_i(1'b0), .arst_i(reset_n),
    .wb_dat_i(wr_data), .wb_adr_i(reg_addr), .wb_we_i(tx_en),
    .wb_stb_i(1'b1), .wb_cyc_i(i2c_cyc),
    .wb_dat_o(rd_data), .wb_ack_o(cmd_ack), .wb_inta_o(),
    .scl_pad_i(scl), .scl_pad_o(scl_m_o), .scl_padoen_o(scl_m_oen),
    .sda_pad_i(sda), .sda_pad_o(sda_m_o), .sda_padoen_o(sda_m_oen)
);

i2c_slave_model #(.I2C_ADR(DEV_ADDR)) slave(.scl(scl), .sda(sda));

always #5 clk = ~clk;

// Wishbone classic-standard access; polls ack (SCCB transactions take many cycles).
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

integer i;
reg [15:0] rd;
logic [7:0] seed [0:NUM_REGS-1];
reg gated_ok;

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    errors = 0;
    adr = 0; dat_w = 0; we = 0; stb = 0; cyc = 0;
    cam_init = 1'b1; clk = 1'b0; reset_n = 1'b1;

    seed[0] = 8'h11; seed[1] = 8'h22; seed[2] = 8'h33; seed[3] = 8'h44;

    #2 reset_n = 1'b0;
    repeat (4) @(posedge clk);
    reset_n = 1'b1;

    @(posedge clk); #2;
    while (!init_done) begin @(posedge clk); #2; end
    logger.info(module_name, "i2c controller init_done");

    // 1) WB writes -> SCCB writes into the slave memory
    for (i = 0; i < NUM_REGS; i = i + 1)
        wb_access(1'b1, i[15:0], {8'h00, seed[i]}, rd);
    for (i = 0; i < NUM_REGS; i = i + 1)
        if (slave.mem[i] !== seed[i]) begin
            $sformat(str, "SCCB write mem[%0d]=%h, expected %h", i, slave.mem[i], seed[i]);
            logger.error(module_name, str); errors = errors + 1;
        end

    // 2) WB reads -> SCCB reads return {8'h00, value}
    for (i = 0; i < NUM_REGS; i = i + 1) begin
        wb_access(1'b0, i[15:0], 16'h0000, rd);
        if (rd !== {8'h00, seed[i]}) begin
            $sformat(str, "WB read reg%0d = %h, expected %h", i, rd, {8'h00, seed[i]});
            logger.error(module_name, str); errors = errors + 1;
        end
    end

    // 3) init gate: with cam_init low, a camera access must not ack
    cam_init = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    adr = 16'h0002; dat_w = 16'h00AB; we = 1'b1; cyc = 1'b1; stb = 1'b1;
    gated_ok = 1'b1;
    repeat (30) begin
        @(posedge clk); #2;
        if (ack || busy) gated_ok = 1'b0;
    end
    if (!gated_ok) begin
        logger.error(module_name, "wb_sccb acked/started a camera access while init gate was low");
        errors = errors + 1;
    end
    // release the gate -> the held access now completes
    cam_init = 1'b1;
    @(posedge clk); #2;
    while (!ack) begin @(posedge clk); #2; end
    @(negedge clk); cyc = 1'b0; stb = 1'b0; we = 1'b0;
    repeat (4) @(posedge clk);
    if (slave.mem[2] !== 8'hAB) begin
        $sformat(str, "post-gate write mem[2]=%h, expected AB", slave.mem[2]);
        logger.error(module_name, str); errors = errors + 1;
    end

    if (errors == 0) begin
        logger.info(module_name, "wb_sccb: SCCB write/read + init gate all correct");
        `TEST_PASS
    end else
        `TEST_FAIL
end

initial begin
    #200000000;
    logger.error(module_name, "Watchdog timeout -- wb_sccb appears to hang");
    `TEST_FAIL
end

endmodule
