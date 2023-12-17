`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

import ColorUtilities::*;

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;
localparam FRAME_WIDTH = 480;
localparam FRAME_HEIGHT = 272;

localparam NUM_COLOR_BARS = 10;
localparam Colorbar_width = FRAME_WIDTH / NUM_COLOR_BARS;

reg clk, reset_n;
reg fb_clk;
reg [16:0] cam_data_in;
reg cam_data_in_wr_en;

wire memory_clk;

reg init_done_0;
reg lcd_queue_rd_en;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

assign cam_clk = clk;

wire [16:0] lcd_queue_data_in;
wire [16:0] lcd_queue_data_out;
wire lcd_queue_wr_en;
wire lcd_queue_empty;
wire lcd_queue_full;

FIFO_cam lcd_Debug_queue(
    .Data(lcd_queue_data_in), //input [16:0] Data
    .WrReset(~reset_n), //input WrReset
    .RdReset(~reset_n), //input RdReset
    .WrClk(fb_clk), //input WrClk
    .RdClk(clk), //input RdClk
    .WrEn(lcd_queue_wr_en), //input WrEn
    .RdEn(lcd_queue_rd_en), //input RdEn
    .Q(lcd_queue_data_out), //output [16:0] Q
    .Empty(lcd_queue_empty), //output Empty
    .Full(lcd_queue_full) //output Full
);

DebugPatternGenerator
#(
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT)
)

pattern_generator
(
    .clk(fb_clk),
    .reset_n(reset_n),

    .queue_full(lcd_queue_full),
    
    .queue_data(lcd_queue_data_in),
    .queue_wr_en(lcd_queue_wr_en)
);

initial begin
    integer i;
    logic error;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    error = 1'b0;
    $sformat(module_name, "%m");

    logger.info(module_name, " << Starting the Simulation >>");
    // initially values
    clk = 0;
    cam_data_in_wr_en = 1'b0;
    init_done_0 = 1'b0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");

    @(posedge clk);

    @(posedge clk);

    init_done_0 = 1'b1;


    repeat(1) @(posedge fb_clk);
    repeat(1) @(negedge fb_clk);

    if (error)
        `TEST_FAIL
end

always #18.519 clk=~clk;

SDRAM_rPLL sdram_clock(.reset(~reset_n), .clkin(clk), .clkout(memory_clk), .lock(pll_lock));

always @(posedge memory_clk or negedge reset_n) begin
    if (!reset_n)
        fb_clk <= #1 1'b0;
    else if (pll_lock)
        fb_clk <= #1 ~fb_clk;
end

integer row_counter, col_counter;

typedef enum {
    IDLE,
    WAIT_START_FRAME
} state_t;

state_t checker_state;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        row_counter <= #1 0;
        col_counter <= #1 0;

        checker_state <= #1 IDLE;
        lcd_queue_rd_en <= #1 1'b0;
    end else begin
        case (checker_state)
            IDLE: begin
                checker_state <= #1 WAIT_START_FRAME;
            end
            WAIT_START_FRAME: begin
                lcd_queue_rd_en <= #1 1'b1;

                if () begin
                    
                end
            end
        endcase
    end
end

always #60000 begin
    `TEST_PASS
end

endmodule
