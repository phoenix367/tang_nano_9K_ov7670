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

package FrameDownloaderTypes;
    typedef enum bit[7:0] {
        FRAME_PROCESSING_START_WAIT = 8'b00000001
    } t_state;
endpackage

module FrameDownloader
    #(
`ifdef __ICARUS__
        parameter MODULE_NAME = "",
        parameter LOG_LEVEL = `SVL_VERBOSE_INFO,
`endif

        parameter MEMORY_BURST = 32,
        parameter FRAME_WIDTH = 480,
        parameter FRAME_HEIGHT = 272,
        parameter ORIG_FRAME_WIDTH = 640,
        parameter ORIG_FRAME_HEIGHT = 480
    )
    (
        input clk,
        input reset_n,
        input start,
        input queue_full,
        input read_ack,
        input [20:0] base_addr,
        input reg [31:0] read_data,
        
        output [16:0] queue_data,
        output reg wr_en,
        output reg read_rq,
        output [20:0] read_addr,
        output reg mem_rd_en,
        output reg download_done
    );

    import FrameDownloaderTypes::*;

    localparam CACHE_SIZE = MEMORY_BURST / 2;
    localparam BURST_CYCLES = MEMORY_BURST / 4;

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    t_state state;

    reg [20:0] frame_addr_counter;
    reg [4:0] cache_addr;
    reg [4:0] frame_addr_inc;
    reg [4:0] cache_addr_next;
    reg [4:0] read_counter;
    reg [4:0] read_counter_next;
    reg [5:0] cmd_cyc_counter;
    reg [20:0] pixel_counter;
    reg cache_in_en;
    reg cache_out_en;
    reg frame_download_cycle;
    reg adder_ce;

    wire [31:0] mem_word;
    wire [21:0] adder_out;

    assign cache_addr_next = cache_addr + 1'b1;
    assign read_addr = frame_addr_counter;
    assign read_counter_next = read_counter + 1'b1;

    Gowin_ALU54 frame_addr_adder(
        .dout(adder_out), //output [21:0] dout
        .caso(), //output [54:0] caso
        .a(frame_addr_counter), //input [20:0] a
        .b(frame_addr_inc), //input [4:0] b
        .ce(adder_ce), //input ce
        .clk(clk), //input clk
        .reset(~reset_n) //input reset
    );

    Gowin_SDPB_DN download_cache(
        .dout(), 
        .clka(clk), 
        .cea(cache_in_en), 
        .reseta(~reset_n), 
        .clkb(clk), 
        .ceb(cache_out_en), 
        .resetb(~reset_n), 
        .oce(1'b0), 
        .ada(read_counter[2:0]), 
        .din(mem_word), 
        .adb(cache_addr[3:0])
    );

    initial begin
        read_rq <= `WRAP_SIM(#1) 1'b0;
        mem_rd_en <= `WRAP_SIM(#1) 1'b0;
        download_done <= `WRAP_SIM(#1) 1'b0;
        wr_en <= `WRAP_SIM(#1) 1'b0;
        download_done <= `WRAP_SIM(#1) 1'b0;
    end

    initial
        frame_addr_counter <= `WRAP_SIM(#1) 'd0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            cmd_cyc_counter <= `WRAP_SIM(#1) 'd0;
        else begin
        end
    end
endmodule
