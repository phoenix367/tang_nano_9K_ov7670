`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam MAX_VAR_LEN = 16;
localparam NUM_ITEMS_BATCH = 16;

// Camera timing parameters
localparam CAM_PIXEL_CLK = 2;
localparam CAM_FRAME_WIDTH = 640;
localparam CAM_FRAME_HEIGHT = 480;
localparam LCD_FRAME_WIDTH = 480;
localparam LCD_FRAME_HEIGHT = 20;

localparam READ_BASE_ADDR = 0;

reg clk, reset_n;
reg fb_clk;
reg [16:0] cam_data_in;
reg cam_data_in_wr_en;

wire memory_clk;
wire cam_clk_o;
wire cam_wr_en;

wire queue_load_rd_en;
wire [16:0] cam_data_out;
wire cam_out_full;
wire cam_out_full_d;

assign #1 cam_out_full_d = cam_out_full;

reg init_done_0;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wire mem_cmd;
wire mem_cmd_en;
wire lcd_clock;
wire pll_lock;

wire [20:0] mem_addr;
wire [31:0] mem_w_data;
wire [16:0] queue_data_out;
wire [16:0] queue_data_out_d;
wire queue_empty_o;

assign #1 queue_data_out_d = queue_data_out;

reg [31:0] mem_r_data;
reg mem_r_data_valid;
reg queue_rd_en;

reg frame_end_signal;
reg [10:0] source_row_counter;
wire [1:0] row_inc_o;

logic[15:0] data_items[3 * CAM_FRAME_WIDTH * CAM_FRAME_HEIGHT + 3 * 32];

FIFO_cam q_cam_data_out(
    .Data(cam_data_out), //input [16:0] Data
    .WrReset(~reset_n), //input WrReset
    .RdReset(~reset_n), //input RdReset
    .WrClk(cam_clk_o), //input WrClk
    .RdClk(lcd_clock), //input RdClk
    .WrEn(cam_wr_en), //input WrEn
    .RdEn(queue_rd_en), //input RdEn
    .Q(queue_data_out), //output [16:0] Q
    .Empty(queue_empty_o), //output Empty
    .Full(cam_out_full) //output Full
);

initial begin
    integer i;
    logic error;
    string str;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    error = 1'b0;
    queue_rd_en = 1'b0;
    $sformat(module_name, "%m");

    $sformat(str, "Initial read address: %0h", READ_BASE_ADDR);
    logger.info(module_name, str);

    logger.info(module_name, " << Starting the Simulation >>");
    // initially values
    for (i = 0; i < $size(data_items); i = i + 1) begin
        data_items[i] = $urandom();
    end

    clk = 1'b0;

    cam_data_in_wr_en = 1'b0;
    init_done_0 = 1'b0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");

    repeat(1) @(posedge pll_lock);
    repeat(1) @(posedge clk);

    init_done_0 = 1'b1;

    if (error)
        `TEST_FAIL
    else begin
        string str;

        repeat(1) @(posedge frame_end_signal);
        logger.info(module_name, "Received frame download done signal");

        `TEST_PASS
    end
end

always #18.519 clk=~clk;

initial begin
    logic error;
    integer download_pixels;

    error = 1'b0;
    download_pixels = 0;

    mem_r_data = 'd0;
    mem_r_data_valid = 1'b0;
    frame_end_signal = 1'b0;

    repeat(1) @(posedge init_done_0);
    logger.info(module_name, "System initialized");

    while (download_pixels != LCD_FRAME_WIDTH * LCD_FRAME_HEIGHT && !error) begin
        repeat(1) @(posedge mem_cmd_en);
        if (mem_cmd == 1'b0) begin
            integer j, base_addr;
            string str;

            $sformat(str, "Mem read command received. Read base address %0h", mem_addr);
            logger.debug(module_name, str);

            base_addr = mem_addr;
            for (j = 0; j < 4; j = j + 1)
                repeat(1) @(posedge fb_clk);

            for (j = 0; j < 8; j = j + 1) begin
                repeat(1) @(posedge fb_clk);
                mem_r_data_valid = #1 1'b1;
                mem_r_data = {data_items[base_addr + 2 * j + 1], data_items[base_addr + 2 * j]};
            end

            repeat(1) @(posedge fb_clk);
            mem_r_data_valid = #1 1'b0;
        end
    end

    if (error)
        `TEST_FAIL
