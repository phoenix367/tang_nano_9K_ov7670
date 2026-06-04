`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for wb_interconnect (combinational Wishbone address decode + muxing).
//
// Stubs the four slaves (each acks with a distinct read-data constant) and checks,
// for every interesting address, that exactly the right per-slave strobe asserts,
// that m_ack_o is high, and that m_dat_o routes the selected slave's data. Unmapped
// addresses (gaps, 0xFE/FF, the 0x0100..0x0FFF band, and stream-band WRITES) must
// select no slave yet still ack with read data 0 (the preserved default arm). With
// cyc low, nothing is selected and ack is low.
//
// The 0xFx split is the off-by-one hot spot: F0/F1/F2/F9/FA -> sysregs,
// F3..F8 -> grab, FB/FC/FD -> osd. Every one of those is checked explicitly.

module main();

localparam LOG_LEVEL = `DEFAULT_LOG_LEVEL;

localparam [15:0] D_SCCB = 16'hAAAA, D_SYS = 16'h5555,
                  D_GRAB = 16'h1234, D_OSD = 16'h0FF0;

reg  [15:0] m_adr;
reg         m_we, m_stb, m_cyc;
wire        m_ack;
wire [15:0] m_dat;
wire        sccb_stb, sysregs_stb, grab_stb, osd_stb;

integer errors;
string  module_name, str;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

