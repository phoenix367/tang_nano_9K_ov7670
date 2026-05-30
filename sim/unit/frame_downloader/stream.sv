`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for FrameDownloader (sequencer + drain over DownloadRowCache).
//
// A behavioural PSRAM responder answers the read bursts on FrameDownloader's
// external read ports; word j of a burst at address A is {A+2j+1, A+2j}, so the
// pixel at PSRAM pixel-address A carries the value A (mod 2^16).
//
// The store side applies pseudo-random `queue_full` back-pressure and captures
// every emitted beat (wr_en). The expected stream per frame is:
//   FRAME_START, { ROW_START, FRAME_WIDTH pixels } x FRAME_HEIGHT, FRAME_END
// with pixel(row,col) == base + row*ORIG_FRAME_WIDTH + col (ENABLE_RESIZE = 0).
//
// Several frames run back to back, gated on download_done, to exercise the
// S_DONE -> S_START_WAIT restart and the cache's F_DONE -> re-`start` reseed --
// the multi-frame path the single-frame integration tests never reach. A
// watchdog fails the test if FrameDownloader ever hangs (download_done never
// arrives / the stream stops short).

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;

localparam integer MEMORY_BURST     = 32;
localparam integer FRAME_WIDTH      = 32;
localparam integer FRAME_HEIGHT     = 4;
localparam integer ORIG_FRAME_WIDTH = 48;
localparam integer NUM_FRAMES       = 3;

localparam [16:0] TOKEN_FRAME_START = 17'h10000;
localparam [16:0] TOKEN_ROW_START   = 17'h10001;
localparam [16:0] TOKEN_FRAME_END   = 17'h1FFFF;

localparam integer BEATS_PER_FRAME = 1 + FRAME_HEIGHT * (1 + FRAME_WIDTH) + 1;
localparam integer TOTAL_BEATS     = NUM_FRAMES * BEATS_PER_FRAME;

reg clk, reset_n;

reg         start;
reg  [20:0] base_addr;
reg         queue_full;
// PSRAM
wire        read_rq;
wire [20:0] read_addr;
reg         read_ack;
wire        mem_rd_en;
reg  [31:0] read_data;
reg         rd_data_valid;
// store
wire [16:0] queue_data_o;
wire        wr_en;
wire        download_done;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

reg [20:0] frame_base [0:NUM_FRAMES-1];

FrameDownloader #(
    .MEMORY_BURST(MEMORY_BURST),
    .FRAME_WIDTH(FRAME_WIDTH),
    .EMIT_ROW_SIZE(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT),
    .ORIG_FRAME_WIDTH(ORIG_FRAME_WIDTH),
    .ORIG_FRAME_HEIGHT(480),
    .ENABLE_RESIZE(0)
`ifdef __ICARUS__
    , .LOG_LEVEL(LOG_LEVEL)