end

SDRAM_rPLL sdram_clock(.reset(~reset_n), .clkin(clk), .clkout(memory_clk), .lock(pll_lock),
                       .clkoutd(lcd_clock));

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
                      .clk(fb_clk),
                      .rst_n(reset_n), 
                      .init_done(init_done_0),
                      .cmd(mem_cmd),
                      .cmd_en(mem_cmd_en),
                      .addr(mem_addr),
                      .wr_data(mem_w_data),
                      .rd_data(mem_r_data),
                      .rd_data_valid(mem_r_data_valid),
                      .error(),
                      .data_mask(),

                      .load_clk_o(),
                      .load_read_rdy(),
                      .load_command_valid(1'b0),
                      .load_pixel_data('d0),
                      .load_mem_addr(),
                      .load_command_data(2'd0),

                      .store_clk_o(cam_clk_o),
                      .store_wr_en(cam_wr_en),
                      .store_queue_full(cam_out_full_d),
                      .store_queue_data(cam_data_out)
                  );

always @(posedge memory_clk or negedge reset_n) begin
    if (!reset_n)
        fb_clk <= #1 1'b0;
    else if (pll_lock)
        fb_clk <= #1 ~fb_clk;
end

reg [10:0] row_index;

PositionScaler_vert position_scaler_vert(
    .source_position(row_index), 
    .position_increment(row_inc_o)
);

reg [10:0] column_index;
reg [10:0] source_column_counter;
wire [1:0] col_inc_o;

function logic[1:0] get_position_increment(input logic [10:0] source_position);
    get_position_increment = 'd0;

    case (source_position)
        0: get_position_increment = 'd1;
        1: get_position_increment = 'd2;
        2: get_position_increment = 'd1;
        3: get_position_increment = 'd1;
        4: get_position_increment = 'd2;
        5: get_position_increment = 'd1;
        6: get_position_increment = 'd1;
        7: get_position_increment = 'd2;
        8: get_position_increment = 'd1;
        9: get_position_increment = 'd1;
        10: get_position_increment = 'd2;
        11: get_position_increment = 'd1;
        12: get_position_increment = 'd1;
        13: get_position_increment = 'd2;
        14: get_position_increment = 'd1;
        15: get_position_increment = 'd1;
        16: get_position_increment = 'd2;
        17: get_position_increment = 'd1;
        18: get_position_increment = 'd1;
        19: get_position_increment = 'd2;
        20: get_position_increment = 'd1;
        21: get_position_increment = 'd1;
        22: get_position_increment = 'd2;
        23: get_position_increment = 'd1;
        24: get_position_increment = 'd1;
        25: get_position_increment = 'd2;
        26: get_position_increment = 'd1;
        27: get_position_increment = 'd1;
        28: get_position_increment = 'd2;
        29: get_position_increment = 'd1;
        30: get_position_increment = 'd1;
        31: get_position_increment = 'd2;
        32: get_position_increment = 'd1;
        33: get_position_increment = 'd1;
        34: get_position_increment = 'd2;
        35: get_position_increment = 'd1;
        36: get_position_increment = 'd1;
        37: get_position_increment = 'd2;
        38: get_position_increment = 'd1;
        39: get_position_increment = 'd1;
        40: get_position_increment = 'd2;
        41: get_position_increment = 'd1;
        42: get_position_increment = 'd1;
        43: get_position_increment = 'd2;
        44: get_position_increment = 'd1;
        45: get_position_increment = 'd1;
        46: get_position_increment = 'd2;
        47: get_position_increment = 'd1;
        48: get_position_increment = 'd1;
        49: get_position_increment = 'd2;
        50: get_position_increment = 'd1;
        51: get_position_increment = 'd1;
        52: get_position_increment = 'd2;
        53: get_position_increment = 'd1;
        54: get_position_increment = 'd1;
        55: get_position_increment = 'd2;
        56: get_position_increment = 'd1;
        57: get_position_increment = 'd1;
        58: get_position_increment = 'd2;
        59: get_position_increment = 'd1;
        60: get_position_increment = 'd1;
        61: get_position_increment = 'd2;
        62: get_position_increment = 'd1;
        63: get_position_increment = 'd1;
        64: get_position_increment = 'd2;
        65: get_position_increment = 'd1;
        66: get_position_increment = 'd1;
        67: get_position_increment = 'd2;
        68: get_position_increment = 'd1;
        69: get_position_increment = 'd1;
        70: get_position_increment = 'd2;
        71: get_position_increment = 'd1;
        72: get_position_increment = 'd1;
        73: get_position_increment = 'd2;
        74: get_position_increment = 'd1;
        75: get_position_increment = 'd1;
        76: get_position_increment = 'd2;
        77: get_position_increment = 'd1;
        78: get_position_increment = 'd1;
        79: get_position_increment = 'd2;
        80: get_position_increment = 'd1;
        81: get_position_increment = 'd1;
        82: get_position_increment = 'd2;
        83: get_position_increment = 'd1;
        84: get_position_increment = 'd1;
        85: get_position_increment = 'd2;
        86: get_position_increment = 'd1;
        87: get_position_increment = 'd1;
        88: get_position_increment = 'd2;
        89: get_position_increment = 'd1;
        90: get_position_increment = 'd1;
        91: get_position_increment = 'd2;
        92: get_position_increment = 'd1;
        93: get_position_increment = 'd1;
        94: get_position_increment = 'd2;
        95: get_position_increment = 'd1;
        96: get_position_increment = 'd1;
        97: get_position_increment = 'd2;
        98: get_position_increment = 'd1;
        99: get_position_increment = 'd1;
        100: get_position_increment = 'd2;
        101: get_position_increment = 'd1;
        102: get_position_increment = 'd1;
        103: get_position_increment = 'd2;
        104: get_position_increment = 'd1;
        105: get_position_increment = 'd1;
        106: get_position_increment = 'd2;
        107: get_position_increment = 'd1;
        108: get_position_increment = 'd1;
        109: get_position_increment = 'd2;
        110: get_position_increment = 'd1;
        111: get_position_increment = 'd1;
        112: get_position_increment = 'd2;
        113: get_position_increment = 'd1;
        114: get_position_increment = 'd1;
        115: get_position_increment = 'd2;
        116: get_position_increment = 'd1;
        117: get_position_increment = 'd1;
        118: get_position_increment = 'd2;
        119: get_position_increment = 'd1;
        120: get_position_increment = 'd1;
        121: get_position_increment = 'd2;
        122: get_position_increment = 'd1;
        123: get_position_increment = 'd1;
        124: get_position_increment = 'd2;
        125: get_position_increment = 'd1;
        126: get_position_increment = 'd1;
        127: get_position_increment = 'd2;
        128: get_position_increment = 'd1;
        129: get_position_increment = 'd1;
        130: get_position_increment = 'd2;
        131: get_position_increment = 'd1;
        132: get_position_increment = 'd1;
        133: get_position_increment = 'd2;
        134: get_position_increment = 'd1;
        135: get_position_increment = 'd1;
        136: get_position_increment = 'd2;
        137: get_position_increment = 'd1;
        138: get_position_increment = 'd1;
        139: get_position_increment = 'd2;
        140: get_position_increment = 'd1;
        141: get_position_increment = 'd1;
        142: get_position_increment = 'd2;
        143: get_position_increment = 'd1;
        144: get_position_increment = 'd1;
        145: get_position_increment = 'd2;
        146: get_position_increment = 'd1;
        147: get_position_increment = 'd1;
        148: get_position_increment = 'd2;
        149: get_position_increment = 'd1;
        150: get_position_increment = 'd1;
        151: get_position_increment = 'd2;
        152: get_position_increment = 'd1;
        153: get_position_increment = 'd1;
        154: get_position_increment = 'd2;
        155: get_position_increment = 'd1;
        156: get_position_increment = 'd1;
        157: get_position_increment = 'd2;
        158: get_position_increment = 'd1;
        159: get_position_increment = 'd1;
        160: get_position_increment = 'd2;
        161: get_position_increment = 'd1;
        162: get_position_increment = 'd1;
        163: get_position_increment = 'd2;
        164: get_position_increment = 'd1;
        165: get_position_increment = 'd1;
        166: get_position_increment = 'd2;
        167: get_position_increment = 'd1;
        168: get_position_increment = 'd1;
        169: get_position_increment = 'd2;
        170: get_position_increment = 'd1;
        171: get_position_increment = 'd1;
        172: get_position_increment = 'd2;
        173: get_position_increment = 'd1;
        174: get_position_increment = 'd1;
        175: get_position_increment = 'd2;
        176: get_position_increment = 'd1;
        177: get_position_increment = 'd1;
        178: get_position_increment = 'd2;
        179: get_position_increment = 'd1;
        180: get_position_increment = 'd1;
        181: get_position_increment = 'd2;
        182: get_position_increment = 'd1;
        183: get_position_increment = 'd1;
        184: get_position_increment = 'd2;
        185: get_position_increment = 'd1;
        186: get_position_increment = 'd1;
        187: get_position_increment = 'd2;
        188: get_position_increment = 'd1;
        189: get_position_increment = 'd1;
        190: get_position_increment = 'd2;
        191: get_position_increment = 'd1;
        192: get_position_increment = 'd1;
        193: get_position_increment = 'd2;
        194: get_position_increment = 'd1;
        195: get_position_increment = 'd1;
        196: get_position_increment = 'd2;
        197: get_position_increment = 'd1;
        198: get_position_increment = 'd1;
        199: get_position_increment = 'd2;
        200: get_position_increment = 'd1;
        201: get_position_increment = 'd1;
        202: get_position_increment = 'd2;
        203: get_position_increment = 'd1;
        204: get_position_increment = 'd1;
        205: get_position_increment = 'd2;
        206: get_position_increment = 'd1;
        207: get_position_increment = 'd1;
        208: get_position_increment = 'd2;
        209: get_position_increment = 'd1;
        210: get_position_increment = 'd1;
        211: get_position_increment = 'd2;
        212: get_position_increment = 'd1;
        213: get_position_increment = 'd1;
        214: get_position_increment = 'd2;
        215: get_position_increment = 'd1;
        216: get_position_increment = 'd1;
        217: get_position_increment = 'd2;
        218: get_position_increment = 'd1;
        219: get_position_increment = 'd1;
        220: get_position_increment = 'd2;
        221: get_position_increment = 'd1;
        222: get_position_increment = 'd1;
        223: get_position_increment = 'd2;
        224: get_position_increment = 'd1;
        225: get_position_increment = 'd1;
        226: get_position_increment = 'd2;
        227: get_position_increment = 'd1;
        228: get_position_increment = 'd1;
        229: get_position_increment = 'd2;
        230: get_position_increment = 'd1;
        231: get_position_increment = 'd1;
        232: get_position_increment = 'd2;
        233: get_position_increment = 'd1;
        234: get_position_increment = 'd1;
        235: get_position_increment = 'd2;
        236: get_position_increment = 'd1;
        237: get_position_increment = 'd1;
        238: get_position_increment = 'd2;
        239: get_position_increment = 'd1;
        240: get_position_increment = 'd1;
        241: get_position_increment = 'd2;
        242: get_position_increment = 'd1;
        243: get_position_increment = 'd1;
        244: get_position_increment = 'd2;
        245: get_position_increment = 'd1;
        246: get_position_increment = 'd1;
        247: get_position_increment = 'd2;
        248: get_position_increment = 'd1;
        249: get_position_increment = 'd1;
        250: get_position_increment = 'd2;
        251: get_position_increment = 'd1;
        252: get_position_increment = 'd1;
        253: get_position_increment = 'd2;
        254: get_position_increment = 'd1;
        255: get_position_increment = 'd1;
        256: get_position_increment = 'd2;
        257: get_position_increment = 'd1;
        258: get_position_increment = 'd1;
        259: get_position_increment = 'd2;
        260: get_position_increment = 'd1;
        261: get_position_increment = 'd1;
        262: get_position_increment = 'd2;
        263: get_position_increment = 'd1;
        264: get_position_increment = 'd1;
        265: get_position_increment = 'd2;
        266: get_position_increment = 'd1;
        267: get_position_increment = 'd1;
        268: get_position_increment = 'd2;
        269: get_position_increment = 'd1;
        270: get_position_increment = 'd1;
        271: get_position_increment = 'd2;
        272: get_position_increment = 'd1;
        273: get_position_increment = 'd1;
        274: get_position_increment = 'd2;
        275: get_position_increment = 'd1;
        276: get_position_increment = 'd1;
        277: get_position_increment = 'd2;
        278: get_position_increment = 'd1;
        279: get_position_increment = 'd1;
        280: get_position_increment = 'd2;
        281: get_position_increment = 'd1;
        282: get_position_increment = 'd1;
        283: get_position_increment = 'd2;
        284: get_position_increment = 'd1;
        285: get_position_increment = 'd1;
        286: get_position_increment = 'd2;
        287: get_position_increment = 'd1;
        288: get_position_increment = 'd1;
        289: get_position_increment = 'd2;
        290: get_position_increment = 'd1;
        291: get_position_increment = 'd1;
        292: get_position_increment = 'd2;
        293: get_position_increment = 'd1;
        294: get_position_increment = 'd1;
        295: get_position_increment = 'd2;
        296: get_position_increment = 'd1;
        297: get_position_increment = 'd1;
        298: get_position_increment = 'd2;
        299: get_position_increment = 'd1;
        300: get_position_increment = 'd1;
        301: get_position_increment = 'd2;
        302: get_position_increment = 'd1;
        303: get_position_increment = 'd1;
        304: get_position_increment = 'd2;
        305: get_position_increment = 'd1;
        306: get_position_increment = 'd1;
        307: get_position_increment = 'd2;
        308: get_position_increment = 'd1;
        309: get_position_increment = 'd1;
        310: get_position_increment = 'd2;
        311: get_position_increment = 'd1;
        312: get_position_increment = 'd1;
        313: get_position_increment = 'd2;
        314: get_position_increment = 'd1;
        315: get_position_increment = 'd1;
        316: get_position_increment = 'd2;
        317: get_position_increment = 'd1;
        318: get_position_increment = 'd1;
        319: get_position_increment = 'd2;
        320: get_position_increment = 'd1;
        321: get_position_increment = 'd1;
        322: get_position_increment = 'd2;
        323: get_position_increment = 'd1;
        324: get_position_increment = 'd1;
        325: get_position_increment = 'd2;
        326: get_position_increment = 'd1;
        327: get_position_increment = 'd1;
        328: get_position_increment = 'd2;
        329: get_position_increment = 'd1;
        330: get_position_increment = 'd1;
        331: get_position_increment = 'd2;
        332: get_position_increment = 'd1;
        333: get_position_increment = 'd1;
        334: get_position_increment = 'd2;
        335: get_position_increment = 'd1;
        336: get_position_increment = 'd1;
        337: get_position_increment = 'd2;
        338: get_position_increment = 'd1;
        339: get_position_increment = 'd1;
        340: get_position_increment = 'd2;
        341: get_position_increment = 'd1;
        342: get_position_increment = 'd1;
        343: get_position_increment = 'd2;
        344: get_position_increment = 'd1;
        345: get_position_increment = 'd1;
        346: get_position_increment = 'd2;
        347: get_position_increment = 'd1;
        348: get_position_increment = 'd1;
        349: get_position_increment = 'd2;
        350: get_position_increment = 'd1;
        351: get_position_increment = 'd1;
        352: get_position_increment = 'd2;
        353: get_position_increment = 'd1;
        354: get_position_increment = 'd1;
        355: get_position_increment = 'd2;
        356: get_position_increment = 'd1;
        357: get_position_increment = 'd1;
        358: get_position_increment = 'd2;
        359: get_position_increment = 'd1;
        360: get_position_increment = 'd1;
        361: get_position_increment = 'd2;
        362: get_position_increment = 'd1;
        363: get_position_increment = 'd1;
        364: get_position_increment = 'd2;
        365: get_position_increment = 'd1;
        366: get_position_increment = 'd1;
        367: get_position_increment = 'd2;
        368: get_position_increment = 'd1;
        369: get_position_increment = 'd1;
        370: get_position_increment = 'd2;
        371: get_position_increment = 'd1;
        372: get_position_increment = 'd1;
        373: get_position_increment = 'd2;
        374: get_position_increment = 'd1;
        375: get_position_increment = 'd1;
        376: get_position_increment = 'd2;
        377: get_position_increment = 'd1;
        378: get_position_increment = 'd1;
        379: get_position_increment = 'd2;
        380: get_position_increment = 'd1;
        381: get_position_increment = 'd1;
        382: get_position_increment = 'd2;
        383: get_position_increment = 'd1;
        384: get_position_increment = 'd1;
        385: get_position_increment = 'd2;
        386: get_position_increment = 'd1;
        387: get_position_increment = 'd1;
        388: get_position_increment = 'd2;
        389: get_position_increment = 'd1;
        390: get_position_increment = 'd1;
        391: get_position_increment = 'd2;
        392: get_position_increment = 'd1;
        393: get_position_increment = 'd1;
        394: get_position_increment = 'd2;
        395: get_position_increment = 'd1;
        396: get_position_increment = 'd1;
        397: get_position_increment = 'd2;
        398: get_position_increment = 'd1;
        399: get_position_increment = 'd1;
        400: get_position_increment = 'd2;
        401: get_position_increment = 'd1;
        402: get_position_increment = 'd1;
        403: get_position_increment = 'd2;
        404: get_position_increment = 'd1;
        405: get_position_increment = 'd1;
        406: get_position_increment = 'd2;
        407: get_position_increment = 'd1;
        408: get_position_increment = 'd1;
        409: get_position_increment = 'd2;
        410: get_position_increment = 'd1;
        411: get_position_increment = 'd1;
        412: get_position_increment = 'd2;
        413: get_position_increment = 'd1;
        414: get_position_increment = 'd1;
        415: get_position_increment = 'd2;
        416: get_position_increment = 'd1;
        417: get_position_increment = 'd1;
        418: get_position_increment = 'd2;
        419: get_position_increment = 'd1;
        420: get_position_increment = 'd1;
        421: get_position_increment = 'd2;
        422: get_position_increment = 'd1;
        423: get_position_increment = 'd1;
        424: get_position_increment = 'd2;
        425: get_position_increment = 'd1;
        426: get_position_increment = 'd1;
        427: get_position_increment = 'd2;
        428: get_position_increment = 'd1;
        429: get_position_increment = 'd1;
        430: get_position_increment = 'd2;
        431: get_position_increment = 'd1;
        432: get_position_increment = 'd1;
        433: get_position_increment = 'd2;
        434: get_position_increment = 'd1;
        435: get_position_increment = 'd1;
        436: get_position_increment = 'd2;
        437: get_position_increment = 'd1;
        438: get_position_increment = 'd1;
        439: get_position_increment = 'd2;
        440: get_position_increment = 'd1;
        441: get_position_increment = 'd1;
        442: get_position_increment = 'd2;
        443: get_position_increment = 'd1;
        444: get_position_increment = 'd1;
        445: get_position_increment = 'd2;
        446: get_position_increment = 'd1;
        447: get_position_increment = 'd1;
        448: get_position_increment = 'd2;
        449: get_position_increment = 'd1;
        450: get_position_increment = 'd1;
        451: get_position_increment = 'd2;
        452: get_position_increment = 'd1;
        453: get_position_increment = 'd1;
        454: get_position_increment = 'd2;
        455: get_position_increment = 'd1;
        456: get_position_increment = 'd1;
        457: get_position_increment = 'd2;
        458: get_position_increment = 'd1;
        459: get_position_increment = 'd1;
        460: get_position_increment = 'd2;
        461: get_position_increment = 'd1;
        462: get_position_increment = 'd1;
        463: get_position_increment = 'd2;
        464: get_position_increment = 'd1;
        465: get_position_increment = 'd1;
        466: get_position_increment = 'd2;
        467: get_position_increment = 'd1;
        468: get_position_increment = 'd1;
        469: get_position_increment = 'd2;
        470: get_position_increment = 'd1;
        471: get_position_increment = 'd1;
        472: get_position_increment = 'd2;
        473: get_position_increment = 'd1;
        474: get_position_increment = 'd1;
        475: get_position_increment = 'd2;
        476: get_position_increment = 'd1;
        477: get_position_increment = 'd1;
        478: get_position_increment = 'd2;
        479: get_position_increment = 'd1;
    endcase
endfunction


initial begin
    integer col_counter, row_counter, i;
    integer cycles_to_wait, base_address;
    string str;

    col_counter = 0;
    row_counter = 0;
    base_address = 0;
    source_row_counter = 'd0;
    row_index = 'd0;
    column_index = 'd0;

    $sformat(str, "Downloaded frame base address %0h", base_address);
    logger.info(module_name, str);

    repeat(1) @(posedge cam_out_full);
    cycles_to_wait = ($urandom() % 10) + 1;

    for (i = 0; i != cycles_to_wait; i = i + 1)
        repeat(1) @(posedge lcd_clock);

    queue_rd_en = #1 1'b1;
    while (queue_data_out_d !== 17'h10000)
        repeat(1) @(posedge lcd_clock);
        /*
    if (queue_data_out_d !== 17'h10000) begin
        logger.error(module_name, "Frame start sequence not found");

        `TEST_FAIL
    end else*/
        logger.info(module_name, "Frame start sequence received");

    for (row_index = 0; row_index < LCD_FRAME_HEIGHT; row_index = row_index + 1) begin
        integer j;

        repeat(1) @(posedge lcd_clock);

        if (queue_data_out_d !== 17'h10001) begin
            logger.error(module_name, "Row start sequence not found");

            `TEST_FAIL
        end

        queue_rd_en = 1'b0;
        for (j = 0; j < LCD_FRAME_WIDTH; j = j + 1)
            repeat(1) @(posedge lcd_clock);
        queue_rd_en = 1'b1;
        source_column_counter = 'd0;

        for (column_index = 0; column_index < LCD_FRAME_WIDTH; column_index = column_index + 1) begin
            logic [16:0] pixel_value;
            integer read_address;

            repeat(1) @(posedge lcd_clock);

            read_address = base_address + source_row_counter * CAM_FRAME_WIDTH + source_column_counter;
            pixel_value = data_items[read_address];
            if (pixel_value !== {1'b0, queue_data_out_d}) begin
                string str;

                $sformat(str, "Invalid pixel value. Got %0h, expected %0h (row %0d, column %0d, addr %0h)", 
                    queue_data_out_d, pixel_value, source_row_counter, source_column_counter, read_address);
                logger.error(module_name, str);
                `TEST_FAIL
            end

            source_column_counter = source_column_counter + get_position_increment(column_index);
        end

        $display("%0d => %0d", row_index, source_row_counter);
        source_row_counter = source_row_counter + row_inc_o;
    end

    repeat(1) @(posedge lcd_clock);

    if (queue_data_out_d != 17'h1FFFF) begin
        logger.error(module_name, "Frame stop sequence not found");

        `TEST_FAIL
    end else begin
        logger.info(module_name, "Frame end");
        frame_end_signal = 1'b1;
    end
end

initial begin
    repeat(1) @(posedge lcd_clock);

    #1;
    repeat(1) @(posedge queue_empty_o);
    if (!frame_end_signal) begin
        logger.error(module_name, "Output queue emitted unexpected empty signal");

        `TEST_FAIL
    end
end

always #9000000 begin
    logger.error(module_name, "System hangs");

    `TEST_FAIL
end

endmodule