wb_interconnect dut (
    .m_adr_i(m_adr), .m_we_i(m_we), .m_stb_i(m_stb), .m_cyc_i(m_cyc),
    .m_ack_o(m_ack), .m_dat_o(m_dat),
    .sccb_stb_o(sccb_stb), .sysregs_stb_o(sysregs_stb),
    .grab_stb_o(grab_stb), .osd_stb_o(osd_stb),
    .sccb_ack_i(1'b1),    .sccb_dat_i(D_SCCB),
    .sysregs_ack_i(1'b1), .sysregs_dat_i(D_SYS),
    .grab_ack_i(1'b1),    .grab_dat_i(D_GRAB),
    .osd_ack_i(1'b1),     .osd_dat_i(D_OSD)
);

task automatic err(input string label, input string what);
    begin
        $sformat(str, "%s: wrong %s (sccb=%b sys=%b grab=%b osd=%b ack=%b)",
                 label, what, sccb_stb, sysregs_stb, grab_stb, osd_stb, m_ack);
        logger.error(module_name, str); errors = errors + 1;
    end
endtask

// expected one-hot strobe code: 0=none,1=sccb,2=sysregs,3=grab,4=osd
task automatic check(input [15:0] a, input wv, input integer who,
                     input [15:0] exp_dat, input string label);
    reg [3:0] sv;
    begin
        m_adr = a; m_we = wv; m_cyc = 1'b1; m_stb = 1'b1; #1;
        sv = {osd_stb, grab_stb, sysregs_stb, sccb_stb};
        case (who)
            1: if (sv !== 4'b0001) begin err(label, "sccb_stb"); end
            2: if (sv !== 4'b0010) begin err(label, "sysregs_stb"); end
            3: if (sv !== 4'b0100) begin err(label, "grab_stb"); end
            4: if (sv !== 4'b1000) begin err(label, "osd_stb"); end
            default: if (sv !== 4'b0000) begin err(label, "no strobe"); end
        endcase
        if (m_ack !== 1'b1) err(label, "ack high");
        if (m_dat !== exp_dat) begin
            $sformat(str, "%s: dat=%h, expected %h", label, m_dat, exp_dat);
            logger.error(module_name, str); errors = errors + 1;
        end
        m_cyc = 1'b0; m_stb = 1'b0; #1;
    end
endtask

initial begin
`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif
    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");
    errors = 0;
    m_adr = 0; m_we = 0; m_stb = 0; m_cyc = 0; #1;

    // camera range -> sccb
    check(16'h0000, 1'b0, 1, D_SCCB, "0x00 camera");
    check(16'h0050, 1'b1, 1, D_SCCB, "0x50 camera write");
    check(16'h00C9, 1'b0, 1, D_SCCB, "0xC9 camera top");

    // co-master heartbeat register routes to sysregs
    check(16'h00E0, 1'b1, 2, D_SYS,  "0xE0 heartbeat write -> sysregs");
    check(16'h00E0, 1'b0, 2, D_SYS,  "0xE0 heartbeat read -> sysregs");

    // the 0xFx split
    check(16'h00F0, 1'b0, 2, D_SYS,  "0xF0 magic");
    check(16'h00F1, 1'b0, 2, D_SYS,  "0xF1 uptime hi");
    check(16'h00F2, 1'b0, 2, D_SYS,  "0xF2 uptime lo");
    check(16'h00F3, 1'b1, 3, D_GRAB, "0xF3 grab ctrl");
    check(16'h00F4, 1'b1, 3, D_GRAB, "0xF4 rdaddr lo");
    check(16'h00F5, 1'b1, 3, D_GRAB, "0xF5 rdaddr hi");
    check(16'h00F6, 1'b0, 3, D_GRAB, "0xF6 rddata hi");
    check(16'h00F7, 1'b0, 3, D_GRAB, "0xF7 rddata lo");
    check(16'h00F8, 1'b1, 3, D_GRAB, "0xF8 stream rewind");
    check(16'h00F9, 1'b0, 2, D_SYS,  "0xF9 health");
    check(16'h00FA, 1'b1, 2, D_SYS,  "0xFA reinit");
    check(16'h00FB, 1'b1, 4, D_OSD,  "0xFB osd ctrl");
    check(16'h00FC, 1'b1, 4, D_OSD,  "0xFC osd addr");
    check(16'h00FD, 1'b1, 4, D_OSD,  "0xFD osd data");

    // stream band: read -> grab, write -> unowned (default ack)
    check(16'h1000, 1'b0, 3, D_GRAB, "0x1000 stream read");
    check(16'h2ABC, 1'b0, 3, D_GRAB, "stream read high");
    check(16'h1000, 1'b1, 0, 16'h0000, "0x1000 stream write (unowned)");

    // OSD burst-read band [0x0800..0x0FFF]: read -> osd, write -> unowned
    check(16'h0800, 1'b0, 4, D_OSD,  "0x0800 osd burst read");
    check(16'h0BFB, 1'b0, 4, D_OSD,  "osd burst read top cell");
    check(16'h0FFF, 1'b0, 4, D_OSD,  "osd band high");
    check(16'h0800, 1'b1, 0, 16'h0000, "0x0800 osd-band write (unowned)");

    // unmapped gaps -> no slave, default ack, data 0
    check(16'h00CA, 1'b0, 0, 16'h0000, "0xCA gap");
    check(16'h00EF, 1'b0, 0, 16'h0000, "0xEF gap");
    check(16'h00FE, 1'b0, 0, 16'h0000, "0xFE gap");
    check(16'h00FF, 1'b0, 0, 16'h0000, "0xFF gap");
    check(16'h0200, 1'b0, 0, 16'h0000, "0x0200 gap (below the OSD band)");
    check(16'h07FF, 1'b0, 0, 16'h0000, "0x07FF gap (just below the OSD band)");

    // cyc low -> no select, no ack
    m_adr = 16'h0000; m_we = 1'b0; m_cyc = 1'b0; m_stb = 1'b1; #1;
    if (m_ack !== 1'b0 || sccb_stb !== 1'b0) begin
        logger.error(module_name, "ack/strobe asserted with cyc low"); errors = errors + 1;
    end

    if (errors == 0) begin
        logger.info(module_name, "wb_interconnect: all addresses route + default-ack correctly");
        `TEST_PASS
    end else
        `TEST_FAIL
end

endmodule
