`ifdef __ICARUS__
`include "timescale.v"
`else
`include "../timescale.v"
`endif

`default_nettype wire

// Wishbone B4 classic-standard interconnect: one master, four slaves, on the
// 27 MHz bus. Pure combinational address decode + read-data/ack muxing.
//
// Address ownership (the register map is byte-identical to the old monolith):
//   * wb_sccb     0x0000..0x00C9                (OV7670 camera registers)
//   * wb_sysregs  0xF0,F1,F2,F9,FA              (magic/uptime/health/reinit)
//   * wb_grab     0xF3..F8 + (read) >= 0x1000   (frame grab + stream download)
//   * wb_osd      0xFB,FC,FD                    (OSD overlay control)
//
// The 0xFx block is split across three slaves, so it is decoded by EXPLICIT
// equality (never a range) -- a naive 0xF0..0xFA range would steal grab's F3..F8.
// The owner predicates are mutually exclusive by construction (the camera range
// ends at 0xC9, the F-regs are distinct constants, the stream band starts at
// 0x1000), so at most one fires.
//
// Any address owned by no slave (gaps 0xCA..0xEF, 0xFE/FF, 0x0100..0x0FFF, and
// stream-band WRITES) falls to `sel_none`, which acks immediately with read data
// 0 -- preserving the old `default` arm so the bus never hangs on an unmapped
// address. The address is held stable by the master for the whole access, so the
// combinational decode is glitch-free for a classic-standard cycle.

module wb_interconnect (
    // master side (driven by the modbus_rtu_slave be_* handshake, renamed)
    input  wire [15:0] m_adr_i,
    input  wire        m_we_i,
    input  wire        m_stb_i,
    input  wire        m_cyc_i,
    output wire        m_ack_o,
    output wire [15:0] m_dat_o,         // read data returned to the master

    // per-slave select strobes (each slave also sees m_cyc_i as wb_cyc_i)
    output wire        sccb_stb_o,
    output wire        sysregs_stb_o,
    output wire        grab_stb_o,
    output wire        osd_stb_o,

    // per-slave ack + read data
    input  wire        sccb_ack_i,    input wire [15:0] sccb_dat_i,
    input  wire        sysregs_ack_i, input wire [15:0] sysregs_dat_i,
    input  wire        grab_ack_i,    input wire [15:0] grab_dat_i,
    input  wire        osd_ack_i,     input wire [15:0] osd_dat_i
);
    wire active = m_cyc_i & m_stb_i;

    // wb_grab also serves the stream band, but only for READS (a stream-band
    // write is unowned -> sel_none, matching the old default arm).
    wire stream_rd = active & ~m_we_i & (m_adr_i >= 16'h1000);

    wire sel_sccb     = active & (m_adr_i <= 16'h00C9);
    wire sel_sysregs  = active & (   (m_adr_i == 16'h00F0)
                                   | (m_adr_i == 16'h00F1)
                                   | (m_adr_i == 16'h00F2)
                                   | (m_adr_i == 16'h00F9)
                                   | (m_adr_i == 16'h00FA));
    wire sel_grab_reg = active & (   (m_adr_i == 16'h00F3)
                                   | (m_adr_i == 16'h00F4)
                                   | (m_adr_i == 16'h00F5)
                                   | (m_adr_i == 16'h00F6)
                                   | (m_adr_i == 16'h00F7)
                                   | (m_adr_i == 16'h00F8));
    wire sel_grab     = sel_grab_reg | stream_rd;
    wire sel_osd      = active & (   (m_adr_i == 16'h00FB)
                                   | (m_adr_i == 16'h00FC)
                                   | (m_adr_i == 16'h00FD));
    wire sel_none     = active & ~(sel_sccb | sel_sysregs | sel_grab | sel_osd);

    assign sccb_stb_o    = sel_sccb;
    assign sysregs_stb_o = sel_sysregs;
    assign grab_stb_o    = sel_grab;
    assign osd_stb_o     = sel_osd;

    // ack mux: each slave's ack is qualified by its select (defense in depth so an
    // unselected slave can never force the bus), plus the default-ack for gaps.
    assign m_ack_o = (sel_sccb    & sccb_ack_i)
                   | (sel_sysregs & sysregs_ack_i)
                   | (sel_grab    & grab_ack_i)
                   | (sel_osd     & osd_ack_i)
                   | sel_none;

    // read-data mux: priority select, default 0 for unmapped addresses
    assign m_dat_o = sel_sccb    ? sccb_dat_i
                   : sel_sysregs ? sysregs_dat_i
                   : sel_grab    ? grab_dat_i
                   : sel_osd     ? osd_dat_i
                   :               16'h0000;

endmodule
