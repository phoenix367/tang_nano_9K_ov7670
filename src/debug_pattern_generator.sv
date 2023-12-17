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

    localparam NUM_COLOR_BARS = 10;
    localparam Colorbar_width = FRAME_WIDTH / NUM_COLOR_BARS;

    function logic [15:0] convert_RGB24_BGR565
    (
        input logic [7:0] R,
        input logic [7:0] G,
        input logic [7:0] B
    );
        logic [4:0] r_value, b_value;
        logic [5:0] g_value;

        r_value = R >> 3;
        g_value = G >> 2;
        b_value = B >> 3;

        convert_RGB24_BGR565 = {r_value, g_value, b_value};
    endfunction

    // This function returns 16-bit color values for first ten
    // SMPTE ECR 1-1978 color bars
    function logic [15:0] get_rgb_color(input logic [3:0] bar_index);
        case (bar_index)
            0: 
                get_rgb_color = convert_RGB24_BGR565(8'd104, 8'd104, 8'd104); // 40% Gray
            1: 
                get_rgb_color = convert_RGB24_BGR565(8'd180, 8'd180, 8'd180); // 75% White 
            2: 
                get_rgb_color = convert_RGB24_BGR565(8'd180, 8'd180, 8'd16); // 75% Yellow
            3: 
                get_rgb_color = convert_RGB24_BGR565(8'd16, 8'd180, 8'd180); // 75% Cyan
            4:
                get_rgb_color = convert_RGB24_BGR565(8'd16, 8'd180, 8'd16); // 75% Green
            5:
                get_rgb_color = convert_RGB24_BGR565(8'd180, 8'd16, 8'd180); // 75% Magenta
            6:
                get_rgb_color = convert_RGB24_BGR565(8'd180, 8'd16, 8'd16); // 75% Red
            7:
                get_rgb_color = convert_RGB24_BGR565(8'd16, 8'd16, 8'd180); // 75% Blue
            8:
                get_rgb_color = convert_RGB24_BGR565(8'd16, 8'd16, 8'd16); // 75% Black
            9:
                get_rgb_color = convert_RGB24_BGR565(8'd235, 8'd235, 8'd235); // 100% White
            default:
                get_rgb_color = 16'h0000;
        endcase
    endfunction

    function logic [15:0] get_pixel_color(input logic [10:0] column_index);
        integer i;
        logic exit;

        get_pixel_color = 16'h0000;
        exit = 1'b0;
        for (i = 0; i < NUM_COLOR_BARS && !exit; i = i + 1)
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
                        logic [15:0] pixel_color;

                        pixel_color = get_pixel_color(col_counter);
                        queue_data <= `WRAP_SIM(#1) { 1'b0, pixel_color };
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
