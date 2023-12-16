`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`ifdef __ICARUS__
`include "svlogger.sv"
`endif

package LCDControllerTypes;
    typedef enum bit[7:0] {
        LCD_CONTROLLER_IDLE      = 8'd00,
        WAIT_FRAME_START         = 8'd01,
        INIT_FRAME_START         = 8'd02,
        WAIT_ROW_START           = 8'd03,
        READ_ROW                 = 8'd04,
        PROCESS_ROW_BACK         = 8'd05,
        PROCESS_FRAME_BACK       = 8'd06,
        PROCESS_ROW_FRONT        = 8'd07
    } t_state;
endpackage

module LCD_Controller
#(
`ifdef __ICARUS__
    parameter MODULE_NAME = "",
    parameter LOG_LEVEL = `SVL_VERBOSE_INFO,
`endif

    parameter LCD_SCREEN_WIDTH = 480,
    parameter LCD_SCREEN_HEIGHT = 272
)
(
    input clk,
    input reset_n,
    input [16:0] queue_data_in,
    input queue_empty,

    output reg queue_rd_en,
    output queue_clk,

    output reg LCD_DE,
    output reg LCD_HSYNC,
    output reg LCD_VSYNC,

	output          reg [4:0]    LCD_B,
	output          reg [5:0]    LCD_G,
	output          reg [4:0]    LCD_R
);

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    import LCDControllerTypes::*;

    assign queue_clk = clk;

    t_state state;

    localparam       H_Pixel_Valid    = LCD_SCREEN_WIDTH; 
    localparam       H_SyncWidth      = 'd4;
    localparam       H_FrontPorch     = 'd4;
    localparam       H_BackPorch      = 'd43;  

    localparam       PixelForHS       = H_Pixel_Valid + H_FrontPorch + H_BackPorch;

    localparam       V_Pixel_Valid    = LCD_SCREEN_HEIGHT; 
    localparam       V_SyncWidth      = 'd3;
    localparam       V_FrontPorch     = 'd4;  
    localparam       V_BackPorch      = 'd12;    

    localparam       PixelForVS       = V_Pixel_Valid + V_FrontPorch + V_BackPorch;

    // Horizen pixel count

    reg         [10:0]  H_PixelCount;
    reg         [10:0]  V_PixelCount;

    //assign  LCD_HSYNC = (H_PixelCount <= (PixelForHS - H_BackPorch)) ? 1'b1 : 1'b0;
	//assign  LCD_VSYNC = (V_PixelCount  <= V_SyncWidth) ? 1'b1 : 1'b0;

    initial begin
        LCD_B <= `WRAP_SIM(#1) 'd0;
        LCD_G <= `WRAP_SIM(#1) 'd0;
        LCD_R <= `WRAP_SIM(#1) 'd0;

        LCD_DE <= `WRAP_SIM(#1) 1'b0;
        LCD_VSYNC <= `WRAP_SIM(#1) 1'b0;
        LCD_HSYNC <= `WRAP_SIM(#1) 1'b0;

        state <= `WRAP_SIM(#1) LCD_CONTROLLER_IDLE;
        queue_rd_en <= `WRAP_SIM(#1) 1'b0;

        H_PixelCount <= `WRAP_SIM(#1) 'd0;
        V_PixelCount <= `WRAP_SIM(#1) 'd0;
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            LCD_B <= `WRAP_SIM(#1) 'd0;
            LCD_G <= `WRAP_SIM(#1) 'd0;
            LCD_R <= `WRAP_SIM(#1) 'd0;

            LCD_DE <= `WRAP_SIM(#1) 1'b0;
            LCD_VSYNC <= `WRAP_SIM(#1) 1'b0;
            LCD_HSYNC <= `WRAP_SIM(#1) 1'b0;
            
            state <= `WRAP_SIM(#1) LCD_CONTROLLER_IDLE;
            queue_rd_en <= `WRAP_SIM(#1) 1'b0;

            H_PixelCount <= `WRAP_SIM(#1) 'd0;
            V_PixelCount <= `WRAP_SIM(#1) 'd0;
        end else begin
            case (state)
                LCD_CONTROLLER_IDLE: begin
                    queue_rd_en <= `WRAP_SIM(#1) 1'b1;
                    state <= `WRAP_SIM(#1) WAIT_FRAME_START;
                end
                WAIT_FRAME_START: begin
                    if (queue_data_in === 17'h10000 && !queue_empty) begin
                        H_PixelCount <= `WRAP_SIM(#1) 'd0;
                        V_PixelCount <= `WRAP_SIM(#1) 'd0;

                        queue_rd_en <= `WRAP_SIM(#1) 1'b0;
                        state <= `WRAP_SIM(#1) INIT_FRAME_START;

`ifdef __ICARUS__
                        logger.info(module_name, "Start LCD frame generation");
`endif
                    end
                end
                INIT_FRAME_START: begin
                    if (V_PixelCount <= V_SyncWidth)
                        LCD_VSYNC <= `WRAP_SIM(#1) 1'b1;
                    else
                        LCD_VSYNC <= `WRAP_SIM(#1) 1'b0;

                    if (H_PixelCount <= H_SyncWidth)
                        LCD_HSYNC <= `WRAP_SIM(#1) 1'b1;
                    else
                        LCD_HSYNC <= `WRAP_SIM(#1) 1'b0;

                    if (V_PixelCount == V_BackPorch) begin
                        state <= `WRAP_SIM(#1) PROCESS_ROW_FRONT;
                    end else if(  H_PixelCount == PixelForHS ) begin
                        V_PixelCount <= `WRAP_SIM(#1) V_PixelCount + 1'b1;
                        H_PixelCount <= `WRAP_SIM(#1) 'd0;
                    end else
                        H_PixelCount <= `WRAP_SIM(#1) H_PixelCount + 1'b1;
                end
                PROCESS_ROW_FRONT: begin
                    if (H_PixelCount <= H_SyncWidth)
                        LCD_HSYNC <= `WRAP_SIM(#1) 1'b1;
                    else
                        LCD_HSYNC <= `WRAP_SIM(#1) 1'b0;

                    if (H_PixelCount == H_BackPorch) begin
                        queue_rd_en <= `WRAP_SIM(#1) 1'b1;

                        state <= `WRAP_SIM(#1) WAIT_ROW_START;
                    end else
                        H_PixelCount <= `WRAP_SIM(#1) H_PixelCount + 1'b1;
                end
                WAIT_ROW_START: if (!queue_empty) begin
                    if (queue_data_in === 17'h10001)
                        state <= `WRAP_SIM(#1) READ_ROW;
                    else if (queue_data_in === 17'h1FFFF) begin
                        queue_rd_en <= `WRAP_SIM(#1) 1'b0;
                        state <= `WRAP_SIM(#1) PROCESS_FRAME_BACK;
                    end
                end
                READ_ROW: begin
                    if (H_PixelCount == H_Pixel_Valid + H_BackPorch) begin
                        H_PixelCount <= `WRAP_SIM(#1) H_PixelCount + 1'b1;
                        LCD_DE <= `WRAP_SIM(#1) 1'b0;
                        
                        state <= `WRAP_SIM(#1) PROCESS_ROW_BACK;
                    end else if (!queue_empty) begin
                        if (H_PixelCount == H_Pixel_Valid + H_BackPorch - 1)
                            queue_rd_en <= `WRAP_SIM(#1) 1'b0;
                        H_PixelCount <= `WRAP_SIM(#1) H_PixelCount + 1'b1;
                        LCD_DE <= `WRAP_SIM(#1) 1'b1;

                        LCD_B <= `WRAP_SIM(#1) queue_data_in[4:0];
                        LCD_G <= `WRAP_SIM(#1) queue_data_in[10:5];
                        LCD_R <= `WRAP_SIM(#1) queue_data_in[15:11];
                    end else
                        LCD_DE <= `WRAP_SIM(#1) 1'b0;
                end
                PROCESS_ROW_BACK: begin
                    if (H_PixelCount == PixelForHS) begin
                        V_PixelCount <= `WRAP_SIM(#1) V_PixelCount + 1'b1;
                        H_PixelCount <= `WRAP_SIM(#1) 'd0;
                        state <= `WRAP_SIM(#1) PROCESS_ROW_FRONT;
                    end else
                        H_PixelCount <= `WRAP_SIM(#1) H_PixelCount + 1'b1;
                end
                PROCESS_FRAME_BACK: begin
                    if (V_PixelCount == PixelForVS) begin
                        H_PixelCount <= `WRAP_SIM(#1) 'd0;
                        state <= `WRAP_SIM(#1) LCD_CONTROLLER_IDLE;

`ifdef __ICARUS__
                        logger.info(module_name, "LCD frame generation completed");
`endif
                    end else if(  H_PixelCount == PixelForHS ) begin
                        V_PixelCount <= `WRAP_SIM(#1) V_PixelCount + 1'b1;
                        H_PixelCount <= `WRAP_SIM(#1) 'd0;
                    end else begin
                        if (H_PixelCount <= H_SyncWidth)
                            LCD_HSYNC <= `WRAP_SIM(#1) 1'b1;
                        else
                            LCD_HSYNC <= `WRAP_SIM(#1) 1'b0;

                        H_PixelCount <= `WRAP_SIM(#1) H_PixelCount + 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
