`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

import ColorUtilities::*;

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;
localparam FRAME_WIDTH = 640;
localparam FRAME_HEIGHT = 20;
localparam MEM_READ_DELAY = 6;

localparam NUM_COLOR_BARS = 10;
localparam Colorbar_width = FRAME_WIDTH / NUM_COLOR_BARS;

reg clk, reset_n;
reg fb_clk;
reg [16:0] cam_data_in;
reg cam_data_in_wr_en;

wire memory_clk;

reg init_done_0;
reg lcd_queue_rd_en;
reg recv_rdy = 1'b0;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wire [16:0] lcd_queue_data_in;
wire [16:0] lcd_queue_data_out;
wire lcd_queue_wr_en;
wire lcd_queue_empty;
wire lcd_queue_full;
wire pll_lock;

logic [15:0] bar_colors[NUM_COLOR_BARS];
logic [10:0] row_counter, col_counter, total_pixels;

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

wire command_valid;
wire [1:0] command_data;
wire [31:0] pixel_data;

reg [1:0] command_data_recv;

DebugPatternGenerator2
#(
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT)
)
pattern_generator
(
    .clk_cam(clk),
    .clk_mem(fb_clk),
    .reset_n(reset_n),
    .init(pll_lock),
    .mem_controller_rdy(recv_rdy),
    .command_data_valid(command_valid),
    .command_data(command_data),
    .mem_addr(col_counter[10:1]),
    .pixel_data(pixel_data)
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
    WAIT_FRAME_START,
    READ_FRAME_START,
    READ_ROW_START,
    WAIT_ROW_START,
    READ_ROW,
    WAIT_FRAME_END,
    FRAME_DONE
} checker_state_t;

checker_state_t checker_state;

always @(posedge fb_clk or negedge reset_n) begin
    if (!reset_n) begin
        row_counter <= #1 'd0;
        col_counter <= #1 'd0;
        recv_rdy <= #1 1'b0;
        command_data_recv <= #1 'd0;

        checker_state <= #1 WAIT_FRAME_START;
    end else begin
        case (checker_state)
            WAIT_FRAME_START: begin
                if (command_valid) begin
                    recv_rdy <= #1 1'b1;
                    command_data_recv <= #1 command_data;
                    checker_state <= #1 READ_FRAME_START;
                end
            end
            READ_FRAME_START: begin
                recv_rdy <= #1 1'b0;
                if (command_data_recv !== 'd1) begin
                    string str;

                    $sformat(str, "Received incorrect command data during frame start: %0d", 
                             command_data_recv);
                    logger.error(module_name, str);
                    `TEST_FAIL
                end else begin
                    row_counter <= #1 'd0;

                    checker_state <= #1 READ_ROW_START;
                    logger.info(module_name, "Received frame start command");
                end
            end
            READ_ROW_START: begin
                if (row_counter === FRAME_HEIGHT && command_valid) begin
                    recv_rdy <= #1 1'b1;
                    command_data_recv <= #1 command_data;

                    checker_state <= #1 WAIT_FRAME_END;
                end else if (command_valid) begin
                    recv_rdy <= #1 1'b1;
                    command_data_recv <= #1 command_data;

                    checker_state <= #1 WAIT_ROW_START;
                end
            end
            WAIT_ROW_START: begin
                recv_rdy <= #1 1'b0;
                if (command_data_recv !== 'd2) begin
                    string str;

                    $sformat(str, "Received incorrect command data during row start: %0d", 
                             command_data_recv);
                    logger.error(module_name, str);
                    `TEST_FAIL
                end else begin
                    col_counter <= #1 'd0;

                    checker_state <= #1 READ_ROW;
                end
            end
            READ_ROW: begin
                if (col_counter === FRAME_WIDTH + MEM_READ_DELAY) begin
                    row_counter <= #1 row_counter + 1'b1;

                    checker_state <= #1 READ_ROW_START;
                end else begin
                    logic [31:0] target_data;

                    if (col_counter >= MEM_READ_DELAY) begin
                        target_data[15:0] = get_pixel_color(col_counter - MEM_READ_DELAY);
                        target_data[31:16] = get_pixel_color(col_counter - MEM_READ_DELAY + 1'b1);

                        if (pixel_data !== target_data) begin
                            string str;

                            $sformat(str, "Invalid pixel data. Actual: %0h, expected: %0h", 
                                     pixel_data, target_data);
                            logger.error(module_name, str);

                            `TEST_FAIL
                        end
                    end
                    col_counter <= #1 col_counter + 'd2;
                end
            end
            WAIT_FRAME_END: begin
                recv_rdy <= #1 1'b0;
                if (command_data_recv === 'd3) begin
                    logger.info(module_name, "Frame received successfully");

                    checker_state <= #1 FRAME_DONE;
                end else begin
                    string str;

                    $sformat(str, "Received incorrect command data during frame end: %0d", 
                             command_data_recv);
                    logger.error(module_name, str);
                    `TEST_FAIL
                end
            end
            FRAME_DONE: begin
                frame_checking_complete <= #1 1'b1;
            end
        endcase
    end
end

always #500000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
