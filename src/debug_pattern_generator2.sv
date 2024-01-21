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
    input clk_cam,
    input clk_mem,
    input reset_n,
    input init,

    input mem_controller_rdy,
    input [9:0] mem_addr,

    output [31:0] pixel_data,
    output [1:0] command_data,
    output command_data_valid
);

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    localparam NUM_COLOR_BARS = 10;
    localparam Colorbar_width = FRAME_WIDTH / NUM_COLOR_BARS;

    wire cam_reset_line;
    wire mem_reset_line;

    wire gen_rdy;
    reg [1:0] command_data_in;
    reg [10:0] col_counter = 'd0;
    reg [10:0] row_counter = 'd0;
    reg [31:0] input_pixel = 'd0;
    reg gen_valid = 1'b0;

    import ColorUtilities::*;

    logic [15:0] bar_colors[NUM_COLOR_BARS];

    initial begin
        logic [3:0] i;
        logic [15:0] c;

        for (i = 0; i < NUM_COLOR_BARS; i = i + 1) begin
            c = get_rgb_color(i);
            bar_colors[i] = c;
        end
    end

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

    Reset_Synchronizer
    #(
        .EXTRA_DEPTH(1),
        .RESET_ACTIVE_STATE(1)
    ) 
    cam_reset
    (
        .receiving_clock(clk_cam),
        .reset_in(~reset_n),
        .reset_out(cam_reset_line)
    );

    Reset_Synchronizer
    #(
        .EXTRA_DEPTH(1),
        .RESET_ACTIVE_STATE(1)
    ) 
    mem_reset
    (
        .receiving_clock(clk_mem),
        .reset_in(~reset_n),
        .reset_out(mem_reset_line)
    );

    CDC_Word_Synchronizer
    #(
        .WORD_WIDTH(2),
        .EXTRA_CDC_DEPTH(1),
        .OUTPUT_BUFFER_TYPE("SKID")
    )
    command_synchronizer
    (
        .sending_clock(clk_cam),
        .sending_clear(cam_reset_line),
        .sending_data(command_data_in),
        .sending_valid(gen_valid),
        .sending_ready(gen_rdy),

        .receiving_clock(clk_mem),
        .receiving_clear(mem_reset_line),
        .receiving_data(command_data), 
        .receiving_valid(command_data_valid),
        .receiving_ready(mem_controller_rdy)
    );

    wire [31:0] pixel_data_a, pixel_data_b;
    reg write_buffer_id = 1'b0;

    assign pixel_data = (write_buffer_id == 1'b0) ? pixel_data_b : pixel_data_a;

    reg clk_cam_en_a;
    reg clk_cam_en_b;
    reg clk_mem_en_a;
    reg clk_mem_en_b;

    sdpb_1kx32 row_a(
        .dout(pixel_data_a), //output [31:0] dout
        .clka(clk_cam), //input clka
        .cea(clk_cam_en_a), //input cea
        .reseta(cam_reset_line), //input reseta
        .clkb(clk_mem), //input clkb
        .ceb(clk_mem_en_a), //input ceb
        .resetb(mem_reset_line), //input resetb
        .oce(clk_mem_en_a), //input oce
        .ada(col_counter[10:1]), //input [9:0] ada
        .din(input_pixel), //input [31:0] din
        .adb(mem_addr) //input [9:0] adb
    );

    sdpb_1kx32 row_b(
        .dout(pixel_data_b), //output [31:0] dout
        .clka(clk_cam), //input clka
        .cea(clk_cam_en_b), //input cea
        .reseta(cam_reset_line), //input reseta
        .clkb(clk_mem), //input clkb
        .ceb(clk_mem_en_b), //input ceb
        .resetb(mem_reset_line), //input resetb
        .oce(clk_mem_en_b), //input oce
        .ada(col_counter[10:1]), //input [9:0] ada
        .din(input_pixel), //input [31:0] din
        .adb(mem_addr) //input [9:0] adb
    );

    typedef enum bit[7:0] {
        IDLE,
        WRITE_FRAME_START,
        PREPARE_ROW_START,
        PREPARE_ROW,
        WRITE_ROW_START,
        CHECK_ROW_COUNT,
        WRITE_FRAME_END,
        FRAME_DONE
    } state_t;

    state_t state;

    always @(posedge clk_cam or negedge reset_n) begin
        if (!reset_n) begin
            gen_valid <= `WRAP_SIM(#1) 1'b0;
            command_data_in <= `WRAP_SIM(#1) 'd0;
            col_counter <= `WRAP_SIM(#1) 'd0;
            input_pixel <= `WRAP_SIM(#1) 'd0;
            write_buffer_id <= `WRAP_SIM(#1) 1'b0;
            clk_cam_en_a <= `WRAP_SIM(#1) 1'b0;
            clk_cam_en_b <= `WRAP_SIM(#1) 1'b0;
            clk_mem_en_a <= `WRAP_SIM(#1) 1'b0;
            clk_mem_en_b <= `WRAP_SIM(#1) 1'b0;
            row_counter <= `WRAP_SIM(#1) 'd0;

            state <= `WRAP_SIM(#1) IDLE;
        end else begin
            case (state)
                IDLE: begin
                    if (init)
                        state <= `WRAP_SIM(#1) WRITE_FRAME_START;
                end
                WRITE_FRAME_START: begin
                    if (gen_rdy) begin
                        gen_valid <= `WRAP_SIM(#1) 1'b1;
                        command_data_in <= `WRAP_SIM(#1) 'd1;
                        row_counter <= `WRAP_SIM(#1) 'd0;

                        state <= `WRAP_SIM(#1) CHECK_ROW_COUNT;

`ifdef __ICARUS__
                        logger.info(module_name, "Start frame generation");
`endif
                    end
                end
                CHECK_ROW_COUNT: begin
                    gen_valid <= `WRAP_SIM(#1) 1'b0;

                    if (row_counter === FRAME_HEIGHT) begin
                        state <= `WRAP_SIM(#1) WRITE_FRAME_END;
                    end else begin
                        state <= `WRAP_SIM(#1) PREPARE_ROW_START;
                    end
                end
                PREPARE_ROW_START: begin
                    gen_valid <= `WRAP_SIM(#1) 1'b0;
                    col_counter <= `WRAP_SIM(#1) 'd0;

                    if (!write_buffer_id) begin
                        clk_cam_en_a <= `WRAP_SIM(#1) 1'b1;
                    end else begin
                        clk_cam_en_b <= `WRAP_SIM(#1) 1'b1;
                    end

                    input_pixel[15:0] <= `WRAP_SIM(#1) get_pixel_color('d0);
                    input_pixel[31:16] <= `WRAP_SIM(#1) get_pixel_color('d1);

                    state <= `WRAP_SIM(#1) PREPARE_ROW;
                end
                PREPARE_ROW: begin
                    if (col_counter === FRAME_WIDTH) begin
                        clk_cam_en_a <= `WRAP_SIM(#1) 1'b0;
                        clk_cam_en_b <= `WRAP_SIM(#1) 1'b0;

                        if (write_buffer_id == 1'b0) begin
                            clk_mem_en_a <= `WRAP_SIM(#1) 1'b1;
                            clk_mem_en_b <= `WRAP_SIM(#1) 1'b0;
                        end else begin
                            clk_mem_en_a <= `WRAP_SIM(#1) 1'b0;
                            clk_mem_en_b <= `WRAP_SIM(#1) 1'b1;
                        end

                        write_buffer_id <= `WRAP_SIM(#1) ~write_buffer_id;

                        state <= `WRAP_SIM(#1) WRITE_ROW_START;
                    end else begin
                        logic [11:0] tmp;

                        input_pixel[15:0] <= `WRAP_SIM(#1) get_pixel_color(col_counter);
                        input_pixel[31:16] <= `WRAP_SIM(#1) get_pixel_color(col_counter + 1'b1);

                        tmp = col_counter + 'd2;
                        col_counter <= `WRAP_SIM(#1) tmp[10:0];
                    end
                end
                WRITE_ROW_START: begin
                    if (gen_rdy) begin
                        gen_valid <= `WRAP_SIM(#1) 1'b1;
                        command_data_in <= `WRAP_SIM(#1) 'd2;
                        row_counter <= `WRAP_SIM(#1) row_counter + 1'b1;

                        state <= `WRAP_SIM(#1) CHECK_ROW_COUNT;
                    end
                end
                WRITE_FRAME_END: begin
                    if (gen_rdy) begin
                        gen_valid <= `WRAP_SIM(#1) 1'b1;
                        command_data_in <= `WRAP_SIM(#1) 'd3;

                        state <= `WRAP_SIM(#1) FRAME_DONE;
                    end
                end
                FRAME_DONE: begin
                    gen_valid <= `WRAP_SIM(#1) 1'b0;
                    state <= `WRAP_SIM(#1) WRITE_FRAME_START;

`ifdef __ICARUS__
                        logger.info(module_name, "Frame generation finished");
`endif
                end
            endcase
        end
    end

endmodule
