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

    input mem_controller_rdy,

    output [31:0] pixel_data,
    output [1:0] command_data,
    output command_data_valid
);

    wire cam_reset_line;
    wire mem_reset_line;

    reg gen_rdy = 1'b0;
    reg [1:0] command_data_in;

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
        .sending_data(command_data),
        .sending_valid(),
        .sending_ready(),

        .receiving_clock(clk_mem),
        .receiving_clear(mem_reset_line),
        .receiving_data(command_data), 
        .receiving_valid(command_data_valid),
        .receiving_ready(mem_controller_rdy)
    );

    always @(posedge clk_cam or negedge reset_n) begin
        if (!reset_n) begin
            gen_rdy <= `WRAP_SIM(#1) 1'b0;
            command_data_in <= `WRAP_SIM(#1) 'd0;
        end else begin
        end
    end

endmodule
