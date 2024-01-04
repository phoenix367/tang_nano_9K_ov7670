`include "camera_control_defs.vh"
`ifdef __ICARUS__
`include "svlogger.sv"
`endif

module CameraHandler
`ifdef __ICARUS__
#(
    parameter MODULE_NAME = "",
    parameter LOG_LEVEL = `SVL_VERBOSE_INFO
)
`endif
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

	typedef enum {
        WAIT_FRAME_START = 8'd0,
        ROW_CAPTURE      = 8'd1,
        WAIT_CALIBRATION = 8'd2
    } state_t;

	state_t FSM_state = WAIT_CALIBRATION;
    reg pixel_half = 1'b0;
    reg frame_done = 1'b0;
    reg pixel_valid = 1'b0;
    reg [15:0] pixel_data = 'd0;
    reg buffer_flip = 1'b0;

    assign queue_clk = PixelClk;

	always @(posedge PixelClk or negedge nRST)
	begin
        if (!nRST) begin
            FSM_state <= `WRAP_SIM(#1) WAIT_CALIBRATION;
            queue_data <= `WRAP_SIM(#1) 17'h00000;
            queue_wr_en <= `WRAP_SIM(#1) 1'b0;
            pixel_valid <= `WRAP_SIM(#1) 1'b0;
            pixel_data <= `WRAP_SIM(#1) 'd0;
            buffer_flip = `WRAP_SIM(#1) 1'b0;
        end else begin                    
            case(FSM_state)
                WAIT_CALIBRATION:
                    if (init_done) begin
                        FSM_state <= `WRAP_SIM(#1) WAIT_FRAME_START;

`ifdef __ICARUS__
                        logger.info(module_name, "Memory controller sucessfully initialized");
`endif                    
                    end
                WAIT_FRAME_START: begin //wait for VSYNC
                    frame_done <= `WRAP_SIM(#1) 1'b0;
                    pixel_half <= `WRAP_SIM(#1) 1'b0;

                    if (!cam_vsync) begin
                        FSM_state <= `WRAP_SIM(#1) ROW_CAPTURE;

                        queue_data <= `WRAP_SIM(#1) 17'h10000;
                        queue_wr_en <= `WRAP_SIM(#1) 1'b1;
`ifdef __ICARUS__
                        logger.info(module_name, "VSYNC signal received");
`endif                    
                    end else
                        queue_wr_en <= `WRAP_SIM(#1) 1'b0;
                end
                ROW_CAPTURE: begin 
                    if (cam_vsync) begin
                        FSM_state <= `WRAP_SIM(#1) WAIT_FRAME_START;
                        frame_done <= `WRAP_SIM(#1) 1'b1;

                        buffer_flip <= `WRAP_SIM(#1) 1'b0;
                        pixel_valid <= `WRAP_SIM(#1) 1'b0;
                    end else begin
                        if (cam_href && pixel_half) begin
                            pixel_valid <= `WRAP_SIM(#1) 1'b1;

                            queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                            queue_data <= `WRAP_SIM(#1) { 1'b0, pixel_data };

                        end else begin
                            pixel_valid <= `WRAP_SIM(#1) 1'b0;
                            queue_wr_en <= `WRAP_SIM(#1) 1'b0;
                        end

                        if (cam_href) begin
                            pixel_half <= `WRAP_SIM(#1) ~pixel_half;

                            if (pixel_half) begin
                                pixel_data[7:0] <= `WRAP_SIM(#1) p_data;
                            end else 
                                pixel_data[15:8] <= `WRAP_SIM(#1) p_data;
                        end
                    end
                end        
            endcase
        end
	end
endmodule
