`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Test for pillarbox borders WITHOUT horizontal downscale
// (ENABLE_OUTPUT_RESIZE = 1): each output row is
//
//   row-start 0x10001
//   cols [0, 58)    -> black 0x00000          (left border)
//   cols [58, 421)  -> 363 active pixels       (1:1 centre crop of source)
//   cols [421, 480) -> black 0x00000          (right border)
//
// The active region is a 1:1 centre crop: active pixel a of output row r is
// source (row R_r, column CROP_OFFSET + a) with CROP_OFFSET = (640-363)/2 =
// 138, and R_r = round(480/272 * r) is the vertically-resized source row.
// Source PSRAM is filled with data_items[addr] = addr; only a few output
// rows are exercised so addresses stay < 65536 (no 16-bit wrap), letting
// each captured pixel decode to its exact source address.
//
// Capture is on the store WRITE side with store_queue_full tied low, so the
// check is immune to async-FIFO read races.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;

localparam CAM_FRAME_WIDTH  = 640;
localparam CAM_FRAME_HEIGHT = 480;
localparam LCD_FRAME_WIDTH  = 480;
localparam LCD_FRAME_HEIGHT = 272;

localparam ACTIVE_WIDTH = 362;   // RESIZED_WIDTH = int(272*640/480)
localparam LEFT_BORDER  = (LCD_FRAME_WIDTH - ACTIVE_WIDTH) / 2;   // 58
localparam ACTIVE_END   = LEFT_BORDER + ACTIVE_WIDTH;            // 421
localparam CROP_OFFSET  = 0;   // no left crop: active = leftmost source cols 0..ACTIVE_WIDTH-1

reg clk, reset_n;
reg fb_clk;
wire memory_clk, lcd_clock, pll_lock;
reg init_done_0;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wire        mem_cmd, mem_cmd_en;
wire [20:0] mem_addr;
wire [31:0] mem_w_data;
reg  [31:0] mem_r_data;
reg         mem_r_data_valid;

wire        store_wr_en;
wire [16:0] store_queue_data;

logic [15:0] data_items[3 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 3 * 32];

localparam CAP_MAX = LCD_FRAME_HEIGHT * (1 + LCD_FRAME_WIDTH) + 64;
reg [16:0] cap [0:CAP_MAX-1];
integer    cap_n;
reg        saw_frame_end;

always @(posedge fb_clk or negedge reset_n) begin
    if (!reset_n) begin
        cap_n <= 0; saw_frame_end <= 1'b0;
    end else if (store_wr_en && cap_n < CAP_MAX) begin
        cap[cap_n] <= store_queue_data;
        cap_n      <= cap_n + 1;
        if (store_queue_data === 17'h1FFFF) saw_frame_end <= 1'b1;
    end
end

VideoController #(
    .MEMORY_BURST(32),
    .INPUT_IMAGE_WIDTH(CAM_FRAME_WIDTH),
    .INPUT_IMAGE_HEIGHT(CAM_FRAME_HEIGHT),
    .OUTPUT_IMAGE_WIDTH(LCD_FRAME_WIDTH),
    .OUTPUT_IMAGE_HEIGHT(LCD_FRAME_HEIGHT),
    .ENABLE_OUTPUT_RESIZE(1)
`ifdef __ICARUS__
    , .LOG_LEVEL(LOG_LEVEL)
