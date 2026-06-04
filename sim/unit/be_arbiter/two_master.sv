`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for be_arbiter: master 0 (host) priority, master 1 (SERV) coexists,
// and owner-lock prevents mid-transaction preemption on a multi-cycle access.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;

reg         clk, reset_n;
reg         m0_req, m0_we; reg [15:0] m0_addr, m0_wdata;
wire        m0_ready; wire [15:0] m0_rdata;
reg         m1_req, m1_we; reg [15:0] m1_addr, m1_wdata;
wire        m1_ready; wire [15:0] m1_rdata;
wire        be_req, be_we; wire [15:0] be_addr, be_wdata;
wire        be_ready; reg [15:0] be_rdata;

integer errors;
string  module_name, str;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

be_arbiter dut(
    .clk(clk), .reset_n(reset_n),
    .m0_req(m0_req), .m0_we(m0_we), .m0_addr(m0_addr), .m0_wdata(m0_wdata),
    .m0_ready(m0_ready), .m0_rdata(m0_rdata),
    .m1_req(m1_req), .m1_we(m1_we), .m1_addr(m1_addr), .m1_wdata(m1_wdata),
    .m1_ready(m1_ready), .m1_rdata(m1_rdata),
    .be_req(be_req), .be_we(be_we), .be_addr(be_addr), .be_wdata(be_wdata),
    .be_ready(be_ready), .be_rdata(be_rdata));

always #5 clk = ~clk;

// downstream model: combinational ack once be_req has been held `latency` cycles
// (latency 0 = combinational same-cycle ack, like wb_sysregs; latency>0 = a
// multi-cycle slave like wb_grab). rdata echoes the address.
integer latency;
reg [7:0] wait_cnt;
always @(posedge clk or negedge reset_n)
    if (!reset_n)                 wait_cnt <= 0;
    else if (be_req & ~be_ready)  wait_cnt <= wait_cnt + 1;
    else                          wait_cnt <= 0;
assign be_ready = be_req & (wait_cnt >= latency);
always @(*) be_rdata = {8'hAB, be_addr[7:0]};

task automatic check(input cond, input string msg);
    if (!cond) begin logger.error(module_name, msg); errors = errors + 1; end
endtask

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");
    clk=0; reset_n=1; latency=0;
    m0_req=0; m0_we=0; m0_addr=0; m0_wdata=0;
    m1_req=0; m1_we=0; m1_addr=0; m1_wdata=0;
    errors=0;
    #2 reset_n=0; repeat(3) @(posedge clk); reset_n=1; @(negedge clk);

    // 1) m0 alone, single-cycle (latency 0): completes, addr/data pass through
    latency=0;
    m0_req=1; m0_we=1; m0_addr=16'h00F1; m0_wdata=16'h1234;
    @(posedge clk); #2;
    check(be_addr===16'h00F1 && be_wdata===16'h1234 && be_we===1'b1, "m0 passthrough");
    check(m0_ready===1'b1, "m0 single-cycle ready");
    m0_req=0; @(negedge clk);

    // 2) m1 alone, single-cycle
    m1_req=1; m1_we=1; m1_addr=16'h00E0; m1_wdata=16'h00AA;
    @(posedge clk); #2;
    check(be_addr===16'h00E0 && be_wdata===16'h00AA, "m1 passthrough");
    check(m1_ready===1'b1, "m1 single-cycle ready");
    m1_req=0; @(negedge clk);

    // 3) both request: m0 has priority, m1 stalls until m0 drops
    m0_req=1; m0_addr=16'h0055; m0_we=0;
    m1_req=1; m1_addr=16'h00E0; m1_we=1; m1_wdata=16'h0001;
    @(posedge clk); #2;
    check(be_addr===16'h0055, "m0 wins arbitration");
    check(m0_ready===1'b1 && m1_ready===1'b0, "m1 stalled while m0 active");
    m0_req=0; @(posedge clk); #2;
    check(be_addr===16'h00E0 && m1_ready===1'b1, "m1 served after m0 drops");
    m1_req=0; @(negedge clk);

    // 4) multi-cycle m1 access: m0 must NOT preempt mid-transaction (owner lock)
    latency=3;
    m1_req=1; m1_we=1; m1_addr=16'h00E0; m1_wdata=16'h0002;
    @(posedge clk); #2;                       // m1 granted, be_ready still low
    m0_req=1; m0_addr=16'h0099; m0_we=0;      // host barges in mid-access
    repeat(2) @(posedge clk); #2;
    check(be_addr===16'h00E0, "m1 owner-locked: m0 did not preempt");
    check(m0_ready===1'b0, "m0 held off during m1's locked access");
    // wait for m1 to finish, then m0 should take over
    wait (m1_ready); @(posedge clk); #2;
    m1_req=0; @(posedge clk); #2;
    check(be_addr===16'h0099, "m0 served after m1's locked access completes");
    m0_req=0;

    if (errors==0) begin
        logger.info(module_name, "be_arbiter: priority, coexistence, owner-lock all correct");
        `TEST_PASS
    end else `TEST_FAIL
end

always #5000000 begin
    logger.error(module_name, "System hangs"); `TEST_FAIL
end

endmodule
