`include "camera_control_defs.vh"
`ifdef __ICARUS__
`include "svlogger.sv"
`endif

`undef DEBUG_CAM_INPUT

`undef DEBUG_LCD

`default_nettype wire

module VGA_timing
`ifdef __ICARUS__
#(
    parameter MODULE_NAME = "",
    parameter LOG_LEVEL = `SVL_VERBOSE_INFO
)
`endif
(
    input                   sys_clk,
    input                   PixelClk,
    input                   nRST,

    output                  LCD_DE,
    output                  reg LCD_HSYNC,
    output                  reg LCD_VSYNC,

	output          reg [4:0]    LCD_B,
	output          reg [5:0]    LCD_G,
	output          reg [4:0]    LCD_R,

    input cam_vsync,
    input href,
    input [7:0] p_data,
    output LCD_CLK,
    output reg debug_led,
    input memory_clk,
    input pll_lock,
    input screen_clk,
    output[1:0]           O_psram_ck,
    output[1:0]           O_psram_ck_n,
    inout [1:0]           IO_psram_rwds,
    output[1:0]           O_psram_reset_n,
    inout [15:0]           IO_psram_dq,
    output[1:0]           O_psram_cs_n
);
// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    wire calib_1;

    assign debug_led = ~(error0 || error1);

    wire [20:0] addr0;
    wire [20:0] addr1;
    wire [31:0] wr_data0;
    wire [31:0] wr_data1;
    wire [31:0] rd_data0;
    wire [31:0] rd_data1;
    wire init_done_0;
    wire init_done_1;
    wire cmd_0;
    wire cmd_1;
    wire cmd_en_0;
    wire cmd_en_1;
    wire error0;
    wire error1 = 1'b0;
    wire [3:0] data_mask_0;
    wire [3:0] data_mask_1;
    wire rd_data_valid_0;
    wire rd_data_valid_1;
    wire clk_2;

    wire mem_load_clk;
    wire load_read_rdy;
    wire load_command_valid;
    wire [1:0] load_command_data;
    wire [31:0] load_pixel_data;
    wire [9:0] load_mem_addr;

    wire queue_store_clk;
    wire queue_store_wr_en;
    wire queue_store_full;
    wire [16:0] video_data_queue_in;

    assign addr1 = 21'h0;
    assign wr_data1 = 32'h0;
    assign cmd_1 = 1'b0;
    assign cmd_en_1 = 1'b1;
    assign data_mask_1 = 4'h0;

    Video_frame_buffer frame_buffer(
        .clk(PixelClk), 
        .rst_n(nRST),
        .memory_clk(memory_clk), //input memory_clk
		.pll_lock(pll_lock), //input pll_lock
		.O_psram_ck(O_psram_ck), //output [1:0] O_psram_ck
		.O_psram_ck_n(O_psram_ck_n), //output [1:0] O_psram_ck_n
		.IO_psram_rwds(IO_psram_rwds), //inout [1:0] IO_psram_rwds
		.O_psram_reset_n(O_psram_reset_n), //output [1:0] O_psram_reset_n
		.IO_psram_dq(IO_psram_dq), //inout [15:0] IO_psram_dq
		.O_psram_cs_n(O_psram_cs_n), //output [1:0] O_psram_cs_n
		.init_calib0(init_done_0), //output init_calib0
		.init_calib1(init_done_1), //output init_calib1
		.clk_out(clk_2), //output clk_out
		.cmd0(cmd_0), //input cmd0
		.cmd1(cmd_1), //input cmd1
		.cmd_en0(cmd_en_0), //input cmd_en0
		.cmd_en1(cmd_en_1), //input cmd_en1
		.addr0(addr0), //input [20:0] addr0
		.addr1(addr1), //input [20:0] addr1
		.wr_data0(wr_data0), //input [31:0] wr_data0
		.wr_data1(wr_data1), //input [31:0] wr_data1
		.rd_data0(rd_data0), //output [31:0] rd_data0
		.rd_data1(rd_data1), //output [31:0] rd_data1
		.rd_data_valid0(rd_data_valid_0), //output rd_data_valid0
		.rd_data_valid1(rd_data_valid_1), //output rd_data_valid1
		.data_mask0(data_mask_0), //input [3:0] data_mask0
		.data_mask1(data_mask_1) //input [3:0] data_mask1
    );
	
