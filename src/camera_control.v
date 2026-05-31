`include "timescale.v"
`include "camera_control_defs.vh"
`include "ov7670_regs.vh"

`default_nettype wire

module CameraControl_TOP (
    input sys_clk,          // clk input
    input sys_rst_n,        // reset input
    inout master_scl,
    inout master_sda,
    output led_out,             // host-active indicator (driven below)
    output cam_reset,
    output cam_clk,
    output led_out1,
    input video_clk_i,
	output			LCD_CLK,
	output			LCD_HYNC,
	output			LCD_SYNC,
	output			LCD_DEN,
	output	[4:0]	LCD_R,
	output	[5:0]	LCD_G,
	output	[4:0]	LCD_B,
    input h_sync_i,
    input v_sync_i,
    input [7:0] cam_data_i,
    output cam_pwdn,
    output debug_led,
    output[1:0]           O_psram_ck,
    output[1:0]           O_psram_ck_n,
    inout [1:0]           IO_psram_rwds,
    output[1:0]           O_psram_reset_n,
    inout [15:0]           IO_psram_dq,
    output[1:0]           O_psram_cs_n,
    output [2:0] status_leds,
    // UART (FT2232H channel B), 9600 8-E-1; see doc/build.md.
    output uart_tx,         // FPGA -> host
    input  uart_rx          // host -> FPGA
);

// ---- UART (9600 8-E-1) + Modbus RTU slave on the FT2232H channel B ----
// A Modbus master/PC reads and writes live OV7670 registers: the holding-
// register address IS the OV7670 register number (0x00..0xC9, see
// ov7670_regs.vh). The slave runs with EXTERNAL_BACKEND=1 and every register
// access is serviced by modbus_cam_backend, which turns it into an SCCB
// transaction on the shared i2c_control_fsm. The backend stays idle until the
// power-on camera init has finished (cam_init_complete), so the default config
// is loaded undisturbed.
// OV7670 register space 0x00..0xC9 plus the bridge's reserved status registers
// (0xF0 magic, 0xF1/0xF2 uptime) so the host can detect a hard reset.
localparam integer MODBUS_REGS = 'hF3;

wire [7:0] uart_rx_data;
wire       uart_rx_valid, uart_rx_perr;
wire [7:0] uart_tx_data;
wire       uart_tx_start, uart_tx_busy;

// register-backend handshake between the slave and the SCCB bridge
wire        be_req, be_we, be_ready;
wire [15:0] be_addr, be_wdata, be_rdata;
// the bridge's drive of the i2c controller (muxed with the init FSM below)
wire        be_store_data, be_send_data, be_recv_data;
wire [7:0]  be_din;
wire        be_busy;

