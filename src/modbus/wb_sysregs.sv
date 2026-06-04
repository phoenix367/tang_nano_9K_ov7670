`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`default_nettype wire

// Wishbone B4 classic-standard slave: system status registers on the 27 MHz bus.
//
// Split out of the old monolithic modbus_cam_backend. Owns the reserved status
// register band (above the OV7670 camera range), all served combinationally in a
// single bus cycle (no wait states):
//   * 0xF0 -> firmware magic 0xA5 (identifies the bridge firmware)
//   * 0xF1 -> uptime high byte (a read latches the 16-bit counter for a coherent pair)
//   * 0xF2 -> uptime low byte (returns the latched value)
//   * 0xF9 -> watchdog health bits (read-only, see wd_health)
//   * 0xFA -> write bit0 = re-run camera init (reset to defaults); reads 0
//
// The free-running uptime counter is independent of the bus: it is 0 at reset and
// ticks ~1 Hz at 27 MHz, so a host that sees it jump backward knows the device was
// hard-reset.
//
// Single-cycle slave: wb_ack_o = stb & cyc (mirrors the proven internal-backend
// timing of modbus_rtu_slave), wb_dat_o is a combinational decode. Side effects
// (uptime latch, cam_reinit pulse) are registered and qualified by stb&cyc so an
// access to another slave's address never disturbs this one.

module wb_sysregs
#(
    // Free-running uptime counter increments every UPTIME_DIV clk cycles
    // (~1 Hz at 27 MHz). Override small in simulation.
    parameter integer UPTIME_DIV = 27_000_000
)
(
    input  wire        clk,
    input  wire        reset_n,

    // Wishbone B4 classic-standard slave
    input  wire [15:0] wb_adr_i,
    input  wire [15:0] wb_dat_i,
    output reg  [15:0] wb_dat_o,
    input  wire        wb_we_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output wire        wb_ack_o,

    // pulse: re-run the power-on camera initialization (reset to defaults)
    output reg         cam_reinit,
    // watchdog health bits: [4]=monitoring [3]=any-hang [2]=cam [1]=mem [0]=lcd
    input  wire [4:0]  wd_health
);
    localparam [7:0]  STATUS_MAGIC   = 8'hA5;
    localparam [15:0] ADDR_MAGIC     = 16'h00F0,
                      ADDR_UPTIME_HI = 16'h00F1,
                      ADDR_UPTIME_LO = 16'h00F2,
                      ADDR_HEALTH    = 16'h00F9,
                      ADDR_REINIT    = 16'h00FA;

    wire sel = wb_stb_i & wb_cyc_i;       // this slave is addressed this cycle

    reg [15:0] uptime;          // free-running seconds-ish, 0 on reset
    reg [15:0] uptime_latch;    // captured on a high-byte read for a coherent pair
    reg [31:0] uptime_div;

    // single-cycle slave: acknowledge immediately
    assign wb_ack_o = sel;

    // combinational read decode (valid while the master holds the address)
    always @* begin
        case (wb_adr_i)
            ADDR_MAGIC:     wb_dat_o = {8'h00, STATUS_MAGIC};
            ADDR_UPTIME_HI: wb_dat_o = {8'h00, uptime[15:8]};
            ADDR_UPTIME_LO: wb_dat_o = {8'h00, uptime_latch[7:0]};
            ADDR_HEALTH:    wb_dat_o = {11'd0, wd_health};
            default:        wb_dat_o = 16'h0000;     // 0xFA + any unowned address
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cam_reinit   <= `WRAP_SIM(#1) 1'b0;
            uptime       <= `WRAP_SIM(#1) 16'h0000;
            uptime_latch <= `WRAP_SIM(#1) 16'h0000;
            uptime_div   <= `WRAP_SIM(#1) 32'h0;
        end else begin
            cam_reinit <= `WRAP_SIM(#1) 1'b0;   // 1-cycle pulse default

            // free-running uptime tick (independent of the bus)
            if (uptime_div >= UPTIME_DIV - 1) begin
                uptime_div <= `WRAP_SIM(#1) 32'h0;
                uptime     <= `WRAP_SIM(#1) uptime + 1'b1;
            end else
                uptime_div <= `WRAP_SIM(#1) uptime_div + 1'b1;

            if (sel) begin
                // a high-byte read latches the counter so the following low-byte
                // read returns a coherent 16-bit pair
                if (!wb_we_i && wb_adr_i == ADDR_UPTIME_HI)
                    uptime_latch <= `WRAP_SIM(#1) uptime;
                // write 1 to 0xFA bit0 -> re-run camera init
                if (wb_we_i && wb_adr_i == ADDR_REINIT && wb_dat_i[0])
                    cam_reinit <= `WRAP_SIM(#1) 1'b1;
            end
        end
    end

endmodule
