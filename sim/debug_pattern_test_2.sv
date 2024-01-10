`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

import ColorUtilities::*;

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;
localparam FRAME_WIDTH = 640;
localparam FRAME_HEIGHT = 20;

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

assign cam_clk = clk & pll_lock;

wire [16:0] lcd_queue_data_in;
wire [16:0] lcd_queue_data_out;
wire lcd_queue_wr_en;
wire lcd_queue_empty;
wire lcd_queue_full;

logic [15:0] bar_colors[NUM_COLOR_BARS];
integer row_counter, col_counter, total_pixels;

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

FIFO_cam lcd_Debug_queue(
    .Data(lcd_queue_data_in), //input [16:0] Data
    .WrReset(~reset_n), //input WrReset
    .RdReset(~reset_n), //input RdReset
    .WrClk(cam_clk), //input WrClk
    .RdClk(fb_clk), //input RdClk
    .WrEn(lcd_queue_wr_en), //input WrEn
    .RdEn(lcd_queue_rd_en), //input RdEn
    .Q(lcd_queue_data_out), //output [16:0] Q
    .Empty(lcd_queue_empty), //output Empty
    .Full(lcd_queue_full) //output Full
);

DebugPatternGenerator2
#(
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT)
)

pattern_generator
(
    .clk(cam_clk),
    .reset_n(reset_n),

    .queue_full(lcd_queue_full),
    
    .queue_data(lcd_queue_data_in),
    .queue_wr_en(lcd_queue_wr_en)
);

logic frame_checking_complete;

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
    frame_checking_complete = 1'b0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");

    repeat(1) @(posedge frame_checking_complete);

    if (total_pixels != FRAME_WIDTH * FRAME_HEIGHT) begin
        logger.error(module_name, "Incorrect total number of received pixels");
        `TEST_FAIL
    end

    if (row_counter != FRAME_HEIGHT) begin
        logger.error(module_name, "Incorrect total number of received frame rows");
        `TEST_FAIL
    end

    `TEST_PASS
end

always #18.519 clk=~clk;

SDRAM_rPLL sdram_clock(.reset(~reset_n), .clkin(clk), .clkout(memory_clk), .lock(pll_lock));

always @(posedge memory_clk or negedge reset_n) begin
    if (!reset_n)
        fb_clk <= #1 1'b0;
    else if (pll_lock)
        fb_clk <= #1 ~fb_clk;
end

typedef enum {
    IDLE,
    WAIT_START_FRAME,
    WAIT_ROW_START,
    READ_ROW,
    READ_ROW_FINISHED,
    WAIT_END_FRAME,
    TEST_COMPLETE
} state_t;

state_t checker_state;

always @(posedge fb_clk or negedge reset_n) begin
    if (!reset_n) begin
        row_counter <= #1 0;
        col_counter <= #1 0;

        checker_state <= #1 IDLE;
        lcd_queue_rd_en <= #1 1'b0;
        total_pixels <= #1 0;
    end else begin
        case (checker_state)
            IDLE: begin
                checker_state <= #1 WAIT_START_FRAME;
                row_counter <= #1 0;
                col_counter <= #1 0;

                lcd_queue_rd_en <= #1 1'b1;
            end
            WAIT_START_FRAME: begin
                if (!lcd_queue_empty && lcd_queue_data_out === 17'h10000) begin
                    checker_state <= #1 WAIT_ROW_START;
                end else if (!lcd_queue_empty) begin
                    string str;

                    $sformat(str, "Unexpected value received instead of frame start: %0h", 
                             lcd_queue_data_out);
                    logger.error(module_name, str);

                    `TEST_FAIL
                end
            end
            WAIT_ROW_START: begin
                if (lcd_queue_empty)
                    ; // Do nothing
                else if (lcd_queue_data_out === 17'h10001) begin
                    checker_state <= #1 READ_ROW;
                end else begin
                    string str;

                    $sformat(str, "Unexpected value received instead of row start: %0h", 
                             lcd_queue_data_out);
                    logger.error(module_name, str);

                    `TEST_FAIL
                end
            end
            READ_ROW: begin
                if (lcd_queue_empty)
                    ; // Do nothing
                else begin
                    logic [15:0] expected_pixel;
                    
                    expected_pixel = get_pixel_color(col_counter);
                    if (lcd_queue_data_out[16] == 1'b1) begin
                        logger.error(module_name, "Unexpected command instead pixel data");
                        `TEST_FAIL
                    end else if (lcd_queue_data_out[15:0] !== expected_pixel) begin
                        string str;

                        $sformat(str, "Unexpected pixel value %0h, expected %0h", 
                                 lcd_queue_data_out[15:0], expected_pixel);
                        logger.error(module_name, str);
                        `TEST_FAIL
                    end else
                        total_pixels <= #1 total_pixels + 1;

                    if (col_counter + 1 == FRAME_WIDTH) begin
                        col_counter <= #1 0;
                        row_counter <= #1 row_counter + 1;
                        lcd_queue_rd_en <= #1 1'b0;

                        checker_state <= #1 READ_ROW_FINISHED;
                    end else begin
                        col_counter <= #1 col_counter + 1;
                    end
                end
            end
            READ_ROW_FINISHED: begin
                lcd_queue_rd_en <= #1 1'b1;

                if (row_counter === FRAME_HEIGHT) begin
                    checker_state <= #1 WAIT_END_FRAME;
                end else begin
                    col_counter <= #1 0;

                    checker_state <= #1 WAIT_ROW_START;
                end
            end
            WAIT_END_FRAME: begin
                if (lcd_queue_empty)
                    ; // Do nothing
                else if (lcd_queue_data_out === 17'h1FFFF) begin
                    logger.info(module_name, "Complete frame command received");
                    frame_checking_complete <= 1'b1;

                    checker_state <= #1 TEST_COMPLETE;
                end else begin
                    string str;

                    $sformat(str, "Unexpected value received instead of frame end: %0h", 
                             lcd_queue_data_out);
                    logger.error(module_name, str);

                    `TEST_FAIL
                end                
            end
            TEST_COMPLETE: ;
        endcase
    end
end

always #5000000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