`endif
) dut (
    .clk(clk), .reset_n(reset_n),
    .start(start), .queue_full(queue_full),
    .read_ack(read_ack), .base_addr(base_addr),
    .read_data(read_data), .rd_data_valid(rd_data_valid),
    .queue_data_o(queue_data_o), .wr_en(wr_en),
    .read_rq(read_rq), .read_addr(read_addr), .mem_rd_en(mem_rd_en),
    .download_done(download_done)
);

always #5 clk = ~clk;

// ---------------------------------------------------------------------------
// Behavioural PSRAM read responder (rising-edge of read_rq -> one burst).
// ---------------------------------------------------------------------------
localparam [1:0] RS_IDLE = 2'd0, RS_GAP = 2'd1, RS_SEND = 2'd2;
reg [1:0]  rs;
reg [20:0] cap_addr;
reg [3:0]  jcnt;
reg [2:0]  gap;
reg        read_rq_d;
reg [2:0]  grant_phase;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        read_ack      <= #1 1'b0;
        rd_data_valid <= #1 1'b0;
        read_data     <= #1 'd0;
        rs            <= #1 RS_IDLE;
        read_rq_d     <= #1 1'b0;
        grant_phase   <= #1 'd0;
    end else begin
        read_ack      <= #1 1'b0;
        rd_data_valid <= #1 1'b0;
        read_rq_d     <= #1 read_rq;

        case (rs)
            RS_IDLE:
                if (read_rq && !read_rq_d) begin
                    cap_addr    <= #1 read_addr;
                    grant_phase <= #1 grant_phase + 1'b1;
                    gap         <= #1 grant_phase[1:0];
                    rs          <= #1 RS_GAP;
                end
            RS_GAP:
                if (gap == 0) begin
                    read_ack <= #1 1'b1;
                    jcnt     <= #1 'd0;
                    rs       <= #1 RS_SEND;
                end else
                    gap <= #1 gap - 1'b1;
            RS_SEND: begin
                rd_data_valid <= #1 1'b1;
                read_data     <= #1 {16'(cap_addr + 2*jcnt + 1), 16'(cap_addr + 2*jcnt)};
                if (jcnt == 8 - 1)
                    rs <= #1 RS_IDLE;
                else
                    jcnt <= #1 jcnt + 1'b1;
            end
        endcase
    end
end

// ---------------------------------------------------------------------------
// Pseudo-random store back-pressure.
// ---------------------------------------------------------------------------
always @(posedge clk or negedge reset_n)
    if (!reset_n) queue_full <= #1 1'b0;
    else          queue_full <= #1 $random;

// ---------------------------------------------------------------------------
// Capture every emitted beat (the downstream skid accepts each wr_en pulse).
// ---------------------------------------------------------------------------
reg [16:0] cap [0:TOTAL_BEATS + 16];
integer    ci;

always @(posedge clk or negedge reset_n)
    if (!reset_n)
        ci <= 0;
    else if (wr_en && ci <= TOTAL_BEATS + 16) begin
        cap[ci] <= queue_data_o;
        ci      <= ci + 1;
    end

// ---------------------------------------------------------------------------
// Stimulus: run NUM_FRAMES frames, each gated on download_done.
// ---------------------------------------------------------------------------
initial begin
    integer f;
    string str;

    start     = 1'b0;
    base_addr = 'd0;
    clk       = 1'b0;
    reset_n   = 1'b1;
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");

    #2 reset_n = 1'b0;
    repeat (3) @(posedge clk);
    reset_n = 1'b1;
    @(posedge clk);

    for (f = 0; f < NUM_FRAMES; f = f + 1) begin
        frame_base[f] = f * 21'd4096;

        @(negedge clk);
        base_addr = frame_base[f];
        start     = 1'b1;
        @(negedge clk);
        start     = 1'b0;

        $sformat(str, "Frame %0d started at base %0h", f, frame_base[f]);
        logger.info(module_name, str);

        @(posedge download_done);
        $sformat(str, "Frame %0d download_done", f);
        logger.info(module_name, str);
    end

    // let the last beats land, then check the captured stream
    repeat (20) @(posedge clk);
    check_stream();
end

task check_stream;
    integer i, f, k, row, pos, errors;
    logic [16:0] exp;
    string str;
    begin
        errors = 0;
        if (ci != TOTAL_BEATS) begin
            $sformat(str, "Beat count mismatch: captured %0d, expected %0d", ci, TOTAL_BEATS);
            logger.error(module_name, str);
            errors = errors + 1;
        end

        for (i = 0; i < ci && i < TOTAL_BEATS; i = i + 1) begin
            f = i / BEATS_PER_FRAME;
            k = i % BEATS_PER_FRAME;
            if (k == 0)
                exp = TOKEN_FRAME_START;
            else if (k == BEATS_PER_FRAME - 1)
                exp = TOKEN_FRAME_END;
            else begin
                row = (k - 1) / (1 + FRAME_WIDTH);
                pos = (k - 1) % (1 + FRAME_WIDTH);
                if (pos == 0)
                    exp = TOKEN_ROW_START;
                else
                    exp = {1'b0, 16'(frame_base[f] + row * ORIG_FRAME_WIDTH + (pos - 1))};
            end

            if (cap[i] !== exp) begin
                $sformat(str, "Beat %0d (frame %0d k %0d): got %0h expected %0h",
                         i, f, k, cap[i], exp);
                logger.error(module_name, str);
                errors = errors + 1;
                if (errors > 20) begin
                    logger.error(module_name, "Too many errors, aborting compare");
                    i = TOTAL_BEATS;
                end
            end
        end

        if (errors == 0)
            `TEST_PASS
        else
            `TEST_FAIL
    end
endtask

// ---------------------------------------------------------------------------
// Watchdog: catches a hang (download_done never arrives / stream stalls).
// ---------------------------------------------------------------------------
initial begin
    #3000000;
    logger.error(module_name, "Watchdog timeout -- FrameDownloader appears to hang");
    `TEST_FAIL
end

endmodule
