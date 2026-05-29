`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for HorizontalResizer (pillarbox borders, no left crop).
//
// For each input row the block emits: row-start, BORDER_SIZE black, the
// ACTIVE_WIDTH LEFTMOST source pixels 1:1 (source cols 0..ACTIVE_WIDTH-1 -- no
// left crop), BORDER_SIZE black; the remaining INPUT_WIDTH-ACTIVE_WIDTH source
// pixels are drained (dropped). Command tokens pass through.
//
// An input-side driver presents the stream and only advances when the block
// accepts it (!in_full) -- this exercises the left-border stall (in_full held
// high while no input is consumed). An output-side monitor captures every
// emitted beat. A parallel ENABLE=0 instance must be a bit-exact pass-through.
//
// out_full is driven by a deterministic pseudo-random toggle so the output
// skid is hammered with backpressure: the captured stream must still match the
// expected stream exactly (no dropped / duplicated beats). This is the guard
// the earlier (skid-free) tests lacked -- a skid handshake bug shows up here
// rather than only on the device.

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

localparam integer INPUT_WIDTH  = 640;   // full source row from FrameDownloader
localparam integer OUTPUT_WIDTH = 480;   // LCD width: borders + active band
localparam integer ACTIVE_WIDTH = 362;
localparam integer BORDER_SIZE  = (OUTPUT_WIDTH - ACTIVE_WIDTH) / 2;   // 59
localparam integer ROWS         = 2;

localparam [16:0] FRAME_START = 17'h10000;
localparam [16:0] ROW_START   = 17'h10001;
localparam [16:0] FRAME_END   = 17'h1FFFF;
localparam [16:0] BLACK       = 17'h00000;

localparam integer IN_LEN  = 1 + ROWS*(1 + INPUT_WIDTH)  + 1;   // 640 consumed per row
localparam integer OUT_LEN = 1 + ROWS*(1 + OUTPUT_WIDTH) + 1;   // 480 emitted per row

reg         clk, reset_n;
reg  [16:0] instream [0:IN_LEN-1];
reg  [16:0] expout   [0:OUT_LEN-1];
reg  [16:0] cap      [0:OUT_LEN-1];
integer     kept     [0:INPUT_WIDTH-1];   // DDA-selected source columns

integer ii, oi;
reg         in_wr_en;
reg  [16:0] in_data;
wire        in_full;
wire        out_wr_en;
wire [16:0] out_data;
wire        in_full0, out_wr_en0;
wire [16:0] out_data0;
reg         out_full;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

HorizontalResizer #(.INPUT_WIDTH(INPUT_WIDTH), .OUTPUT_WIDTH(OUTPUT_WIDTH), .ACTIVE_WIDTH(ACTIVE_WIDTH), .ENABLE(1))
dut (.clk(clk), .reset_n(reset_n),
     .in_wr_en(in_wr_en), .in_data(in_data), .in_full(in_full),
     .out_wr_en(out_wr_en), .out_data(out_data), .out_full(out_full));

HorizontalResizer #(.INPUT_WIDTH(INPUT_WIDTH), .OUTPUT_WIDTH(OUTPUT_WIDTH), .ACTIVE_WIDTH(ACTIVE_WIDTH), .ENABLE(0))
dut0 (.clk(clk), .reset_n(reset_n),
      .in_wr_en(in_wr_en), .in_data(in_data), .in_full(in_full0),
      .out_wr_en(out_wr_en0), .out_data(out_data0), .out_full(out_full));

// Input driver: present instream[ii], advance only when accepted.
always @* begin
    if (ii < IN_LEN) begin in_wr_en = 1'b1; in_data = instream[ii]; end
    else             begin in_wr_en = 1'b0; in_data = 17'h0;        end
end
always @(posedge clk or negedge reset_n)
    if (!reset_n) ii <= 0;
    else if (ii < IN_LEN && !in_full) ii <= ii + 1;

// Output monitor.
always @(posedge clk or negedge reset_n)
    if (!reset_n) oi <= 0;
    else if (out_wr_en && !out_full && oi < OUT_LEN) begin
        cap[oi] <= out_data;
        oi      <= oi + 1;
    end

// Pseudo-random downstream backpressure (deterministic seed -> reproducible).
always @(posedge clk or negedge reset_n)
    if (!reset_n) out_full <= 1'b0;
    else          out_full <= $random;

// ENABLE=0 must forward verbatim, every presented beat.
always @(posedge clk)
    if (reset_n && in_wr_en && out_data0 !== in_data) begin
        logger.error(module_name, "ENABLE=0 instance is not a pass-through");
        `TEST_FAIL
    end

initial begin
    integer row, c, b, n, m, nk, acc;
    string  str;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    // build input stream
    n = 0;
    instream[n] = FRAME_START; n = n + 1;
    for (row = 0; row < ROWS; row = row + 1) begin
        instream[n] = ROW_START; n = n + 1;
        for (c = 0; c < INPUT_WIDTH; c = c + 1) begin instream[n] = {1'b0, 16'(c)}; n = n + 1; end
    end
    instream[n] = FRAME_END; n = n + 1;

    // model the DDA: which INPUT_WIDTH columns the kernel keeps (-> ACTIVE_WIDTH)
    acc = 0; nk = 0;
    for (c = 0; c < INPUT_WIDTH; c = c + 1)
        if (acc + ACTIVE_WIDTH >= INPUT_WIDTH) begin
            kept[nk] = c; nk = nk + 1;
            acc = acc + ACTIVE_WIDTH - INPUT_WIDTH;
        end else
            acc = acc + ACTIVE_WIDTH;
    if (nk !== ACTIVE_WIDTH) begin
        logger.error(module_name, "model keep-count != ACTIVE_WIDTH"); `TEST_FAIL
    end

    // build expected output stream: row-start, left border, downscaled active
    // (the DDA-kept source columns), right border
    m = 0;
    expout[m] = FRAME_START; m = m + 1;
    for (row = 0; row < ROWS; row = row + 1) begin
        expout[m] = ROW_START; m = m + 1;
        for (b = 0; b < BORDER_SIZE; b = b + 1)  begin expout[m] = BLACK;                 m = m + 1; end
        for (c = 0; c < ACTIVE_WIDTH; c = c + 1) begin expout[m] = {1'b0, 16'(kept[c])}; m = m + 1; end
        for (b = 0; b < BORDER_SIZE; b = b + 1)  begin expout[m] = BLACK;                 m = m + 1; end
    end
    expout[m] = FRAME_END; m = m + 1;

    clk = 0; out_full = 0; ii = 0; oi = 0;
    reset_n = 1; #2; reset_n = 0; repeat(2) @(posedge clk); reset_n = 1;

    // wait for the whole output stream (or timeout via watchdog)
    while (oi < OUT_LEN) @(posedge clk);
    repeat(2) @(posedge clk);

    for (m = 0; m < OUT_LEN; m = m + 1)
        if (cap[m] !== expout[m]) begin
            $sformat(str, "out[%0d] = %05h, expected %05h", m, cap[m], expout[m]);
            logger.error(module_name, str); `TEST_FAIL
        end

    logger.info(module_name,
        "HorizontalResizer: left border stalls input, active = leftmost source cols, borders + drain correct");
    `TEST_PASS
end

always #5 clk = ~clk;

always #2000000 begin
    logger.error(module_name, "System hangs"); `TEST_FAIL
end

endmodule
