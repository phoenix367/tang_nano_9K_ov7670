`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`elsif FORMAL
// formal (SymbiYosys/yosys): WRAP_SIM is a no-op outside Icarus -- define it empty
// so the read is self-contained (no include-path juggling under sby's flat copy).
`define WRAP_SIM(x)
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`default_nettype wire

// Wishbone B4 classic-standard slave: 4 bidirectional GPIO pins on the 27 MHz bus.
//
// A fifth slave alongside wb_sccb/wb_sysregs/wb_grab/wb_osd. Both bus masters reach
// it the same way -- the host over Modbus (FC03/06 to the register addresses) and
// the SERV soft core through its 0x40000000 EXT window -- so the 4 pins are
// controllable from either, with no extra wiring (the be_arbiter serialises them).
//
// Register map (reserved band above the OV7670 range):
//   * 0xEA GPIO_DIR  -- bits[3:0] direction, 1 = output (drive), 0 = input.
//                       Reset 0 -> all four pins are inputs (hi-Z) by default.
//   * 0xEB GPIO_DATA -- write: bits[3:0] output latch (driven where DIR=1);
//                       read:  bits[3:0] = live pin levels (synchronised pads).
//
// The pads themselves are tri-stated in camera_control.v (one IOBUF per pin):
// gpio[i] = gpio_dir[i] ? gpio_out[i] : 1'bz, and gpio_in[i] = gpio[i]. The async
// pad inputs are run through a 2-FF synchroniser here before the bus can read them.
//
// Single-cycle slave: wb_ack_o = stb & cyc, wb_dat_o a combinational decode (same
// timing as wb_sysregs). Writes are registered and qualified by stb&cyc&we, so an
// access to another slave's address never disturbs the GPIO state.

module wb_gpio (
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

    // pad side (to the tri-state IOBUFs in camera_control.v)
    output reg  [3:0]  gpio_dir,   // 1 = drive (output), 0 = input (hi-Z); reset 0
    output reg  [3:0]  gpio_out,   // value driven on a pin when its dir bit is 1
    input  wire [3:0]  gpio_in     // raw async pad level (synchronised below)
);
    localparam [15:0] ADDR_DIR  = 16'h00EA,
                      ADDR_DATA = 16'h00EB;

    wire sel = wb_stb_i & wb_cyc_i;
    assign wb_ack_o = sel;                 // single-cycle ack

    reg [3:0] in_meta, in_sync;            // 2-FF synchroniser for the async pads

    // combinational read decode (valid while the master holds the address)
    always @* begin
        case (wb_adr_i)
            ADDR_DIR:  wb_dat_o = {12'd0, gpio_dir};
            ADDR_DATA: wb_dat_o = {12'd0, in_sync};   // live pin levels
            default:   wb_dat_o = 16'h0000;
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            gpio_dir <= `WRAP_SIM(#1) 4'h0;    // all inputs at reset
            gpio_out <= `WRAP_SIM(#1) 4'h0;
            in_meta  <= `WRAP_SIM(#1) 4'h0;
            in_sync  <= `WRAP_SIM(#1) 4'h0;
        end else begin
            in_meta <= `WRAP_SIM(#1) gpio_in;
            in_sync <= `WRAP_SIM(#1) in_meta;
            if (sel & wb_we_i) begin
                if (wb_adr_i == ADDR_DIR)  gpio_dir <= `WRAP_SIM(#1) wb_dat_i[3:0];
                if (wb_adr_i == ADDR_DATA) gpio_out <= `WRAP_SIM(#1) wb_dat_i[3:0];
            end
        end
    end

`ifdef FORMAL
    // ---- Formal verification (yosys k-induction; see sby/wb_gpio.sby) ----
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    always @(posedge clk) begin
        // single-cycle ack, exactly when addressed
        assert (wb_ack_o == (wb_stb_i & wb_cyc_i));

        if (f_past_valid && reset_n && $past(reset_n)) begin
            // a write to GPIO_DIR / GPIO_DATA updates exactly that register...
            if ($past(sel) && $past(wb_we_i) && $past(wb_adr_i) == ADDR_DIR)
                assert (gpio_dir == $past(wb_dat_i[3:0]));
            if ($past(sel) && $past(wb_we_i) && $past(wb_adr_i) == ADDR_DATA)
                assert (gpio_out == $past(wb_dat_i[3:0]));
            // ...and nothing else can change the GPIO state (no write to our addrs)
            if (!($past(sel) && $past(wb_we_i) && $past(wb_adr_i) == ADDR_DIR))
                assert (gpio_dir == $past(gpio_dir));
            if (!($past(sel) && $past(wb_we_i) && $past(wb_adr_i) == ADDR_DATA))
                assert (gpio_out == $past(gpio_out));
        end
        // after reset, default is "all inputs"
        if (f_past_valid && !$past(reset_n))
            assert (gpio_dir == 4'h0);
    end
`endif

endmodule