VideoController #(
.MEMORY_BURST(32),
.ENABLE_OUTPUT_RESIZE(1)
`ifdef __ICARUS__
, .LOG_LEVEL(LOG_LEVEL)
`endif
) u_test0(
                      .clk(clk_2),
                      .rst_n(nRST), 
                      .init_done(init_done_0),
                      .cmd(cmd_0),
                      .cmd_en(cmd_en_0),
                      .addr(addr0),
                      .wr_data(wr_data0),
                      .rd_data(rd_data0),
                      .rd_data_valid(rd_data_valid_0),
                      .error(error0),
                      .data_mask(data_mask_0),

                      .load_clk_o(mem_load_clk),
                      .load_read_rdy(load_read_rdy),
                      .load_command_valid(load_command_valid),
                      .load_pixel_data(load_pixel_data),
                      .load_mem_addr(load_mem_addr),
                      .load_command_data(load_command_data),

                      .store_clk_o(queue_store_clk),
                      .store_wr_en(queue_store_wr_en),
                      .store_queue_full(queue_store_full),
                      .store_queue_data(video_data_queue_in)
                  );


    wire lcd_read_clk;
    wire lcd_queue_rd_en;
    wire lcd_queue_full;
    wire [16:0] lcd_queue_data_out;
    wire lcd_queue_empty;

	FIFO_cam q_cam_data_out(
		.Data(video_data_queue_in), //input [16:0] Data
		.WrReset(~nRST), //input WrReset
		.RdReset(~nRST), //input RdReset
		.WrClk(queue_store_clk), //input WrClk
`ifdef DEBUG_LCD
		.RdClk(1'b0), //input RdClk
		.RdEn(1'b0), //input RdEn
`else
		.RdClk(lcd_read_clk), //input RdClk
		.RdEn(lcd_queue_rd_en), //input RdEn
`endif
		.WrEn(queue_store_wr_en), //input WrEn
`ifdef DEBUG_LCD
		.Q(), //output [16:0] Q
		.Empty(), //output Empty
`else
		.Q(lcd_queue_data_out), //output [16:0] Q
		.Empty(lcd_queue_empty), //output Empty
`endif
		.Full(queue_store_full) //output Full
	);

`ifdef DEBUG_CAM_INPUT
    DebugPatternGenerator2
    #(
    `ifdef __ICARUS__
        .LOG_LEVEL(LOG_LEVEL),
    `endif

        .FRAME_WIDTH(640),
        .FRAME_HEIGHT(480)
    )

    pattern_generator_cam
    (
        .clk_cam(screen_clk),
        .clk_mem(mem_load_clk),
        .reset_n(nRST),
        .init(init_done_0),
        .pixel_data(load_pixel_data),
        .command_data_valid(load_command_valid),
        .mem_controller_rdy(load_read_rdy),
        .mem_addr(load_mem_addr),
        .command_data(load_command_data)
    );

`else

    CamPixelProcessor
    #(
    `ifdef __ICARUS__
        .LOG_LEVEL(LOG_LEVEL),
    `endif

        .FRAME_WIDTH(640),
        .FRAME_HEIGHT(480)
    )
    pixel_processor_cam
    (
        .clk_cam(PixelClk),
        .clk_mem(mem_load_clk),
        .reset_n(nRST),
        .init(init_done_0),
        .pixel_data(load_pixel_data),
        .command_data_valid(load_command_valid),
        .mem_controller_rdy(load_read_rdy),
        .mem_addr(load_mem_addr),
        .command_data(load_command_data),

        .v_sync(cam_vsync),
        .h_ref(href),
        .cam_data(p_data)
    );
`endif

    assign LCD_CLK = screen_clk;

`ifdef DEBUG_LCD
    wire [16:0] lcd_queue_data_in;
    wire lcd_queue_wr_en;

	FIFO_cam lcd_Debug_queue(
		.Data(lcd_queue_data_in), //input [16:0] Data
		.WrReset(~nRST), //input WrReset
		.RdReset(~nRST), //input RdReset
		.WrClk(clk_2), //input WrClk
		.RdClk(lcd_read_clk), //input RdClk
		.WrEn(lcd_queue_wr_en), //input WrEn
		.RdEn(lcd_queue_rd_en), //input RdEn
		.Q(lcd_queue_data_out), //output [16:0] Q
		.Empty(lcd_queue_empty), //output Empty
		.Full(lcd_queue_full) //output Full
	);

    DebugPatternGenerator
    #(
    `ifdef __ICARUS__
        .LOG_LEVEL(LOG_LEVEL),
    `endif

        .FRAME_WIDTH(480),
        .FRAME_HEIGHT(272)
    )

    pattern_generator
    (
        .clk(clk_2),
        .reset_n(nRST),

        .queue_full(lcd_queue_full),
        
        .queue_data(lcd_queue_data_in),
        .queue_wr_en(lcd_queue_wr_en)
    );
`endif

    LCD_Controller
    #(
    `ifdef __ICARUS__
        .LOG_LEVEL(LOG_LEVEL),
    `endif

        .LCD_SCREEN_WIDTH(480),
        .LCD_SCREEN_HEIGHT(272)
    )

    lcd_controller
    (
        .clk(screen_clk),
        .reset_n(nRST),
        .queue_data_in(lcd_queue_data_out),
        .queue_empty(lcd_queue_empty),

        .queue_rd_en(lcd_queue_rd_en),
        .queue_clk(lcd_read_clk),

        .LCD_DE(LCD_DE),
        .LCD_HSYNC(LCD_HSYNC),
        .LCD_VSYNC(LCD_VSYNC),

        .LCD_B(LCD_B),
        .LCD_G(LCD_G),
        .LCD_R(LCD_R)
    );
endmodule
