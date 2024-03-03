`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;
localparam FRAME_WIDTH = 480;
localparam FRAME_HEIGHT = 20;
localparam TOTAL_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;

reg clk, reset_n;
reg fb_clk;
reg [1:0] mem_command_data = 'd0;
reg mem_command_available = 1'b0;
wire mem_command_ack;

wire memory_clk, pll_lock, lcd_clk;

always #18.519 clk=~clk;

SDRAM_rPLL sdram_clock(.reset(~reset_n), .clkin(clk), .clkout(memory_clk), .lock(pll_lock),
                       .clkoutd(lcd_clk));

always @(posedge memory_clk or negedge reset_n) begin
    if (!reset_n)
        fb_clk <= #1 1'b0;
    else if (pll_lock)
        fb_clk <= #1 ~fb_clk;
end

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

reg [10:0] mem_addr = 'd0;
reg [15:0] mem_data = 'd0;
reg mem_data_en = 1'b0;

reg [10:0] lcd_addr = 'd0;
wire [15:0] lcd_data;

reg lcd_command_ack = 1'b0;
wire [1:0] lcd_command_data;
wire lcd_command_available;

DownloadBuffer #(
.LOG_LEVEL(LOG_LEVEL)
) 
download_buffer
(
    .clk_lcd(lcd_clk),
    .clk_mem(fb_clk),
    .reset_n(reset_n),
    .init(1'b0),

    .mem_addr(mem_addr),
    .mem_data(mem_data),
    .mem_data_en(mem_data_en),

    .lcd_addr(lcd_addr),
    .lcd_data(lcd_data),

    .command_data_in(mem_command_data),
    .command_available_in(mem_command_available),
    .buffer_rdy(mem_command_ack),

    .command_data_out(lcd_command_data),
    .command_available_out(lcd_command_available),
    .command_ack(lcd_command_ack)
);

logic [15:0] frame_data[TOTAL_PIXELS];

initial begin
    integer i;

    $sformat(module_name, "%m");

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    for (i = 0; i < TOTAL_PIXELS; i = i + 1) begin
        frame_data[i] = $urandom();
    end

    logger.info(module_name, " << Starting the Simulation >>");
    // initially values
    clk = 0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");
end

initial begin
    integer row_cnt, col_cnt;

    mem_command_data = 'd0;

    repeat(1) @(posedge pll_lock);
    mem_command_data <= #1 'd1;
    mem_command_available <= #1 1'b1;

    repeat(1) @(posedge mem_command_ack);
    mem_command_available <= #1 1'b0;

    for (row_cnt = 0; row_cnt < FRAME_HEIGHT; row_cnt = row_cnt + 1) begin
        logic [10:0] base_addr;

        base_addr = row_cnt * FRAME_WIDTH;
        for (col_cnt = 0; col_cnt < FRAME_WIDTH; col_cnt = col_cnt + 1) begin
            logic [15:0] pixel_in;

            if (col_cnt != 0 && col_cnt % 16 == 0) begin
                integer delay_cnt;

                mem_data_en <= #1 1'b0;
                for (delay_cnt = 0; delay_cnt < 13; delay_cnt = delay_cnt + 1) begin
                    repeat(1) @(posedge fb_clk);
                end
            end

            mem_data_en <= #1 1'b1;
            pixel_in = frame_data[base_addr + col_cnt];
            repeat(1) @(posedge fb_clk);

            mem_data <= #1 pixel_in;
            mem_addr <= #1 col_cnt;
        end

        repeat(1) @(posedge fb_clk);
        mem_data_en <= #1 1'b0;

        repeat(1) @(posedge fb_clk);
        mem_command_data <= #1 'd2;
        mem_command_available <= #1 1'b1;

        repeat(1) @(posedge fb_clk);
        repeat(1) @(posedge fb_clk);
        while (!mem_command_ack) #1;
        mem_command_available <= #1 1'b0;
    end
end

typedef enum {
    READER_IDLE                 = 'd0,
    READER_FRAME_START          = 'd1,
    READER_WAIT_ROW             = 'd2,
    READER_PREPARE_READ_ROW     = 'd3,
    READER_READ_ROW             = 'd4,
    READER_READ_ROW_DONE        = 'd5
} state_t;

state_t state = READER_IDLE;
integer row_counter = 'd0;

always @(posedge lcd_clk or negedge reset_n) begin
    if (!reset_n) begin
        state <= #1 READER_IDLE;
        lcd_command_ack <= #1 1'b0;
        row_counter <= #1 'd0;
        lcd_addr <= #1 'd0;
    end else begin
        case (state)
            READER_IDLE: begin
                if (lcd_command_available) begin
                    if (lcd_command_data === 'd1) begin
                        lcd_command_ack <= #1 1'b1;
                        state <= #1 READER_FRAME_START;
                    end else begin
                        logger.error(module_name, "Unexpected command. Frame start required");
                        `TEST_FAIL
                    end
                end
            end
            READER_FRAME_START: begin
                lcd_command_ack <= #1 1'b0;
                row_counter <= #1 'd0;
                state <= #1 READER_WAIT_ROW;
            end
            READER_WAIT_ROW: begin
                if (lcd_command_available) begin
                    if (lcd_command_data === 'd2) begin
                        lcd_command_ack <= #1 1'b1;
                        state <= #1 READER_PREPARE_READ_ROW;
                    end else begin
                        logger.error(module_name, "Unexpected command. Row start required");
                        `TEST_FAIL
                    end
                end                
            end
            READER_PREPARE_READ_ROW: begin
                lcd_command_ack <= #1 1'b0;
                lcd_addr <= #1 'd0;

                state <= #1 READER_READ_ROW;
            end
            READER_READ_ROW: begin
                if (lcd_addr === FRAME_WIDTH) begin
                    row_counter <= #1 row_counter + 1'b1;
                    state <= #1 READER_READ_ROW_DONE;
                end else begin
                    integer mem_addr;

                    mem_addr = row_counter * FRAME_WIDTH + lcd_addr;
                    if (lcd_data !== frame_data[mem_addr]) begin
                        string str;

                        $sformat(str, "");
                        logger.error(module_name, str);

                        `TEST_FAIL
                    end else begin
                        lcd_addr <= #1 lcd_addr + 1'b1;
                    end
                end
            end
            READER_READ_ROW_DONE: begin
                if (row_counter === FRAME_HEIGHT) begin

                end else
                    state <= #1 READER_WAIT_ROW;
            end
        endcase
    end
end

always #500000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