`endif
) frame_buffer(
    .clk(fb_clk), .rst_n(reset_n), .init_done(init_done_0),
    .cmd(mem_cmd), .cmd_en(mem_cmd_en), .addr(mem_addr),
    .wr_data(mem_w_data), .rd_data(mem_r_data), .rd_data_valid(mem_r_data_valid),
    .error(), .data_mask(),
    .load_clk_o(), .load_read_rdy(), .load_command_valid(1'b0),
    .load_pixel_data('d0), .load_mem_addr(), .load_command_data(2'd0),
    .store_clk_o(), .store_wr_en(store_wr_en),
    .store_queue_full(1'b0), .store_queue_data(store_queue_data)
);

always #18.519 clk = ~clk;
SDRAM_rPLL sdram_clock(.reset(~reset_n), .clkin(clk), .clkout(memory_clk),
                       .lock(pll_lock), .clkoutd(lcd_clock));
always @(posedge memory_clk or negedge reset_n)
    if (!reset_n) fb_clk <= #1 1'b0;
    else if (pll_lock) fb_clk <= #1 ~fb_clk;

initial begin
    integer j, base_addr;
    mem_r_data = 'd0; mem_r_data_valid = 1'b0;
    repeat(1) @(posedge init_done_0);
    forever begin
        repeat(1) @(posedge mem_cmd_en);
        if (mem_cmd == 1'b0) begin
            base_addr = mem_addr;
            for (j = 0; j < 4; j = j + 1) repeat(1) @(posedge fb_clk);
            for (j = 0; j < 8; j = j + 1) begin
                repeat(1) @(posedge fb_clk);
                mem_r_data_valid = #1 1'b1;
                mem_r_data = {data_items[base_addr + 2*j + 1], data_items[base_addr + 2*j]};
            end
            repeat(1) @(posedge fb_clk);
            mem_r_data_valid = #1 1'b0;
        end
    end
end

integer kept [0:CAM_FRAME_WIDTH-1];   // DDA-selected source columns (of the full 640-wide row)

initial begin
    integer i, row, col, idx, a, R, exp_addr, prev_R, nk, acc;
    string  str;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    for (i = 0; i < $size(data_items); i = i + 1)
        data_items[i] = (i % CAM_FRAME_WIDTH);   // encode source column

    // model the DDA: which of the CAM_FRAME_WIDTH (640) source columns the block
    // keeps when downscaling the full row to ACTIVE_WIDTH
    acc = 0; nk = 0;
    for (i = 0; i < CAM_FRAME_WIDTH; i = i + 1)
        if (acc + ACTIVE_WIDTH >= CAM_FRAME_WIDTH) begin
            kept[nk] = i; nk = nk + 1;
            acc = acc + ACTIVE_WIDTH - CAM_FRAME_WIDTH;
        end else
            acc = acc + ACTIVE_WIDTH;

    clk = 1'b0; init_done_0 = 1'b0;
    reset_n = 1'b1; #2; reset_n = 1'b0;
    repeat(1) @(posedge clk); reset_n = 1'b1;
    repeat(1) @(posedge pll_lock); repeat(1) @(posedge clk);
    init_done_0 = 1'b1;

    while (!saw_frame_end) @(posedge fb_clk);
    repeat(2) @(posedge fb_clk);
    $sformat(str, "Captured %0d store entries", cap_n);
    logger.info(module_name, str);

    idx = 0;
    if (cap[idx] !== 17'h10000) begin logger.error(module_name, "missing frame start"); `TEST_FAIL end
    idx = idx + 1;
    prev_R = -1;

    for (row = 0; row < LCD_FRAME_HEIGHT; row = row + 1) begin
        if (cap[idx] !== 17'h10001) begin
            $sformat(str, "row %0d: missing row start (got %05h)", row, cap[idx]);
            logger.error(module_name, str); `TEST_FAIL
        end
        idx = idx + 1;


        for (col = 0; col < LCD_FRAME_WIDTH; col = col + 1) begin
            logic [16:0] e; e = cap[idx];
            if (e[16] !== 1'b0) begin
                $sformat(str, "row %0d col %0d: token 0x%05h mid-row (short row?)", row, col, e);
                logger.error(module_name, str); `TEST_FAIL
            end
            if (col < LEFT_BORDER || col >= ACTIVE_END) begin
                if (e !== 17'h00000) begin
                    $sformat(str, "row %0d col %0d: border pixel = %05h, expected black", row, col, e);
                    logger.error(module_name, str); `TEST_FAIL
                end
            end else begin
                a = col - LEFT_BORDER;
                if (e !== kept[a]) begin
                    $sformat(str,
                        "row %0d active[%0d]: source column %0d, expected DDA-kept column %0d",
                        row, a, e, kept[a]);
                    logger.error(module_name, str); `TEST_FAIL
                end
            end
            idx = idx + 1;
        end
        prev_R = R;
    end

    if (cap[idx] !== 17'h1FFFF) begin
        $sformat(str, "missing frame end at %0d (got %05h)", idx, cap[idx]);
        logger.error(module_name, str); `TEST_FAIL
    end
    idx = idx + 1;
    if (idx !== cap_n) begin
        $sformat(str, "stream length mismatch: parsed %0d, captured %0d", idx, cap_n);
        logger.error(module_name, str); `TEST_FAIL
    end

    logger.info(module_name,
        "pillarbox borders correct: 58 black + 363 (1:1 centre crop) + 59 black per row");
    `TEST_PASS
end

always #15000000 begin
    logger.error(module_name, "System hangs"); `TEST_FAIL
end

endmodule
