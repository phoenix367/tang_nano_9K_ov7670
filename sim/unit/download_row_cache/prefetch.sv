`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for DownloadRowCache (ping-pong row prefetch cache).
//
// A behavioural PSRAM responder answers the cache's read bursts: on each rising
// edge of read_rq it grants (read_ack) after a small delay, latches read_addr,
// and streams BURST_CYCLES 32-bit words whose value encodes the *address* --
// word j = {addr+2j+1, addr+2j}. So the pixel stored at PSRAM pixel-address A
// has value A (mod 2^16); the drain side can therefore check that every pixel
// it reads carries the source address the cache was supposed to fetch.
//
// A drain consumer mirrors FrameDownloader's read protocol (present rd_pix_addr,
// sample rd_pix_data two cycles later), drains FRAME_WIDTH pixels per row, then
// pulses row_release. It deliberately runs slower than the cache can fetch and
// inserts random stalls, so both banks fill and the cache must stall its reads
// (both-banks-full back-pressure) and resume -- the path single-frame
// integration tests don't exercise. Several frames run back to back to cover
// the F_DONE -> re-`start` restart. A watchdog fails the test on any hang.
//
// ENABLE_RESIZE = 0: one source row per output row, stride ORIG_FRAME_WIDTH, so
// expected source address is deterministic. The fill FSM / row handshake /
// both-banks-full / restart logic exercised here is identical for ENABLE_RESIZE
// = 1 (resize only changes the per-row stride value); the pillarbox integration
// tests cover the resize stride end to end.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;

localparam integer MEMORY_BURST     = 32;
localparam integer PIX_PER_BURST    = MEMORY_BURST / 2;   // 16
localparam integer BURST_CYCLES     = 8;                  // burst_cycles(32)
localparam integer FRAME_WIDTH      = 32;                 // 2 bursts/row
localparam integer FRAME_HEIGHT     = 4;
localparam integer ORIG_FRAME_WIDTH = 48;                 // source row pitch
localparam integer NUM_FRAMES       = 3;

reg clk, reset_n;

// control
reg         start;
reg  [20:0] base_addr;
// PSRAM
wire        read_rq;
wire [20:0] read_addr;
reg         read_ack;
wire        mem_rd_en;
reg  [31:0] read_data;
reg         rd_data_valid;
// drain
wire        row_avail;
reg  [9:0]  rd_pix_addr;
wire [15:0] rd_pix_data;
reg         row_release;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

DownloadRowCache #(
    .MEMORY_BURST(MEMORY_BURST),
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT),
    .ORIG_FRAME_WIDTH(ORIG_FRAME_WIDTH),
    .ENABLE_RESIZE(0)
) dut (
    .clk(clk), .reset_n(reset_n),
    .start(start), .base_addr(base_addr),
    .read_rq(read_rq), .read_addr(read_addr), .read_ack(read_ack),
    .mem_rd_en(mem_rd_en), .read_data(read_data), .rd_data_valid(rd_data_valid),
    .row_avail(row_avail), .rd_pix_addr(rd_pix_addr), .rd_pix_data(rd_pix_data),
    .row_release(row_release)
);

always #5 clk = ~clk;

// ---------------------------------------------------------------------------
// Behavioural PSRAM read responder (one outstanding read at a time, which is
// all the cache ever issues). Rising-edge triggered so the cache holding
// read_rq high across the whole burst yields exactly one response.
// ---------------------------------------------------------------------------
localparam [1:0] RS_IDLE = 2'd0, RS_GAP = 2'd1, RS_SEND = 2'd2;
reg [1:0]  rs;
reg [20:0] cap_addr;
reg [3:0]  jcnt;
reg [2:0]  gap;
reg        read_rq_d;
reg [2:0]  grant_phase;   // deterministic pseudo-random grant delay

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
                    // latch this burst's address (held stable by the cache while
                    // read_rq is asserted) and grant after grant_phase cycles
                    cap_addr    <= #1 read_addr;
                    grant_phase <= #1 grant_phase + 1'b1;
                    gap         <= #1 (grant_phase[1:0]);   // 0..3 cycle grant delay
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
                if (jcnt == BURST_CYCLES - 1)
                    rs <= #1 RS_IDLE;
                else
                    jcnt <= #1 jcnt + 1'b1;
            end
        endcase
    end
end

// ---------------------------------------------------------------------------
// Drain consumer: read a pixel at address `a` (2-cycle BRAM latency), check it.
// ---------------------------------------------------------------------------
integer errors;

task automatic read_pixel(input integer a, output [15:0] d);
    begin
        @(negedge clk);
        rd_pix_addr = a[9:0];
        @(posedge clk);          // BRAM read register
        @(posedge clk);          // BRAM output register
        #1;
        d = rd_pix_data;
    end
endtask

initial begin
    integer f, r, c, src_base;
    logic [15:0] px;
    string str;

    errors      = 0;
    start       = 1'b0;
    base_addr   = 'd0;
    rd_pix_addr = 'd0;
    row_release = 1'b0;
    clk         = 1'b0;
    reset_n     = 1'b1;
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    $sformat(module_name, "%m");

    // reset
    #2 reset_n = 1'b0;
    repeat (3) @(posedge clk);
    reset_n = 1'b1;
    @(posedge clk);

    for (f = 0; f < NUM_FRAMES; f = f + 1) begin
        // each frame starts at a different base address
        @(negedge clk);
        base_addr = f * 21'd4096;
        start     = 1'b1;
        @(negedge clk);
        start     = 1'b0;

        $sformat(str, "Frame %0d: download from base %0h", f, base_addr);
        logger.info(module_name, str);

        for (r = 0; r < FRAME_HEIGHT; r = r + 1) begin
            // run slower than the cache: let both banks fill before draining,
            // so the both-banks-full stall path is exercised
            repeat (5 + (r * 7) % 13) @(posedge clk);

            // wait for the prefetched row to be available (watchdog catches hangs)
            while (!row_avail) @(posedge clk);

            src_base = base_addr + r * ORIG_FRAME_WIDTH;

            for (c = 0; c < FRAME_WIDTH; c = c + 1) begin
                read_pixel(c, px);
                if (px !== 16'((src_base + c))) begin
                    $sformat(str,
                        "Frame %0d row %0d col %0d: got %0h expected %0h",
                        f, r, c, px, 16'((src_base + c)));
                    logger.error(module_name, str);
                    errors = errors + 1;
                end
            end

            // release the drained bank
            @(negedge clk);
            row_release = 1'b1;
            @(negedge clk);
            row_release = 1'b0;
        end

        $sformat(str, "Frame %0d drained OK", f);
        logger.info(module_name, str);
    end

    if (errors == 0)
        `TEST_PASS
    else
        `TEST_FAIL
end



// ---------------------------------------------------------------------------
// Watchdog: any hang (cache never asserts row_avail, never returns data, ...)
// trips this before the consumer can finish.
// ---------------------------------------------------------------------------
initial begin
    #2000000;
    logger.error(module_name, "Watchdog timeout -- DownloadRowCache appears to hang");
    `TEST_FAIL
end

endmodule
