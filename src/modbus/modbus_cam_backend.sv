`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`default_nettype wire

// Wishbone composition root for the 27 MHz control plane.
//
// This module used to be a single monolithic FSM bridging the modbus_rtu_slave
// register-backend handshake (be_*) to five unrelated jobs. It is now a thin
// wrapper that exposes the SAME port list (so camera_control.v and the cam_bridge
// integration test are unchanged) but internally is a Wishbone B4 classic-standard
// bus: the be_* handshake drives a wb_interconnect that address-decodes to four
// independent, individually-testable slaves --
//
//   * wb_sccb     0x0000..0x00C9                OV7670 camera registers (SCCB)
//   * wb_sysregs  0xF0,F1,F2,F9,FA              magic / uptime / health / reinit
//   * wb_grab     0xF3..F8 + (read) >= 0x1000   ch1 frame grab + stream download
//   * wb_osd      0xFB,FC,FD                    OSD text-overlay control
//
// The be_* protocol (assert be_req, stall until be_ready, capture be_rdata) is a
// single-outstanding register access that maps 1:1 onto a classic-standard cycle,
// so no adapter logic is needed -- just net renaming below:
//   cyc = stb = be_req,  we = be_we,  adr = be_addr,  dat_w = be_wdata,
//   ack -> be_ready,     dat_r -> be_rdata.
// Everything is on `clk` (sys_clk, 27 MHz); the CDC into psram_ch1 (grab) and
// OSDOverlay (osd) lives downstream in VGA_timing, so no synchronizers here.

module modbus_cam_backend
#(
    // forwarded to wb_sysregs: uptime tick divider (~1 Hz at 27 MHz; small in sim)
    parameter integer UPTIME_DIV = 27_000_000
)
(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        cam_init_complete,  // gate: 1 once camera init has finished

    // register-backend handshake (connect to modbus_rtu_slave be_*)
    input  wire        be_req,
    input  wire        be_we,
    input  wire [15:0] be_addr,
    input  wire [15:0] be_wdata,
    output wire        be_ready,
    output wire [15:0] be_rdata,

    // i2c_control_fsm handshake (wb_sccb)
    output wire        store_data,
    output wire        send_data,
    output wire        recv_data,
    output wire [7:0]  i2c_din,
    input  wire        device_rdy,
    input  wire        data_valid,
    input  wire [7:0]  i2c_dout,

    output wire        busy,

    // pulse: re-run the power-on camera initialization (wb_sysregs)
    output wire        cam_reinit,
    // pulse: host-commanded SERV MCU reset (wb_sysregs 0xE2); crosses to mcu_clk
    // in camera_control.v. Unconnected on a non-SERV build.
    output wire        mcu_reset,

    // OSD text overlay (LCD): enable bit + character-buffer write port (wb_osd)
    output wire        osd_enable,
    output wire        osd_wr_en,
    output wire [10:0] osd_wr_addr,
    output wire [7:0]  osd_wr_data,
    output wire [10:0] osd_rb_addr,   // OSD char-buffer read-back: cursor out
    input  wire [7:0]  osd_rb_data,   //                            glyph in

    // channel-1 PSRAM bring-up loopback (wb_grab, to/from psram_ch1 via VGA_timing)
    output wire        grab_arm,
    output wire        grab_rd_req,
    output wire        grab_wr_req,
    output wire [31:0] grab_wr_data,
    output wire [20:0] grab_rd_addr,
    input  wire        grab_busy,
    input  wire [255:0] grab_rd_data,
    input  wire        grab_calib,
    // health watchdog status (wb_sysregs reg 0xF9)
    input  wire [4:0]  wd_health
);
    // ---- be_* -> Wishbone master nets (1:1 rename) ----
    wire        m_cyc;
    wire        m_stb;
    wire        m_we;
    wire [15:0] m_adr;
    wire [15:0] m_dat_w;
    assign m_cyc   = be_req;
    assign m_stb   = be_req;
    assign m_we    = be_we;
    assign m_adr   = be_addr;
    assign m_dat_w = be_wdata;

    // ---- per-slave bus fan-out ----
    wire        sccb_stb,    sysregs_stb,    grab_stb,    osd_stb;
    wire        sccb_ack,    sysregs_ack,    grab_ack,    osd_ack;
    wire [15:0] sccb_dat,    sysregs_dat,    grab_dat,    osd_dat;

    wb_interconnect xbar (
        .m_adr_i(m_adr),
        .m_we_i(m_we),
        .m_stb_i(m_stb),
        .m_cyc_i(m_cyc),
        .m_ack_o(be_ready),
        .m_dat_o(be_rdata),
        .sccb_stb_o(sccb_stb),
        .sysregs_stb_o(sysregs_stb),
        .grab_stb_o(grab_stb),
        .osd_stb_o(osd_stb),
        .sccb_ack_i(sccb_ack),       .sccb_dat_i(sccb_dat),
        .sysregs_ack_i(sysregs_ack), .sysregs_dat_i(sysregs_dat),
        .grab_ack_i(grab_ack),       .grab_dat_i(grab_dat),
        .osd_ack_i(osd_ack),         .osd_dat_i(osd_dat)
    );

    wb_sccb sccb (
        .clk(clk), .reset_n(reset_n),
        .cam_init_complete(cam_init_complete),
        .wb_adr_i(m_adr), .wb_dat_i(m_dat_w), .wb_dat_o(sccb_dat),
        .wb_we_i(m_we), .wb_stb_i(sccb_stb), .wb_cyc_i(m_cyc), .wb_ack_o(sccb_ack),
        .store_data(store_data), .send_data(send_data), .recv_data(recv_data),
        .i2c_din(i2c_din),
        .device_rdy(device_rdy), .data_valid(data_valid), .i2c_dout(i2c_dout),
        .busy(busy)
    );

    wb_sysregs #(.UPTIME_DIV(UPTIME_DIV)) sysregs (
        .clk(clk), .reset_n(reset_n),
        .wb_adr_i(m_adr), .wb_dat_i(m_dat_w), .wb_dat_o(sysregs_dat),
        .wb_we_i(m_we), .wb_stb_i(sysregs_stb), .wb_cyc_i(m_cyc), .wb_ack_o(sysregs_ack),
        .cam_reinit(cam_reinit),
        .mcu_reset(mcu_reset),
        .wd_health(wd_health)
    );

    wb_grab grab (
        .clk(clk), .reset_n(reset_n),
        .wb_adr_i(m_adr), .wb_dat_i(m_dat_w), .wb_dat_o(grab_dat),
        .wb_we_i(m_we), .wb_stb_i(grab_stb), .wb_cyc_i(m_cyc), .wb_ack_o(grab_ack),
        .grab_arm(grab_arm), .grab_rd_req(grab_rd_req),
        .grab_wr_req(grab_wr_req), .grab_wr_data(grab_wr_data),
        .grab_rd_addr(grab_rd_addr),
        .grab_busy(grab_busy), .grab_rd_data(grab_rd_data), .grab_calib(grab_calib)
    );

    wb_osd osd (
        .clk(clk), .reset_n(reset_n),
        .wb_adr_i(m_adr), .wb_dat_i(m_dat_w), .wb_dat_o(osd_dat),
        .wb_we_i(m_we), .wb_stb_i(osd_stb), .wb_cyc_i(m_cyc), .wb_ack_o(osd_ack),
        .osd_enable(osd_enable), .osd_wr_en(osd_wr_en),
        .osd_wr_addr(osd_wr_addr), .osd_wr_data(osd_wr_data),
        .osd_rb_addr(osd_rb_addr), .osd_rb_data(osd_rb_data)
    );

endmodule
