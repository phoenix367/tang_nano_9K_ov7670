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

`default_nettype wire

module DownloadBuffer
#(
`ifdef __ICARUS__
        parameter MODULE_NAME = "",
        parameter LOG_LEVEL = `SVL_VERBOSE_INFO
`endif
)
(
    input clk_lcd,
    input clk_mem,
    input reset_n,
    input init,

    input [10:0] mem_addr,
    input [15:0] mem_data,
    input mem_data_en,

    input [10:0] lcd_addr,
    output [15:0] lcd_data,

    input [1:0] command_data_in,
    input command_available_in,
    output buffer_rdy,
    output row_read_ack,

    output [1:0] command_data_out,
    output command_available_out,
    input command_ack,
    input row_read_done
);

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    wire [15:0] pixel_data_a;
    wire [15:0] pixel_data_b;

    reg write_buffer_id = 1'b0;
    reg mem_output_en_a = 1'b0;
    reg mem_output_en_b = 1'b0;
    reg mem_input_en_a = 1'b0;
    reg mem_input_en_b = 1'b0;

    assign lcd_data = (write_buffer_id == 1'b0) ? pixel_data_b : pixel_data_a;

    Reset_Synchronizer
    #(
        .RESET_ACTIVE_STATE(1)
    ) 
    cam_reset
    (
        .receiving_clock(clk_lcd),
        .reset_in(~reset_n),
        .reset_out(lcd_reset_line)
    );

    Reset_Synchronizer
    #(
        .RESET_ACTIVE_STATE(1)
    ) 
    mem_reset
    (
        .receiving_clock(clk_mem),
        .reset_in(~reset_n),
        .reset_out(mem_reset_line)
    );

    sdpb_2kx16 row_a(
        .dout(pixel_data_a), //output [15:0] dout
        .clka(clk_mem), //input clka
        .cea(mem_input_en_a), //input cea
        .reseta(mem_reset_line), //input reseta
        .clkb(clk_lcd), //input clkb
        .ceb(mem_output_en_a), //input ceb
        .resetb(lcd_reset_line), //input resetb
        .oce(mem_output_en_a), //input oce
        .ada(mem_addr), //input [10:0] ada
        .din(mem_data), //input [15:0] din
        .adb(lcd_addr) //input [10:0] adb
    );

    sdpb_2kx16 row_b(
        .dout(pixel_data_b), //output [15:0] dout
        .clka(clk_mem), //input clka
        .cea(mem_input_en_b), //input cea
        .reseta(mem_reset_line), //input reseta
        .clkb(clk_lcd), //input clkb
        .ceb(mem_output_en_b), //input ceb
        .resetb(lcd_reset_line), //input resetb
        .oce(mem_output_en_b), //input oce
        .ada(mem_addr), //input [10:0] ada
        .din(mem_data), //input [15:0] din
        .adb(lcd_addr) //input [10:0] adb
    );

    CDC_Word_Synchronizer
    #(
        .WORD_WIDTH(2),
        .OUTPUT_BUFFER_TYPE("HALF")
    )
    command_synchronizer
    (
        .sending_clock(clk_mem),
        .sending_clear(mem_reset_line),
        .sending_data(command_data_in),
        .sending_valid(command_available_in),
        .sending_ready(buffer_rdy),

        .receiving_clock(clk_lcd),
        .receiving_clear(lcd_reset_line),
        .receiving_data(command_data_out), 
        .receiving_valid(command_available_out),
        .receiving_ready(command_ack)
    );

    CDC_Pulse_Synchronizer_2phase row_read_synchronizer (
        .sending_clock(clk_lcd),
        .sending_pulse_in(row_read_done),
        .sending_ready(),

        .receiving_clock(clk_mem),
        .receiving_pulse_out(row_read_ack)
    );


    typedef enum {
        IDLE                = 'd0,
        WAIT_ROW_SWITCH     = 'd1,
        SWITCH_ROW          = 'd2,
        WAIT_RESET          = 'd3
    } state_t;

    state_t state = IDLE;

    always @(posedge clk_mem or posedge reset_n) begin
        if (!reset_n) begin
            write_buffer_id <= `WRAP_SIM(#1) 1'b0;
            mem_output_en_a <= `WRAP_SIM(#1) 1'b0;
            mem_output_en_b <= `WRAP_SIM(#1) 1'b0;
            mem_input_en_a <= `WRAP_SIM(#1) 1'b0;
            mem_input_en_b <= `WRAP_SIM(#1) 1'b0;

            state <= `WRAP_SIM(#1) IDLE;
        end else begin
            case (state)
                IDLE: begin
                    if (mem_reset_line)
                        state <= `WRAP_SIM(#1) WAIT_RESET;
                end
                WAIT_RESET: begin
                    if (!mem_reset_line) begin
                        mem_input_en_a <= `WRAP_SIM(#1) 1'b1;
                        state <= `WRAP_SIM(#1) WAIT_ROW_SWITCH;
                    end
                end
                WAIT_ROW_SWITCH: begin
                    if (command_data_in == 'd2 && buffer_rdy && command_available_in)
                        state <= `WRAP_SIM(#1) SWITCH_ROW;
                end
                SWITCH_ROW: begin
                    if (write_buffer_id) begin
                        mem_input_en_a <= `WRAP_SIM(#1) 1'b1;
                        mem_input_en_b <= `WRAP_SIM(#1) 1'b0;

                        mem_output_en_a <= `WRAP_SIM(#1) 1'b0;
                        mem_output_en_b <= `WRAP_SIM(#1) 1'b1;
                    end else begin
                        mem_input_en_a <= `WRAP_SIM(#1) 1'b0;
                        mem_input_en_b <= `WRAP_SIM(#1) 1'b1;

                        mem_output_en_a <= `WRAP_SIM(#1) 1'b1;
                        mem_output_en_b <= `WRAP_SIM(#1) 1'b0;
                    end

                    write_buffer_id <= `WRAP_SIM(#1) ~write_buffer_id;

                    state <= `WRAP_SIM(#1) WAIT_ROW_SWITCH;
                end
            endcase
        end
    end
endmodule
