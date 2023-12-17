`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

localparam FRAME_WIDTH = 23;
localparam FRAME_HEIGHT = 17;

reg clk, reset_n;
reg fb_clk;
reg [16:0] cam_data_in;
reg cam_data_in_wr_en;

wire memory_clk;
wire screen_clk;

wire queue_load_rd_en;
wire [16:0] cam_data_queue_out;
wire [16:0] cam_data_queue_out_d;
wire queue_load_empty;
wire queue_load_empty_d;
wire queue_load_full;
wire queue_load_full_d;
wire queue_load_clk;

assign #1 queue_load_empty_d = queue_load_empty;
assign #1 queue_load_full_d = queue_load_full;
assign #1 cam_data_queue_out_d = cam_data_queue_out;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

assign cam_clk = clk;

wire mem_cmd;
wire mem_cmd_en;

wire [20:0] mem_addr;
wire [31:0] mem_w_data;

logic [15:0] data_items[FRAME_WIDTH * FRAME_HEIGHT];

FIFO_cam q_cam_data_in(
    .Data(cam_data_in), //input [16:0] Data
    .WrReset(~reset_n), //input WrReset
    .RdReset(~reset_n), //input RdReset
    .WrClk(fb_clk), //input WrClk
    .RdClk(queue_load_clk), //input RdClk
    .WrEn(cam_data_in_wr_en), //input WrEn
    .RdEn(queue_load_rd_en), //input RdEn
    .Q(cam_data_queue_out), //output [16:0] Q
    .Empty(queue_load_empty), //output Empty
    .Full(queue_load_full) //output Full
);

wire [4:0] lcd_data_r;
wire [5:0] lcd_data_g;
wire [4:0] lcd_data_b;
wire lcd_de;
wire lcd_hsync;
wire lcd_vsync;

LCD_Controller
#(
    .LCD_SCREEN_WIDTH(FRAME_WIDTH),
    .LCD_SCREEN_HEIGHT(FRAME_HEIGHT),
`ifdef __ICARUS__
    .LOG_LEVEL(LOG_LEVEL)
`endif
)
lcd_controller
(
    .clk(screen_clk),
    .reset_n(reset_n),
    .queue_data_in(cam_data_queue_out_d),
    .queue_empty(queue_load_empty_d),

    .queue_rd_en(queue_load_rd_en),
    .queue_clk(queue_load_clk),

    .LCD_DE(lcd_de),
    .LCD_HSYNC(lcd_hsync),
    .LCD_VSYNC(lcd_vsync),

	.LCD_B(lcd_data_b),
	.LCD_G(lcd_data_g),
	.LCD_R(lcd_data_r)
);

integer pixel_idx;

always @(posedge screen_clk or negedge reset_n) begin
    if (!reset_n) begin
        pixel_idx = 0;
    end else begin
        if (lcd_de) begin
            logic [15:0] pixel_data;

            if (lcd_hsync || lcd_vsync) begin
                logger.error(module_name, "Unexpected VSYNC or HSYNC signal received");
                `TEST_FAIL
            end

            pixel_data = {lcd_data_r, lcd_data_g, lcd_data_b};
            if (pixel_data !== data_items[pixel_idx]) begin
                string str;

                $sformat(str, "Incorrect pixel data. Got %0h, expected %0h", 
                         pixel_data, data_items[pixel_idx]);
                logger.error(module_name, str);

                `TEST_FAIL
            end else
                pixel_idx = pixel_idx + 1;
        end
    end
end

integer vsync_counter, hsync_counter;

always @(posedge lcd_vsync or negedge reset_n) begin
    if (!reset_n) begin
        vsync_counter = 0;
    end else begin
        vsync_counter = vsync_counter + 1;
    end
end

always @(posedge lcd_hsync or negedge reset_n) begin
    if (!reset_n) begin
        hsync_counter = 0;
    end else begin
        hsync_counter = hsync_counter + 1;
    end
end

initial begin
    integer i;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    $sformat(module_name, "%m");

    for (i = 0; i < FRAME_WIDTH * FRAME_HEIGHT; i = i + 1)
        data_items[i] = $urandom();

    logger.info(module_name, " << Starting the Simulation >>");
    // initially values
    clk = 0;
    cam_data_in_wr_en = 1'b0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");

    @(posedge clk);

    @(posedge clk);

    #240000;

    if (!queue_load_empty_d) begin
        logger.error(module_name, "Queue not empty!");
        `TEST_FAIL
    end else if (pixel_idx != FRAME_WIDTH * FRAME_HEIGHT) begin
        logger.error(module_name, "Invalid number of pixels passed to LCD");
        `TEST_FAIL
    end else if (vsync_counter != 1) begin
        logger.error(module_name, "Invalid number of VSYNC pulses");
        `TEST_FAIL
    end else if (hsync_counter != lcd_controller.PixelForVS) begin
        logger.error(module_name, "Invalid number of HSYNC pulses");
        `TEST_FAIL
    end

    `TEST_PASS
