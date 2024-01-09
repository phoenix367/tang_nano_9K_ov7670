`include "camera_control_defs.vh"
`ifdef __ICARUS__
`include "svlogger.sv"
`endif

module CameraHandler
#(
`ifdef __ICARUS__
    parameter MODULE_NAME = "",
    parameter LOG_LEVEL = `SVL_VERBOSE_INFO,
`endif
    parameter int FRAME_WIDTH = 640,
    parameter int FRAME_HEIGHT = 480
)
(
    input                   PixelClk,
    input                   nRST,
    input                   cam_vsync,
    input                   cam_href,
    input             [7:0] p_data,
    input                   init_done,

    output                  queue_clk,
    output       reg [16:0] queue_data,
    output       reg        queue_wr_en
);
// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

	typedef enum bit[7:0] {
        WAIT_FRAME_START = 8'd0,
        ROW_CAPTURE      = 8'd1,
        WAIT_CALIBRATION = 8'd2,
        START_WRITE_ROW  = 8'd3,
        WAIT_HREF        = 8'd4,
        READ_HALF_PIXEL  = 8'd5,
        READ_FULL_PIXEL  = 8'd6,
        CHECK_ROW_COUNT  = 8'd7
    } state_t;

	state_t FSM_state = WAIT_CALIBRATION;
    reg pixel_half = 1'b0;
    reg frame_done = 1'b0;
    reg pixel_valid = 1'b0;
    reg [15:0] pixel_data = 'd0;
    reg [10:0] row_counter = 'd0;
    reg [10:0] col_counter = 'd0;

    wire [10:0] row_counter_next;

    //Gowin_CLKDIV2 clkdiv(queue_clk, PixelClk, nRST);
    assign queue_clk = ~PixelClk;
    assign row_counter_next = row_counter + 1'b1;

	always @(posedge PixelClk or negedge nRST)
	begin
        if (!nRST) begin
            FSM_state <= `WRAP_SIM(#1) WAIT_CALIBRATION;
            queue_data <= `WRAP_SIM(#1) 17'h00000;
            queue_wr_en <= `WRAP_SIM(#1) 1'b0;
            pixel_valid <= `WRAP_SIM(#1) 1'b0;
            pixel_data <= `WRAP_SIM(#1) 'd0;
            frame_done <= `WRAP_SIM(#1) 1'b0;
            row_counter <= `WRAP_SIM(#1) 'd0;
            col_counter <= `WRAP_SIM(#1) 'd0;
        end else begin                    
            case(FSM_state)
                WAIT_CALIBRATION: begin
                    queue_wr_en <= `WRAP_SIM(#1) 1'b0;

                    if (init_done && cam_vsync) begin
                        FSM_state <= `WRAP_SIM(#1) WAIT_FRAME_START;

`ifdef __ICARUS__
                        logger.info(module_name, "Memory controller sucessfully initialized");
`endif                    
                    end
                end
                WAIT_FRAME_START: begin //wait for VSYNC
                    frame_done <= `WRAP_SIM(#1) 1'b0;
                    pixel_half <= `WRAP_SIM(#1) 1'b0;

                    if (!cam_vsync) begin
                        FSM_state <= `WRAP_SIM(#1) START_WRITE_ROW;

                        queue_data <= `WRAP_SIM(#1) 17'h10000;
                        queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                        row_counter <= `WRAP_SIM(#1) 'd0;

`ifdef __ICARUS__
                        logger.info(module_name, "VSYNC signal received");
`endif                    
                    end else
                        queue_wr_en <= `WRAP_SIM(#1) 1'b0;
                end
                START_WRITE_ROW: begin
                    queue_data <= `WRAP_SIM(#1) 17'h10001;
                    queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                    pixel_valid <= `WRAP_SIM(#1) 1'b0;
                    pixel_half <= `WRAP_SIM(#1) 1'b0;
                    col_counter <= `WRAP_SIM(#1) 'd0;

                    FSM_state <= `WRAP_SIM(#1) WAIT_HREF;
                end
                WAIT_HREF: begin
                    queue_wr_en <= `WRAP_SIM(#1) 1'b0;

                    if (cam_href) begin
                        pixel_data[7:0] <= `WRAP_SIM(#1) p_data;
                        FSM_state <= `WRAP_SIM(#1) READ_FULL_PIXEL;
                    end
                end
                READ_HALF_PIXEL: begin
                    queue_wr_en <= `WRAP_SIM(#1) 1'b0;
    
                    if (col_counter == 'd640) begin
                        FSM_state <= `WRAP_SIM(#1) CHECK_ROW_COUNT;
                    end else begin
                        pixel_data[7:0] <= `WRAP_SIM(#1) p_data;
                        FSM_state <= `WRAP_SIM(#1) READ_FULL_PIXEL;
                    end
                end
                READ_FULL_PIXEL: begin
                    if (col_counter == 'd640) begin
                        queue_wr_en <= `WRAP_SIM(#1) 1'b0;
                        FSM_state <= `WRAP_SIM(#1) CHECK_ROW_COUNT;
                    end else begin
                        queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                        //queue_data <= `WRAP_SIM(#1) { 1'b0, 11'b0, col_counter[4:0] };
                        queue_data <= `WRAP_SIM(#1) { 1'b0, pixel_data[7:0], p_data };
                        col_counter <= `WRAP_SIM(#1) col_counter + 1'b1;

                        FSM_state <= `WRAP_SIM(#1) READ_HALF_PIXEL;
                    end
                end
                CHECK_ROW_COUNT: begin
                    if (row_counter_next == FRAME_HEIGHT) begin
                        queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                        queue_data <= `WRAP_SIM(#1) 17'h1FFFF;

                        FSM_state <= `WRAP_SIM(#1) WAIT_CALIBRATION;

`ifdef __ICARUS__
                        logger.info(module_name, "Frame writing finished");
`endif                    
                    end else begin
                        row_counter <= `WRAP_SIM(#1) row_counter_next;
                        FSM_state <= `WRAP_SIM(#1) START_WRITE_ROW;
                    end
                end
            endcase
        end
	end
endmodule
