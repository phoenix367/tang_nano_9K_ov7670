`include "camera_control_defs.vh"
`ifdef __ICARUS__
`include "svlogger.sv"
`endif

module VGA_timing
`ifdef __ICARUS__
#(
    parameter MODULE_NAME = "",
    parameter LOG_LEVEL = `SVL_VERBOSE_INFO
)
`endif
(
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
    output reg LCD_CLK,
    output reg debug_led,
    input memory_clk,
    input pll_lock,
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

    reg buffer_flip;
    wire reset_p = ~nRST;

    initial begin
        buffer_flip <= `WRAP_SIM(#1) 1'b0;
        //debug_led <= `WRAP_SIM(#1) 1'b1;
    end

	localparam WAIT_FRAME_START = 0;
	localparam ROW_CAPTURE = 1;
	localparam WAIT_CALIBRATION = 2;

	reg [1:0] FSM_state = WAIT_CALIBRATION;
    reg pixel_half = 1'b0;
    reg frame_done = 1'b0;
    reg pixel_valid = 1'b0;
    reg [15:0] pixel_data = 15'd0;
    reg [10:0] cam_row_addr = 11'd0;
    reg [10:0] cam_row_addr_next = 11'd0;
    reg [10:0] screen_row_addr = 11'd0;

    reg write_a;
    reg write_b;

    wire [15:0] out_a;
    wire [15:0] out_b;

    wire calib_1;
    //wire PixelClk;

    assign debug_led = ~(error0 || error1);

    //Gowin_DQCE qce(.clkout(PixelClk), .clkin(PixelClk1), .ce(1'b1));

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

    wire queue_load_clk;
    wire queue_load_rd_en;
    wire queue_load_empty;
    wire [16:0] cam_data_queue_out;

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
.MEMORY_BURST(32)
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

                      .load_clk_o(queue_load_clk),
                      .load_rd_en(queue_load_rd_en),
                      .load_queue_empty(queue_load_empty),
                      .load_queue_data(cam_data_queue_out),

                      .store_clk_o(queue_store_clk),
                      .store_wr_en(queue_store_wr_en),
                      .store_queue_full(queue_store_full),
                      .store_queue_data(video_data_queue_in)
                  );
