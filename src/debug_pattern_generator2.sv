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

module DebugPatternGenerator2
#(
`ifdef __ICARUS__
        parameter MODULE_NAME = "",
        parameter LOG_LEVEL = `SVL_VERBOSE_INFO,
`endif

    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 480
)
(
    input clk,
    input reset_n,

    input queue_full,
    
    output reg [16:0] queue_data,
    output reg queue_wr_en,
    output queue_wr_clk
);
    import ColorUtilities::*;

    localparam NUM_COLOR_BARS = 10;
    localparam Colorbar_width = FRAME_WIDTH / NUM_COLOR_BARS;

    assign queue_wr_clk = clk;

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

    reg [10:0] row_counter;
    reg [10:0] col_wr_counter = 'd0;
    reg [10:0] col_rd_counter = 'd0;
    reg buffer_wr_index = 1'b0;
    reg buffer_rd_index = 1'b0;
    reg [15:0] pixel_color = 'd0;

    wire [15:0] mem_out_a;
    wire [15:0] mem_out_b;

    wire [10:0] addr_a;
    wire [10:0] addr_b;
    wire en_a, en_b;

    assign addr_a = (buffer_wr_index == 1'b0) ? col_wr_counter : col_rd_counter;
    assign addr_b = (buffer_wr_index == 1'b1) ? col_wr_counter : col_rd_counter;
    assign en_a = buffer_wr_index == 1'b0;
    assign en_b = buffer_wr_index == 1'b1;

    Image_row_buffer row_buffer(.clka(clk), 
                                .clkb(clk), 
                                .cea(1'b1), 
                                .ocea(1'b1),
                                .ceb(1'b1), 
                                .oceb(1'b1), 
                                .reseta(~reset_n), 
                                .resetb(~reset_n),
                                .ada(addr_a),
                                .adb(addr_b),
                                .dina(pixel_color), 
                                .dinb(pixel_color), 
                                .douta(mem_out_a), 
                                .doutb(mem_out_b),
                                .wrea(en_a), 
                                .wreb(en_b));
    typedef enum {
        STATE_LOADER_IDLE,
        STATE_LOADER_WRITE_FRAME_START,
        STATE_LOADER_WRITE_ROW_START,
        STATE_LOADER_WRITE_ROW,
        STATE_LOADER_WRITE_ROW_END,
        STATE_LOADER_WRITE_FRAME_DONE,
        STATE_LOADER_QUEUE_WR_DONE,
        STATE_LOADER_CHECK_ROW
    } loader_state_t;

    typedef enum {
        STATE_SAVER_IDLE,
        STATE_SAVER_WRITE_ROW,
        STATE_SAVER_SYNC
    } saver_state_t;

    loader_state_t loader_state;
    saver_state_t saver_state;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            row_counter <= `WRAP_SIM(#1) 'd0;
            col_wr_counter <= `WRAP_SIM(#1) 'd0;
            col_rd_counter <= `WRAP_SIM(#1) 'd0;
            buffer_wr_index <= `WRAP_SIM(#1) 1'b0;
            buffer_rd_index <= `WRAP_SIM(#1) 1'b0;
            queue_wr_en <= `WRAP_SIM(#1) 1'b0;
            queue_data <= `WRAP_SIM(#1) 'd0;

            saver_state <= `WRAP_SIM(#1) STATE_SAVER_IDLE;
        end else begin
            case (saver_state)
                STATE_SAVER_IDLE: begin
                    col_wr_counter <= `WRAP_SIM(#1) 'd0;
                    //pixel_color <= `WRAP_SIM(#1) get_pixel_color('d0, NUM_COLOR_BARS);
                    pixel_color <= `WRAP_SIM(#1) { 12'd0, col_wr_counter[3:0] };

                    saver_state <= `WRAP_SIM(#1) STATE_SAVER_WRITE_ROW;
                end
                STATE_SAVER_WRITE_ROW: begin
                    if (col_wr_counter === FRAME_WIDTH) begin
                        saver_state <= `WRAP_SIM(#1) STATE_SAVER_SYNC;
                    end else begin
                        //pixel_color <= `WRAP_SIM(#1) get_pixel_color(col_wr_counter, NUM_COLOR_BARS);
                        pixel_color <= `WRAP_SIM(#1) { 12'd0, col_wr_counter[3:0] };

                        col_wr_counter <= `WRAP_SIM(#1) col_wr_counter + 1'b1;
                    end
                end
                STATE_SAVER_SYNC: begin
                    if (loader_state != STATE_LOADER_WRITE_ROW) begin
                        buffer_wr_index <= `WRAP_SIM(#1) ~buffer_wr_index;
                        saver_state <= `WRAP_SIM(#1) STATE_SAVER_IDLE;
                    end
                end
            endcase

            case (loader_state)
                STATE_LOADER_IDLE: begin
                    row_counter <= `WRAP_SIM(#1) 'd0;

                    if (buffer_wr_index != buffer_rd_index) begin
                        loader_state <= `WRAP_SIM(#1) STATE_LOADER_CHECK_ROW;
                    end
                end
                STATE_LOADER_CHECK_ROW: begin
                    if (row_counter === 'd0)
                        loader_state <= `WRAP_SIM(#1) STATE_LOADER_WRITE_FRAME_START;
                    else if (row_counter !== FRAME_HEIGHT)
                        loader_state <= `WRAP_SIM(#1) STATE_LOADER_WRITE_ROW_START;
                    else begin
                        queue_wr_en <= `WRAP_SIM(#1) 1'b0;

                        loader_state <= `WRAP_SIM(#1) STATE_LOADER_IDLE;
                    end
                end
                STATE_LOADER_WRITE_FRAME_START: begin
                    if (queue_full)
                        ; // Do nothing
                    else begin
                        queue_data <= `WRAP_SIM(#1) 17'h10000;
                        queue_wr_en <= `WRAP_SIM(#1) 1'b1;

                        loader_state <= `WRAP_SIM(#1) STATE_LOADER_WRITE_ROW_START;
                    end
                end
                STATE_LOADER_WRITE_ROW_START: begin
                    if (queue_full)
                        ; // Do nothing
                    else begin
                        queue_data <= `WRAP_SIM(#1) 17'h10001;
                        col_rd_counter <= `WRAP_SIM(#1) 'd0;
                        queue_wr_en <= `WRAP_SIM(#1) 1'b1;

                        loader_state <= `WRAP_SIM(#1) STATE_LOADER_WRITE_ROW;
                    end
                end
                STATE_LOADER_WRITE_ROW: begin
                    if (queue_full)
                        ; // Do nothing
                    else if (col_rd_counter === FRAME_WIDTH) begin
                        if (row_counter + 1'b1 === FRAME_HEIGHT) begin
                            queue_data <= `WRAP_SIM(#1) 17'h1FFFF;
                            row_counter <= `WRAP_SIM(#1) row_counter + 1'b1;

                            loader_state <= `WRAP_SIM(#1) STATE_LOADER_CHECK_ROW;
                        end else begin
                            queue_wr_en <= `WRAP_SIM(#1) 1'b0;

                            loader_state <= `WRAP_SIM(#1) STATE_LOADER_WRITE_ROW_END;
                        end
                    end else begin
                        /*
                        if (buffer_rd_index == 1'b0)
                            queue_data <= `WRAP_SIM(#1) { 1'b0, mem_out_a };
                        else
                            queue_data <= `WRAP_SIM(#1) { 1'b0, mem_out_b };
                        */
                        queue_data <= `WRAP_SIM(#1) { 1'b0, 11'd0, col_rd_counter[4:0] };
                        col_rd_counter <= `WRAP_SIM(#1) col_rd_counter + 1'b1;
                    end
                end
                STATE_LOADER_WRITE_ROW_END: begin
                    buffer_rd_index <= `WRAP_SIM(#1) ~buffer_rd_index;
                    row_counter <= `WRAP_SIM(#1) row_counter + 1'b1;
                    col_rd_counter <= `WRAP_SIM(#1) 'd0;

                    loader_state <= `WRAP_SIM(#1) STATE_LOADER_CHECK_ROW;
                end
            endcase
        end
    end
/*
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

                        queue_wr_en <= `WRAP_SIM(#1) 1'b1;
                        pixel_color = get_pixel_color(col_counter, NUM_COLOR_BARS);
                        queue_data <= `WRAP_SIM(#1) { 1'b0, pixel_color };
                        col_counter <= `WRAP_SIM(#1) col_counter + 1'b1;
                        loader_state <= `WRAP_SIM(#1) STATE_QUEUE_WR_DONE;
                    end
                end
                STATE_QUEUE_WR_DONE: begin
                    queue_wr_en <= `WRAP_SIM(#1) 1'b0;
                    loader_state <= `WRAP_SIM(#1) STATE_WRITE_ROW;
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
*/
endmodule