uart #(
    .CLK_FREQ('d27_000_000),
    .BAUD('d9600)
) uart_inst (
    .clk(sys_clk),
    .reset_n(sys_rst_n),
    .tx_data(uart_tx_data),
    .tx_start(uart_tx_start),
    .tx_busy(uart_tx_busy),
    .tx(uart_tx),
    .rx(uart_rx),
    .rx_data(uart_rx_data),
    .rx_valid(uart_rx_valid),
    .rx_parity_error(uart_rx_perr),
    .rx_frame_error()
);

modbus_rtu_slave #(
    .CLK_FREQ('d27_000_000),
    .BAUD('d9600),
    .SLAVE_ADDR(8'd7),
    .REG_COUNT(MODBUS_REGS),
    .MAX_FRAME(32),         // caps a read burst at 13 regs; keeps the buffers small
    .EXTERNAL_BACKEND(1)
) modbus_inst (
    .clk(sys_clk),
    .reset_n(sys_rst_n),
    .rx_data(uart_rx_data),
    .rx_valid(uart_rx_valid),
    .rx_parity_error(uart_rx_perr),
    .tx_data(uart_tx_data),
    .tx_start(uart_tx_start),
    .tx_busy(uart_tx_busy),
    .reg_o(),
    .host_we(1'b0),
    .host_addr(8'h00),
    .host_wdata(16'h0000),
    .be_req(be_req),
    .be_we(be_we),
    .be_addr(be_addr),
    .be_wdata(be_wdata),
    .be_ready(be_ready),
    .be_rdata(be_rdata)
);

modbus_cam_backend cam_bridge (
    .clk(sys_clk),
    .reset_n(sys_rst_n),
    .cam_init_complete(cam_init_complete),
    .be_req(be_req),
    .be_we(be_we),
    .be_addr(be_addr),
    .be_wdata(be_wdata),
    .be_ready(be_ready),
    .be_rdata(be_rdata),
    .store_data(be_store_data),
    .send_data(be_send_data),
    .recv_data(be_recv_data),
    .i2c_din(be_din),
    .device_rdy(device_ready),
    .data_valid(i2c_data_valid),
    .i2c_dout(i2c_data_out),
    .busy(be_busy)
);

// ---- UART activity blink + host-presence timeout ----
// uart_*_blink stretch each byte event to ~50 ms so a 9600-baud transfer is
// visible. host_active_cnt reloads on every received byte (a host request) and
// counts down over ~6 s, so it stays asserted while a host keeps talking (the
// web app heartbeats every ~4 s) and clears a few seconds after it stops.
localparam [20:0] LED_BLINK    = 21'd1_350_000;     // ~50 ms at 27 MHz
localparam [27:0] HOST_TIMEOUT = 28'd162_000_000;   // ~6 s  at 27 MHz
reg [20:0] uart_rx_blink;
reg [20:0] uart_tx_blink;
reg [27:0] host_active_cnt;

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        uart_rx_blink   <= `WRAP_SIM(#1) 21'd0;
        uart_tx_blink   <= `WRAP_SIM(#1) 21'd0;
        host_active_cnt <= `WRAP_SIM(#1) 28'd0;
    end else begin
        if (uart_rx_valid)            uart_rx_blink <= `WRAP_SIM(#1) LED_BLINK;
        else if (uart_rx_blink != 0)  uart_rx_blink <= `WRAP_SIM(#1) uart_rx_blink - 1'b1;

        if (uart_tx_start)            uart_tx_blink <= `WRAP_SIM(#1) LED_BLINK;
        else if (uart_tx_blink != 0)  uart_tx_blink <= `WRAP_SIM(#1) uart_tx_blink - 1'b1;

        if (uart_rx_valid)              host_active_cnt <= `WRAP_SIM(#1) HOST_TIMEOUT;
        else if (host_active_cnt != 0)  host_active_cnt <= `WRAP_SIM(#1) host_active_cnt - 1'b1;
    end
end

// LEDs are active-low (drive 0 to light):
//   status_leds[0] = UART RX activity, [1] = UART TX activity, [2] = init done
//   led_out        = host actively connected (recent Modbus traffic)
assign status_leds = ~{cam_init_complete, (uart_tx_blink != 0), (uart_rx_blink != 0)};
assign led_out     = ~(host_active_cnt != 0);

typedef enum {
    WAIT_RDY, 
    SEND_INIT, 
    SEND_INIT2, 
    SEND_INIT_DONE, 
    WAIT_CAMERA_INIT_DONE, 
    CAMERA_INIT_DONE,
    WAIT_TRANSMIT_COMPLETE, 
    TRANSMIT_COMPLETE, 
    CHECK_ROM_DATA, 
    START_DELAY
} CONTROL_STATES;

localparam [6:0] OV7670_ADDR = 7'h21;

wire ctrl_done_wire;
wire send_complete;
assign cam_reset = sys_rst_n;
assign cam_clk = sys_clk;

reg [7:0] data_buffer_out;
reg store_data;
reg send_data;
reg delay_reset;
reg [7:0] rom_addr;
CONTROL_STATES controller_state;

// Latched high once the power-on register load reaches TRANSMIT_COMPLETE; hands
// the SCCB controller over from the init FSM to the Modbus bridge.
reg        cam_init_complete;

// i2c_control_fsm read result (driven once the read path returns).
wire [7:0] i2c_data_out;
wire       i2c_data_valid;

// SCCB controller inputs, owned by the init FSM during init and by the Modbus
// bridge afterwards.
wire       sccb_store_data = cam_init_complete ? be_store_data : store_data;
wire       sccb_send_data  = cam_init_complete ? be_send_data  : send_data;
wire       sccb_recv_data  = cam_init_complete ? be_recv_data  : 1'b0;
wire [7:0] sccb_data_in    = cam_init_complete ? be_din        : data_buffer_out;

wire tx_en;
wire [7:0] wr_data;
wire [2:0] wr_addr;
wire rx_en;
wire [7:0] rd_data;
wire [2:0] rd_addr;

wire scl_i;
wire scl_o;
wire scl_o_oen;

wire sda_i;
wire sda_o;
wire sda_o_oen;
wire cyc;
wire [2:0] reg_addr;
wire cmd_ack;
wire device_ready;
wire transmit_error;
wire delay_done;

wire [7:0] rom_reg_addr;
wire [7:0] rom_reg_val;

wire memory_clk;
wire pll_lock;
wire screen_clk;

assign master_scl = scl_o_oen ? 1'bZ : scl_o;
assign master_sda = sda_o_oen ? 1'bZ : sda_o;
assign cyc = tx_en | rx_en;
assign reg_addr = (tx_en) ? wr_addr : rd_addr;
assign led_out1 = ~transmit_error;
assign cam_pwdn = 1'b0;

SDRAM_rPLL sdram_clock(
    .reset(~sys_rst_n), 
    .clkin(sys_clk), 
    .clkout(memory_clk), 
    .clkoutd(screen_clk),
    .lock(pll_lock)
);

VGA_timing	VGA_timing_inst(
    .sys_clk(sys_clk),
    .PixelClk	(	video_clk_i		),
    .nRST		(	sys_rst_n),

    .LCD_DE		(	LCD_DEN	 	),
    .LCD_HSYNC	(	LCD_HYNC 	),
    .LCD_VSYNC	(	LCD_SYNC 	),

    .LCD_B		(	LCD_B		),
    .LCD_G		(	LCD_G		),
    .LCD_R		(	LCD_R		),
    .cam_vsync(v_sync_i),
    .href(h_sync_i),
    .p_data(cam_data_i),
    .LCD_CLK(LCD_CLK),
    .debug_led(debug_led),
    .memory_clk(memory_clk),
    .pll_lock(pll_lock),
    .screen_clk(screen_clk),
    .O_psram_ck(O_psram_ck),
    .O_psram_ck_n(O_psram_ck_n), 
    .IO_psram_rwds(IO_psram_rwds),
    .O_psram_reset_n(O_psram_reset_n), 
    .IO_psram_dq(IO_psram_dq),
    .O_psram_cs_n(O_psram_cs_n)
);

i2c_master_top i2c_master(
    .wb_clk_i(sys_clk),
    .wb_rst_i(1'b0),
    .arst_i(sys_rst_n),
    .wb_dat_i(wr_data),
    .wb_adr_i(reg_addr),
    .wb_we_i(tx_en),
    .wb_stb_i(1'b1),
    .scl_padoen_o(scl_o_oen),
    .scl_pad_i(master_scl),
    .scl_pad_o(scl_o),
    .sda_padoen_o(sda_o_oen),
    .sda_pad_i(master_sda),
    .sda_pad_o(sda_o),
    .wb_cyc_i(cyc),
    .wb_dat_o(rd_data),
    .wb_ack_o(cmd_ack),
    .wb_inta_o()
);

i2c_control_fsm i2c_controller(
    .clk(sys_clk), 
    .rst_n(sys_rst_n), 
    .device_addr(OV7670_ADDR), 
    .init_done(ctrl_done_wire), 
    .data_in(sccb_data_in),
    .store_data(sccb_store_data),
    .send_data(sccb_send_data),
    .tx_en(tx_en),
    .rx_en(rx_en),
    .wr_data(wr_data),
    .wr_addr(wr_addr),
    .rd_data(rd_data),
    .rd_addr(rd_addr),
    .cmd_ack_i(cmd_ack),
    .device_rdy(device_ready),
    .error_o(transmit_error),
    .data_out(i2c_data_out),
    .data_valid(i2c_data_valid),
    .load_data(1'b0),
    .recv_data(sccb_recv_data)
);

ov7670_default settings_rom(
    .addr_i(rom_addr), 
    .dout({rom_reg_addr, rom_reg_val})
);

device_delay i2c_init_delay(
    .clk_i(sys_clk), 
    .rst_n(sys_rst_n), 
    .syn_rst(delay_reset), 
    .delay_done(delay_done)
);

initial begin
    controller_state <= `WRAP_SIM(#1) WAIT_RDY;
    send_data <= `WRAP_SIM(#1) 1'b0;
    store_data <= `WRAP_SIM(#1) 1'b0;
    delay_reset <= `WRAP_SIM(#1) 1'b0;
    rom_addr <= `WRAP_SIM(#1) 8'h00;
    cam_init_complete <= `WRAP_SIM(#1) 1'b0;
end

always @(posedge sys_clk or negedge sys_rst_n)
begin
    if (!sys_rst_n)
    begin
        controller_state <= `WRAP_SIM(#1) WAIT_RDY;
        send_data <= `WRAP_SIM(#1) 1'b0;
        delay_reset <= `WRAP_SIM(#1) 1'b0;
        rom_addr <= `WRAP_SIM(#1) 8'h00;
        cam_init_complete <= `WRAP_SIM(#1) 1'b0;
    end else begin
        case (controller_state)
            WAIT_RDY:
            begin
                if (ctrl_done_wire && delay_done) begin 
                    controller_state <= `WRAP_SIM(#1) CHECK_ROM_DATA;
                end
            end
            CHECK_ROM_DATA:
            begin
                if (rom_reg_addr == 8'hff && rom_reg_val == 8'hff)
                    controller_state <= `WRAP_SIM(#1) TRANSMIT_COMPLETE;
                else if (rom_reg_addr == 8'hff && rom_reg_val == 8'hf0) begin
                    `WRAP_SIM($display("t=%d, DEBUG CameraControl_TOP; Apply delay for addr = %0h", $time, rom_addr));
                    delay_reset <= `WRAP_SIM(#1) 1'b1;
                    controller_state <= `WRAP_SIM(#1) START_DELAY;
                end else
                    controller_state <= `WRAP_SIM(#1) SEND_INIT;
            end
            START_DELAY:
            begin
                delay_reset <= `WRAP_SIM(#1) 1'b0;

                if (!delay_done) begin
                    controller_state <= `WRAP_SIM(#1) WAIT_RDY;
                    rom_addr <= `WRAP_SIM(#1) rom_addr + 1'b1;
                end
            end
            SEND_INIT: 
            begin
                controller_state <= `WRAP_SIM(#1) SEND_INIT2;
                store_data <= `WRAP_SIM(#1) 1'b1;
                
                // Write camera control register index
                data_buffer_out <= `WRAP_SIM(#1) rom_reg_addr;
            end
            SEND_INIT2: 
            begin
                controller_state <= `WRAP_SIM(#1) SEND_INIT_DONE;
                store_data <= `WRAP_SIM(#1) 1'b1;
                data_buffer_out <= `WRAP_SIM(#1) rom_reg_val;
            end
            SEND_INIT_DONE:
            begin
                store_data <= `WRAP_SIM(#1) 1'b0; 
                controller_state <= `WRAP_SIM(#1) WAIT_CAMERA_INIT_DONE;
            end
            WAIT_CAMERA_INIT_DONE:
            begin
                //$finish;
                send_data <= `WRAP_SIM(#1) 1'b1;
                controller_state <= `WRAP_SIM(#1) CAMERA_INIT_DONE;
            end
            CAMERA_INIT_DONE: 
            begin
                send_data <= `WRAP_SIM(#1) 1'b0;
                controller_state <= WAIT_TRANSMIT_COMPLETE;
            end
            WAIT_TRANSMIT_COMPLETE:
            begin
                if (transmit_error)
                    controller_state <= `WRAP_SIM(#1) TRANSMIT_COMPLETE;
                else if (device_ready) begin
                    controller_state <= `WRAP_SIM(#1) CHECK_ROM_DATA;
                    rom_addr <= `WRAP_SIM(#1) rom_addr + 1'b1;

                    `WRAP_SIM($display("t=%d, DEBUG CameraControl_TOP; Loading next byte...", $time));
                end
            end
            TRANSMIT_COMPLETE:
                cam_init_complete <= `WRAP_SIM(#1) 1'b1;   // hand SCCB to the Modbus bridge
        endcase
    end
end

endmodule