/*
psram_test u_test0(
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
                      .data_mask(data_mask_0)
                  );
*/
/*
psram_test u_test1(
                      .clk(clk_2),
                      .rst_n(nRST), 
                      .init_done(init_done_1),
                      .cmd(cmd_1),
                      .cmd_en(cmd_en_1),
                      .addr(addr1),
                      .wr_data(wr_data1),
                      .rd_data(rd_data1),
                      .rd_data_valid(rd_data_valid_1),
                      .error(error1),
                      .data_mask(data_mask_1)
                  );
*/

    Image_row_buffer row_buffer(.clka(PixelClk), .clkb(PixelClk), .cea(1'b1), .ocea(1'b1),
                                .ceb(1'b1), .oceb(1'b1), .reseta(reset_p), .resetb(reset_p),
                                .ada((!buffer_flip) ? cam_row_addr : screen_row_addr),
                                .adb(( buffer_flip) ? cam_row_addr : screen_row_addr),
                                .dina(pixel_data), .dinb(pixel_data), .douta(out_a), .doutb(out_b),
                                .wrea(write_a), .wreb(write_b));

    reg [16:0] cam_data_in;
    reg cam_data_in_wr_en;

	FIFO_cam q_cam_data_in(
		.Data(cam_data_in), //input [16:0] Data
		.WrReset(~nRST), //input WrReset
		.RdReset(~nRST), //input RdReset
		.WrClk(PixelClk), //input WrClk
		.RdClk(queue_load_clk), //input RdClk
		.WrEn(cam_data_in_wr_en), //input WrEn
		.RdEn(queue_load_rd_en), //input RdEn
		.Q(cam_data_queue_out), //output [16:0] Q
		.Empty(queue_load_empty), //output Empty
		.Full() //output Full
	);

	FIFO_cam q_cam_data_out(
		.Data(video_data_queue_in), //input [16:0] Data
		.WrReset(~nRST), //input WrReset
		.RdReset(~nRST), //input RdReset
		.WrClk(queue_store_clk), //input WrClk
		.RdClk(LCD_CLK), //input RdClk
		.WrEn(queue_store_wr_en), //input WrEn
		.RdEn(), //input RdEn
		.Q(), //output [16:0] Q
		.Empty(), //output Empty
		.Full(queue_store_full) //output Full
	);

	always @(posedge PixelClk or negedge nRST)
	begin
        if (!nRST) begin
            FSM_state <= `WRAP_SIM(#1) WAIT_CALIBRATION;
            cam_data_in <= 17'h000;
            cam_data_in_wr_en <= 1'b0;
            //debug_led <= `WRAP_SIM(#1) 1'b1;
        end else begin
                    
            case(FSM_state)
            WAIT_CALIBRATION:
                if (init_done_0 && init_done_1) begin
                    FSM_state <= `WRAP_SIM(#1) WAIT_FRAME_START;
`ifdef __ICARUS__
                    logger.info(module_name, "Memory controller sucessfully initialized");
                    //$finish;
`endif                    
                end
            WAIT_FRAME_START: begin //wait for VSYNC
                frame_done <= `WRAP_SIM(#1) 1'b0;
                pixel_half <= `WRAP_SIM(#1) 1'b0;
                cam_row_addr <= `WRAP_SIM(#1) 11'd0;
                cam_row_addr_next <= `WRAP_SIM(#1) 11'd0;

                if (!cam_vsync) begin
                    FSM_state <= `WRAP_SIM(#1) ROW_CAPTURE;

                    cam_data_in <= `WRAP_SIM(#1) 17'h10000;
                    cam_data_in_wr_en <= `WRAP_SIM(#1) 1'b1;
`ifdef __ICARUS__
                    logger.info(module_name, "VSYNC signal received");
`endif                    
                end else
                    cam_data_in_wr_en <= `WRAP_SIM(#1) 1'b0;
            end
            
            ROW_CAPTURE: begin 
                if (cam_vsync) begin
                    FSM_state <= `WRAP_SIM(#1) WAIT_FRAME_START;
                    frame_done <= `WRAP_SIM(#1) 1'b1;

                    buffer_flip <= `WRAP_SIM(#1) 1'b0;
                    pixel_valid <= `WRAP_SIM(#1) 1'b0;
                    write_a <= `WRAP_SIM(#1) 1'b0;
                    write_b <= `WRAP_SIM(#1) 1'b0;

                    //cam_data_in_wr_en <= `WRAP_SIM(#1) 1'b1;
                    //cam_data_in <= `WRAP_SIM(#1) 17'h1FFFF;
                end else begin
                    if (href && pixel_half) begin
                        pixel_valid <= `WRAP_SIM(#1) 1'b1;
                        cam_row_addr_next <= `WRAP_SIM(#1) cam_row_addr_next + 1'b1;

                        cam_data_in_wr_en <= `WRAP_SIM(#1) 1'b1;
                        cam_data_in <= `WRAP_SIM(#1) { 1'b0, pixel_data };

                        if (!buffer_flip) begin
                            write_a <= `WRAP_SIM(#1) 1'b1;
                            write_b <= `WRAP_SIM(#1) 1'b0;
                        end else begin
                            write_a <= `WRAP_SIM(#1) 1'b0;
                            write_b <= `WRAP_SIM(#1) 1'b1;
                        end
                    end else begin
                        pixel_valid <= `WRAP_SIM(#1) 1'b0;
                        write_a <= `WRAP_SIM(#1) 1'b0;
                        write_b <= `WRAP_SIM(#1) 1'b0;

                        cam_data_in_wr_en <= `WRAP_SIM(#1) 1'b0;
                    end

                    if (href) begin
                        pixel_half <= `WRAP_SIM(#1) ~pixel_half;

                        if (pixel_half) begin
                            pixel_data[7:0] <= `WRAP_SIM(#1) p_data;
                            cam_row_addr <= `WRAP_SIM(#1) cam_row_addr_next;
                        end else 
                            pixel_data[15:8] <= `WRAP_SIM(#1) p_data;
                    end else if (cam_row_addr > 11'd0) begin
                        cam_row_addr <= `WRAP_SIM(#1) 11'd0;
                        cam_row_addr_next <= `WRAP_SIM(#1) 11'd0;
                        buffer_flip <= `WRAP_SIM(#1) ~buffer_flip;
                    end
                end
            end        
            endcase
        end
	end

    //Gowin_CLKDIV2 clkd_div(.hclkin(PixelClk), .clkout(LCD_CLK), .resetn(nRST));
    //assign LCD_CLK = PixelClk;

    // Horizen count to Hsync, then next Horizen line.

    parameter       H_Pixel_Valid    = 16'd480; 
    parameter       H_FrontPorch     = 16'd50;//16'd50;
    parameter       H_BackPorch      = 16'd254;  

    parameter       PixelForHS       = H_Pixel_Valid + H_FrontPorch + H_BackPorch;

    parameter       V_Pixel_Valid    = 16'd272; 
    parameter       V_FrontPorch     = 16'd20;  
    parameter       V_BackPorch      = 16'd10;    

    parameter       PixelForVS       = V_Pixel_Valid + V_FrontPorch + V_BackPorch;

    // Horizen pixel count

    reg         [15:0]  H_PixelCount;
    reg         [15:0]  V_PixelCount;

    reg [4:0] screen_fsm = WAIT_FRAME_START;
	//localparam WAIT_FRAME_START = 0;
	localparam START_DRAW_ROW = 1;
	localparam DRAW_ROW = 2;
    localparam END_DRAW_ROW = 3;
    localparam WAIT_ROW_START = 4;
    localparam WAIT_VSYNC = 5;

    initial begin
            H_PixelCount <= `WRAP_SIM(#1) 'd0;
            V_PixelCount <= `WRAP_SIM(#1) 'd0;
            LCD_CLK <= `WRAP_SIM(#1) 1'b0;
    end

    always @(posedge PixelClk or negedge nRST) begin
        if( !nRST )
            LCD_CLK <= `WRAP_SIM(#1) 1'b0;
        else
            LCD_CLK <= `WRAP_SIM(#1) ~LCD_CLK;
    end


    always @(  posedge LCD_CLK or negedge nRST  )begin
        if( !nRST ) begin
            screen_fsm <= `WRAP_SIM(#1) WAIT_FRAME_START;
            H_PixelCount <= `WRAP_SIM(#1) 'd0;
            V_PixelCount <= `WRAP_SIM(#1) 'd0;
            screen_row_addr   <=  `WRAP_SIM(#1) 'd0;
        end else begin
/*
            case (screen_fsm)
                WAIT_FRAME_START: begin
                    V_PixelCount      <=  `WRAP_SIM(#1) 16'b0;    
                    H_PixelCount      <=  `WRAP_SIM(#1) 16'b0;
                    screen_row_addr   <=  `WRAP_SIM(#1) 'd0;
                    //LCD_DE <= `WRAP_SIM(#1) 1'b0;
                    //LCD_HSYNC <= `WRAP_SIM(#1) 1'b0;
                    //LCD_VSYNC <= `WRAP_SIM(#1) 1'b0;
    
                    if (href) begin
                        screen_fsm <= `WRAP_SIM(#1) START_DRAW_ROW;
                        debug_led <= `WRAP_SIM(#1) ~debug_led;
                    end
                end
            
                START_DRAW_ROW: begin
                    //LCD_VSYNC <= `WRAP_SIM(#1) 1'b0;

                    if (H_PixelCount < H_BackPorch)
                        H_PixelCount <= `WRAP_SIM(#1) H_PixelCount + 1'b1;
                    else begin
                        screen_fsm <= `WRAP_SIM(#1) DRAW_ROW;
                    end
                end
                DRAW_ROW: begin
                    if (H_PixelCount < H_Pixel_Valid + H_BackPorch) begin
                        H_PixelCount <= `WRAP_SIM(#1) H_PixelCount + 1'b1;
                        LCD_B[4:0] <= (buffer_flip) ? out_a[4:0] : out_b[4:0];
                        LCD_G[5:0] <= (buffer_flip) ? out_a[10:5] : out_b[10:5];//(buffer_flip) ? out_a[10:5] : out_b[10:5];
                        LCD_R[4:0] <= (buffer_flip) ? out_a[15:11] : out_b[15:11];//(buffer_flip) ? out_a[15:11] : out_b[15:11];
                        
                        screen_row_addr <= `WRAP_SIM(#1) screen_row_addr + 1'b1;
                    end else
                        screen_fsm <= `WRAP_SIM(#1) END_DRAW_ROW;
                end
                END_DRAW_ROW: begin
                    //if (cam_vsync) begin
                    //    screen_fsm <= `WRAP_SIM(#1) WAIT_FRAME_START;
                    //end else begin
                        //LCD_HSYNC <= `WRAP_SIM(#1) 1'b1;
                        if (!href)
                            screen_fsm <= `WRAP_SIM(#1) WAIT_ROW_START;
                    //end
                end
                WAIT_ROW_START: begin
                    //if (cam_vsync) begin
                    //    screen_fsm <= `WRAP_SIM(#1) WAIT_FRAME_START;
                    end else if (href) begin
                        //LCD_HSYNC <= `WRAP_SIM(#1) 1'b0;
                        if (V_PixelCount < V_Pixel_Valid) begin
                            V_PixelCount <= `WRAP_SIM(#1) V_PixelCount + 1'b1;

                            screen_fsm <= `WRAP_SIM(#1) START_DRAW_ROW;
                            H_PixelCount      <=  `WRAP_SIM(#1) 16'b0;
                            screen_row_addr   <=  `WRAP_SIM(#1) 'd0;
                        end else begin
                            //LCD_VSYNC <= `WRAP_SIM(#1) 1'b0;
                            screen_fsm <= `WRAP_SIM(#1) WAIT_VSYNC;
                        end
                    end
                end
                WAIT_VSYNC: begin
                    if (cam_vsync)
                       screen_fsm <= `WRAP_SIM(#1) WAIT_FRAME_START; 
                end
            endcase
        end
*/

        if(  H_PixelCount == PixelForHS ) begin
            V_PixelCount      <=  `WRAP_SIM(#1) V_PixelCount + 1'b1;
            H_PixelCount      <=  `WRAP_SIM(#1) 16'b0;
            screen_row_addr <= 0;
            end
        else if(  V_PixelCount == PixelForVS ) begin
            V_PixelCount      <=  `WRAP_SIM(#1) 16'b0;
            H_PixelCount      <=  `WRAP_SIM(#1) 16'b0;
            screen_row_addr <= 0;

            end
        else begin
            V_PixelCount      <=  `WRAP_SIM(#1) V_PixelCount ;
            H_PixelCount      <=  `WRAP_SIM(#1) H_PixelCount + 1'b1;

            LCD_B[4:0] <= (buffer_flip) ? out_a[4:0] : out_b[4:0];
            LCD_G[5:0] <= (buffer_flip) ? out_a[10:5] : out_b[10:5];
            LCD_R[4:0] <= (buffer_flip) ? out_a[15:11] : out_b[15:11];

            screen_row_addr <= `WRAP_SIM(#1) screen_row_addr + 1'b1;
        end
        end

    end

    //assign  LCD_DE = (screen_fsm == DRAW_ROW) /*&& LCD_CLK*/;
    //assign  LCD_HSYNC = (screen_fsm == START_DRAW_ROW) /*&& LCD_CLK*/;
    //assign  LCD_VSYNC = cam_vsync /*&& LCD_CLK*/;
    // SYNC-DE MODE
    
    assign  LCD_HSYNC = (H_PixelCount <= (PixelForHS-H_FrontPorch)) ? 1'b0 : 1'b1;
    //assign LCD_HSYNC = ~href;
    
	assign  LCD_VSYNC = (V_PixelCount  <= (PixelForVS-V_FrontPorch)) ? 1'b0 : 1'b1;

    assign  LCD_DE =    ( H_PixelCount >= H_BackPorch ) && ( H_PixelCount <= H_Pixel_Valid + H_BackPorch ) &&
                        ( V_PixelCount >= V_BackPorch ) && ( V_PixelCount <= V_Pixel_Valid + V_BackPorch ) /*&& LCD_CLK*/;

    // color bar
    localparam          Colorbar_width   =   H_Pixel_Valid / 16;
/*
    assign LCD_R[4:0] = (buffer_flip) ? out_a[4:0] : out_b[4:0];
    assign LCD_G[5:0] = (buffer_flip) ? out_a[10:5] : out_b[10:5];//(buffer_flip) ? out_a[10:5] : out_b[10:5];
    assign LCD_B[4:0] = (buffer_flip) ? out_a[15:11] : out_b[15:11];//(buffer_flip) ? out_a[15:11] : out_b[15:11];
*/

    //assign  LCD_R = pixel_data[4:0];
    //assign  LCD_G = pixel_data[10:5];
    //assign  LCD_B = pixel_data[15:11];
/*
    assign LCD_R     = ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 0  )) ? 5'b00000 :
                    ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 1  )) ? 5'b00001 : 
                    ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 2  )) ? 5'b00011 :    
                    ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 3  )) ? 5'b00111 :    
                    ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 4  )) ? 5'b01111 :    
                    ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 5  )) ? 5'b11111 :  5'b00000;


    assign  LCD_G    =  ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 6  )) ? 6'b000001: 
                        ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 7  )) ? 6'b000011:    
                        ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 8  )) ? 6'b000111:    
                        ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 9  )) ? 6'b001111:    
                        ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 10 )) ? 6'b011111:    
                        ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 11 )) ? 6'b111111:  6'b000000;

    assign  LCD_B    =  ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 12 )) ? 5'b00001 : 
                        ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 13 )) ? 5'b00011 :    
                        ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 14 )) ? 5'b00111 :    
                        ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 15 )) ? 5'b01111 :    
                        ( H_PixelCount < ( H_BackPorch +  Colorbar_width * 16 )) ? 5'b11111 :  5'b00000;
*/
endmodule
