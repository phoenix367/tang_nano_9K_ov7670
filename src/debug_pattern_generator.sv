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

`include "color_utilities.vh"

`default_nettype wire

module DebugPatternGenerator
#(
`ifdef __ICARUS__
        parameter MODULE_NAME = "",
        parameter LOG_LEVEL = `SVL_VERBOSE_INFO,
`endif

    parameter integer FRAME_WIDTH = 480,
    parameter integer FRAME_HEIGHT = 272,
    parameter bit SEND_EXTRA_DATA = 1'b1
)
(
    input clk,
    input reset_n,

    input queue_full,
    
    output reg [16:0] queue_data,
    output reg queue_wr_en,
    output queue_clk
);
    import ColorUtilities::*;

    localparam NUM_COLOR_BARS = 10;
    localparam Colorbar_width = FRAME_WIDTH / NUM_COLOR_BARS;

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    function logic [15:0] get_pixel_color(input logic [10:0] column_index, input int color_bars);
        integer i;
        logic exit;

        get_pixel_color = 16'h0000;
        exit = 1'b0;
        for (i = 0; i < color_bars && !exit; i = i + 1)
            if (column_index < (i + 1) * Colorbar_width) begin
                get_pixel_color = bar_colors[i];
                exit = 1'b1;
            end
    endfunction

    reg [15:0] bar_colors[NUM_COLOR_BARS];

    initial begin
        integer i;
        for (i = 0; i < NUM_COLOR_BARS; i = i + 1)
            bar_colors[i] = get_rgb_color(i);
    end

    reg [10:0] row_counter, col_counter;
    assign queue_clk = clk;

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

                    if (SEND_EXTRA_DATA)
                        loader_state <= `WRAP_SIM(#1) STATE_WRITE_ROW_START;
                    else
                        loader_state <= `WRAP_SIM(#1) STATE_WRITE_ROW;
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
                        logic [15:0] pixel_color;

                        pixel_color = get_pixel_color(col_counter, NUM_COLOR_BARS);
                        queue_data <= `WRAP_SIM(#1) { 1'b0, pixel_color };
                        col_counter <= `WRAP_SIM(#1) col_counter + 1'b1;

                        if (!SEND_EXTRA_DATA)
                            queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                    end
                end
                STATE_WRITE_ROW_END: begin
                    if (row_counter + 1 == FRAME_HEIGHT) begin
                        if (SEND_EXTRA_DATA && !queue_full) begin
                            queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                            queue_data <= `WRAP_SIM(#1) 17'h1FFFF;

                            loader_state <= `WRAP_SIM(#1) STATE_WRITE_FRAME_DONE;
                        end else if (!SEND_EXTRA_DATA)
                            loader_state <= `WRAP_SIM(#1) STATE_WRITE_FRAME_DONE;
                    end else begin
                        row_counter <= `WRAP_SIM(#1) row_counter + 1'b1;
                        col_counter <= `WRAP_SIM(#1) 'd0;

                        if (SEND_EXTRA_DATA)
                            loader_state <= `WRAP_SIM(#1) STATE_WRITE_ROW_START;
                        else
                            loader_state <= `WRAP_SIM(#1) STATE_WRITE_ROW;
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