end

integer row_counter, col_counter;

typedef enum {
    STATE_IDLE,
    STATE_WRITE_ROW_START,
    STATE_WRITE_ROW,
    STATE_WRITE_ROW_END,
    STATE_WRITE_FRAME_DONE
} loader_state_t;

loader_state_t loader_state;

always @(posedge fb_clk or negedge reset_n) begin
    if (!reset_n) begin 
        row_counter <= #1 0;
        col_counter <= #1 0;

        loader_state <= #1 STATE_IDLE;
    end else begin
        case (loader_state)
            STATE_IDLE: if (!queue_load_full) begin
                cam_data_in_wr_en <= #1 1'b1;
                cam_data_in <= #1 17'h10000;

                row_counter <= #1 0;
                col_counter <= #1 0;

                loader_state <= #1 STATE_WRITE_ROW_START;
            end
            STATE_WRITE_ROW_START: if (!queue_load_full) begin
                cam_data_in_wr_en <= #1 1'b1;
                cam_data_in <= #1 17'h10001;

                loader_state <= #1 STATE_WRITE_ROW;
            end
            STATE_WRITE_ROW: begin
                if (col_counter == FRAME_WIDTH && !queue_load_full) begin
                    cam_data_in_wr_en <= #1 1'b0;

                    loader_state <= #1 STATE_WRITE_ROW_END;
                end else if (!queue_load_full) begin
                    logic [15:0] pixel_value;

                    pixel_value = data_items[FRAME_WIDTH * row_counter + col_counter];
                    cam_data_in <= #1 { 1'b0, pixel_value };
                    col_counter <= #1 col_counter + 1;
                end
            end
            STATE_WRITE_ROW_END: begin
                if (row_counter + 1 == FRAME_HEIGHT) begin
                    if (!queue_load_full) begin
                        cam_data_in_wr_en <= #1 1'b1;
                        cam_data_in <= #1 17'h1FFFF;

                        loader_state <= #1 STATE_WRITE_FRAME_DONE;
                    end
                end else begin
                    row_counter <= #1 row_counter + 1;
                    col_counter <= #1 0;

                    loader_state <= #1 STATE_WRITE_ROW_START;
                end
            end
            STATE_WRITE_FRAME_DONE:
                cam_data_in_wr_en <= #1 1'b0;
        endcase
    end
end

always #18.519 clk=~clk;

SDRAM_rPLL sdram_clock(
    .reset(~reset_n), 
    .clkin(clk), 
    .clkout(memory_clk), 
    .clkoutd(screen_clk),
    .lock(pll_lock)
);

always @(posedge memory_clk or negedge reset_n) begin
    if (!reset_n)
        fb_clk <= #1 1'b0;
    else if (pll_lock)
        fb_clk <= #1 ~fb_clk;
end

endmodule
