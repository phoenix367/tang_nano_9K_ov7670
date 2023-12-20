`include "timescale.v"
`include "camera_control_defs.vh"
`include "ov7670_regs.vh"

module CameraControl_TOP (
    input sys_clk,          // clk input
    input sys_rst_n,        // reset input
    inout master_scl,
    inout master_sda,
    output reg led_out,
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
    output[1:0]           O_psram_cs_n
);

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
    .data_in(data_buffer_out),
    .store_data(store_data), 
    .send_data(send_data),
    .tx_en(tx_en), 
    .rx_en(rx_en), 
    .wr_data(wr_data),
    .wr_addr(wr_addr), 
    .rd_data(rd_data), 
    .rd_addr(rd_addr),
    .cmd_ack_i(cmd_ack), 
    .device_rdy(device_ready), 
    .error_o(transmit_error),
    .load_data(1'b0), 
    .recv_data(1'b0)
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
    led_out <= `WRAP_SIM(#1) 1'b1;
    delay_reset <= `WRAP_SIM(#1) 1'b0;
    rom_addr <= `WRAP_SIM(#1) 8'h00;
end

always @(posedge sys_clk or negedge sys_rst_n)
begin
    if (!sys_rst_n)
    begin
        controller_state <= `WRAP_SIM(#1) WAIT_RDY;
        send_data <= `WRAP_SIM(#1) 1'b0;
        led_out <= 1'b1;
        delay_reset <= `WRAP_SIM(#1) 1'b0;
        rom_addr <= `WRAP_SIM(#1) 8'h00;
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
            TRANSMIT_COMPLETE: led_out <= `WRAP_SIM(#1) 1'b0;
        endcase
    end
end

endmodule
