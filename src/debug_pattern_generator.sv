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

module DebugPatternGenerator
#(
    parameter FRAME_WIDTH = 480,
    parameter FRAME_HEIGHT = 272
)
(
    input clk,
    input reset_n,

    input queue_full,
    
    output reg [16:0] queue_data,
    output reg queue_wr_en
);
    localparam Colorbar_width = FRAME_WIDTH / 16;

    reg [10:0] row_counter, col_counter;

    typedef enum {
        STATE_IDLE,
        STATE_WRITE_ROW_START,
        STATE_WRITE_ROW,
        STATE_WRITE_ROW_END,
        STATE_WRITE_FRAME_DONE
    } loader_state_t;

    loader_state_t loader_state;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin 
            row_counter <= `WRAP_SIM(#1) 'd0;
            col_counter <= `WRAP_SIM(#1) 'd0;

            loader_state <= `WRAP_SIM(#1) STATE_IDLE;
            queue_wr_en <= `WRAP_SIM(#1) 1'b0;
            queue_data <= `WRAP_SIM(#1) 'd0;
        end else begin
            case (loader_state)
                STATE_IDLE: if (!queue_full) begin
                    queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                    queue_data <= `WRAP_SIM(#1) 17'h10000;

                    row_counter <= `WRAP_SIM(#1) 0;
                    col_counter <= `WRAP_SIM(#1) 0;

                    loader_state <= `WRAP_SIM(#1) STATE_WRITE_ROW_START;
                end
                STATE_WRITE_ROW_START: if (!queue_full) begin
                    queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                    queue_data <= `WRAP_SIM(#1) 17'h10001;

                    loader_state <= `WRAP_SIM(#1) STATE_WRITE_ROW;
                end
                STATE_WRITE_ROW: begin
                    if (col_counter == FRAME_WIDTH && !queue_full) begin
                        queue_wr_en <= `WRAP_SIM(#1) 1'b0;

                        loader_state <= `WRAP_SIM(#1) STATE_WRITE_ROW_END;
                    end else if (!queue_full) begin
                        logic [4:0] pixel_value_r;
                        logic [5:0] pixel_value_g;
                        logic [4:0] pixel_value_b;

                        if ((col_counter >> 4) %2) begin
                        pixel_value_r = 'd0;
                        pixel_value_g = 'd0;
                        pixel_value_b = 'h1F;
                        end else begin
                        pixel_value_r = 'h1F;
                        pixel_value_g = 'd0;
                        pixel_value_b = 'h1F;
                        end

                        queue_data <= `WRAP_SIM(#1) { 1'b0, pixel_value_r, pixel_value_g, pixel_value_b };
                        col_counter <= `WRAP_SIM(#1) col_counter + 1'b1;
                    end
                end
                STATE_WRITE_ROW_END: begin
                    if (row_counter + 1 == FRAME_HEIGHT) begin
                        if (!queue_full) begin
                            queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                            queue_data <= `WRAP_SIM(#1) 17'h1FFFF;

                            loader_state <= `WRAP_SIM(#1) STATE_WRITE_FRAME_DONE;
                        end
                    end else begin
                        row_counter <= `WRAP_SIM(#1) row_counter + 1'b1;
                        col_counter <= `WRAP_SIM(#1) 'd0;

                        loader_state <= `WRAP_SIM(#1) STATE_WRITE_ROW_START;
                    end
                end
                STATE_WRITE_FRAME_DONE: begin
                    queue_wr_en <= `WRAP_SIM(#1) 1'b0;
                    loader_state <= `WRAP_SIM(#1) STATE_IDLE;
                end
            endcase
        end
    end

endmodule
