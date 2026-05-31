`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for the 8-E-1 UART (8 data, even parity, 1 stop).
//
// Happy path: loopback (rx tied to tx) -- transmit bytes and check the receiver
// recovers them with no parity/frame error (exercises TX framing + parity and
// RX sampling + parity together). Error paths: bit-bang the rx line directly
// with a deliberately wrong parity bit (-> rx_parity_error) and a bad stop bit
// (-> rx_frame_error), confirming the byte is still delivered with the right
// flag. Uses a tiny CLKS_PER_BIT (CLK_FREQ/BAUD = 16) for fast simulation.
//
// rx_valid is a one-cycle strobe, so a byte-count latch captures each received
// byte; the checks compare the latched value (robust to when the strobe fires
// relative to the bit-bang driver, which blocks for a whole frame).

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;
localparam integer CLK_FREQ = 160;
localparam integer BAUD     = 10;
localparam integer CPB      = CLK_FREQ / BAUD;   // 16 clocks per bit

reg        clk, reset_n;
reg  [7:0] tx_data;
reg        tx_start;
wire       tx_busy;
wire       tx;

reg        loopback;
reg        rx_drive;
wire       rx_line = loopback ? tx : rx_drive;   // serial bus to the receiver

wire [7:0] rx_data;
wire       rx_valid, rx_parity_error, rx_frame_error;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

uart #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) dut(
    .clk(clk), .reset_n(reset_n),
    .tx_data(tx_data), .tx_start(tx_start), .tx_busy(tx_busy), .tx(tx),
    .rx(rx_line), .rx_data(rx_data), .rx_valid(rx_valid),
    .rx_parity_error(rx_parity_error), .rx_frame_error(rx_frame_error)
);

always #5 clk = ~clk;

// Latch each received byte (rx_valid is a one-cycle strobe).
integer    rx_count;
reg [7:0]  got_data;
reg        got_pe, got_fe;
always @(posedge clk or negedge reset_n)
    if (!reset_n)
        rx_count <= 0;
    else if (rx_valid) begin
        rx_count <= rx_count + 1;
        got_data <= rx_data;
        got_pe   <= rx_parity_error;
        got_fe   <= rx_frame_error;
    end

integer errors;
string  str;

task automatic tx_byte(input [7:0] d);
    begin
        @(posedge clk); #2;
        while (tx_busy) begin @(posedge clk); #2; end
        @(negedge clk); tx_data = d; tx_start = 1'b1;
        @(negedge clk); tx_start = 1'b0;
    end
endtask

// Bit-bang one frame onto the rx line: start, 8 data (LSB first), parity, stop.
task automatic rx_send(input [7:0] d, input par, input stop);
    integer i;
    begin
        rx_drive = 1'b0;                 repeat (CPB) @(posedge clk);   // start
        for (i = 0; i < 8; i = i + 1) begin
            rx_drive = d[i];             repeat (CPB) @(posedge clk);   // data LSB-first
        end
        rx_drive = par;                  repeat (CPB) @(posedge clk);   // parity
        rx_drive = stop;                 repeat (CPB) @(posedge clk);   // stop
        rx_drive = 1'b1;                                                 // idle
    end
endtask

// Wait until one more byte than `prev` has been received.
task automatic wait_byte(input integer prev);
    begin
        @(posedge clk); #2;
        while (rx_count == prev) begin @(posedge clk); #2; end
    end
endtask

integer i, prev;
logic [7:0] vec [0:3];

initial begin
    errors   = 0;
    tx_data  = 8'h00;
    tx_start = 1'b0;
    loopback = 1'b1;
    rx_drive = 1'b1;
    clk      = 1'b0;
    reset_n  = 1'b1;
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");

    #2 reset_n = 1'b0;
    repeat (3) @(posedge clk);
    reset_n = 1'b1;
    @(posedge clk);

    // ---- happy path via loopback ----
    vec[0] = 8'h00; vec[1] = 8'hFF; vec[2] = 8'hA5; vec[3] = 8'h5C;
    for (i = 0; i < 4; i = i + 1) begin
        prev = rx_count;
        tx_byte(vec[i]);
        wait_byte(prev);
        if (got_data !== vec[i] || got_pe || got_fe) begin
            $sformat(str, "Loopback %0h: got %0h pe=%0b fe=%0b", vec[i], got_data, got_pe, got_fe);
            logger.error(module_name, str);
            errors = errors + 1;
        end else begin
            $sformat(str, "Loopback %0h OK", vec[i]);
            logger.info(module_name, str);
        end
    end

    // ---- error paths via direct rx drive ----
    loopback = 1'b0;
    @(posedge clk);

    // bad parity: correct even parity is ^d, send the inverse
    prev = rx_count;
    rx_send(8'h3C, ~(^8'h3C), 1'b1);
    wait_byte(prev);
    if (got_data !== 8'h3C || !got_pe || got_fe) begin
        $sformat(str, "Bad-parity case: got %0h pe=%0b fe=%0b", got_data, got_pe, got_fe);
        logger.error(module_name, str);
        errors = errors + 1;
    end else
        logger.info(module_name, "Parity error detected");

    // bad stop bit (stop = 0)
    prev = rx_count;
    rx_send(8'h91, ^8'h91, 1'b0);
    wait_byte(prev);
    if (got_data !== 8'h91 || got_pe || !got_fe) begin
        $sformat(str, "Bad-stop case: got %0h pe=%0b fe=%0b", got_data, got_pe, got_fe);
        logger.error(module_name, str);
        errors = errors + 1;
    end else
        logger.info(module_name, "Frame error detected");

    // a clean direct frame must report no error
    prev = rx_count;
    rx_send(8'h6D, ^8'h6D, 1'b1);
    wait_byte(prev);
    if (got_data !== 8'h6D || got_pe || got_fe) begin
        $sformat(str, "Clean direct frame: got %0h pe=%0b fe=%0b", got_data, got_pe, got_fe);
        logger.error(module_name, str);
        errors = errors + 1;
    end else
        logger.info(module_name, "Clean direct frame OK");

    if (errors == 0)
        `TEST_PASS
    else
        `TEST_FAIL
end

initial begin
    #2000000;
    logger.error(module_name, "Watchdog timeout -- UART test hung");
    `TEST_FAIL
end

endmodule
