`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`default_nettype wire

// Wishbone B4 classic-standard slave: OSD text-overlay control on the 27 MHz bus.
//
// Split out of the old monolithic modbus_cam_backend. Owns:
//   * 0xFB -> write bit0 = enable overlay, bit1 = clear the whole char buffer;
//             read bit0 = current enable state
//   * 0xFC -> write = char-cell write cursor (row*COLS + col); read = current cursor
//   * 0xFD -> write = char code at the cursor, cursor auto-increments; reads 0
//
// Drives the dual-clock char-buffer write port in OSDOverlay (osd_wr_*). A clear
// walks all cells writing 0x00 (blank glyph) in the background; a data write
// deposits one char code at the cursor and auto-increments it.
//
// Single-cycle slave: wb_ack_o = stb & cyc, wb_dat_o combinational. The bus block
// turns each write into a 1-cycle pulse (osd_addr_we / osd_data_we /
// osd_clear_pulse) consumed by the char-buffer write block, exactly as the old
// monolith did. The clear sweep runs in the background and never stalls the bus.

module wb_osd (
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

    // OSD text overlay (LCD): enable bit + character-buffer write port
    output reg         osd_enable,      // held: 1 = OSD visible
    output reg         osd_wr_en,       // 1-cycle write strobe into the char buffer
    output reg [10:0]  osd_wr_addr,     // character cell (row*COLS + col)
    output reg [7:0]   osd_wr_data      // glyph/char code
);
    localparam [15:0] ADDR_OSD_CTRL = 16'h00FB,
                      ADDR_OSD_ADDR = 16'h00FC,
                      ADDR_OSD_DATA = 16'h00FD;

    localparam integer OSD_CELLS = 60 * 17;          // 60x17 grid (must match OSDOverlay)

    wire sel = wb_stb_i & wb_cyc_i;

    // ---- OSD write cursor + clear sweep (drives the char-buffer write port) ----
    reg [10:0] osd_cursor;
    reg        osd_addr_we;       // pulse: load cursor from osd_addr_val
    reg [10:0] osd_addr_val;
    reg        osd_data_we;       // pulse: write osd_data_val at the cursor, then cursor++
    reg [7:0]  osd_data_val;
    reg        osd_clear_pulse;   // pulse: blank the whole buffer
    reg        osd_clear_busy;
    reg [10:0] osd_clear_addr;

    // single-cycle slave: acknowledge immediately
    assign wb_ack_o = sel;

    // combinational read decode
    always @* begin
        case (wb_adr_i)
            ADDR_OSD_CTRL: wb_dat_o = {15'd0, osd_enable};
            ADDR_OSD_ADDR: wb_dat_o = {5'd0, osd_cursor};
            default:       wb_dat_o = 16'h0000;     // 0xFD + any unowned address
        endcase
    end

    // ---- bus side: turn writes into the control pulses ----
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            osd_enable      <= `WRAP_SIM(#1) 1'b0;
            osd_addr_we     <= `WRAP_SIM(#1) 1'b0;
            osd_addr_val    <= `WRAP_SIM(#1) 11'd0;
            osd_data_we     <= `WRAP_SIM(#1) 1'b0;
            osd_data_val    <= `WRAP_SIM(#1) 8'd0;
            osd_clear_pulse <= `WRAP_SIM(#1) 1'b0;
        end else begin
            osd_addr_we     <= `WRAP_SIM(#1) 1'b0;   // 1-cycle pulse defaults
            osd_data_we     <= `WRAP_SIM(#1) 1'b0;
            osd_clear_pulse <= `WRAP_SIM(#1) 1'b0;

            if (sel && wb_we_i) begin
                case (wb_adr_i)
                    ADDR_OSD_CTRL: begin
                        osd_enable      <= `WRAP_SIM(#1) wb_dat_i[0];
                        osd_clear_pulse <= `WRAP_SIM(#1) wb_dat_i[1];
                    end
                    ADDR_OSD_ADDR: begin
                        osd_addr_we  <= `WRAP_SIM(#1) 1'b1;
                        osd_addr_val <= `WRAP_SIM(#1) wb_dat_i[10:0];
                    end
                    ADDR_OSD_DATA: begin
                        osd_data_we  <= `WRAP_SIM(#1) 1'b1;
                        osd_data_val <= `WRAP_SIM(#1) wb_dat_i[7:0];
                    end
                    default: ;
                endcase
            end
        end
    end

    // ---- char-buffer write port + clear sweep ----
    // Consumes the 1-cycle pulses above and drives the dual-clock char-buffer
    // write side in OSDOverlay. A clear walks all cells writing 0x00; a data write
    // deposits one char code at the cursor and auto-increments it.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            osd_wr_en      <= `WRAP_SIM(#1) 1'b0;
            osd_wr_addr    <= `WRAP_SIM(#1) 11'd0;
            osd_wr_data    <= `WRAP_SIM(#1) 8'd0;
            osd_cursor     <= `WRAP_SIM(#1) 11'd0;
            osd_clear_busy <= `WRAP_SIM(#1) 1'b0;
            osd_clear_addr <= `WRAP_SIM(#1) 11'd0;
        end else begin
            osd_wr_en <= `WRAP_SIM(#1) 1'b0;          // default: no write this cycle
            if (osd_clear_busy) begin
                osd_wr_en   <= `WRAP_SIM(#1) 1'b1;
                osd_wr_addr <= `WRAP_SIM(#1) osd_clear_addr;
                osd_wr_data <= `WRAP_SIM(#1) 8'h00;
                if (osd_clear_addr == OSD_CELLS - 1) begin
                    osd_clear_busy <= `WRAP_SIM(#1) 1'b0;
                    osd_cursor     <= `WRAP_SIM(#1) 11'd0;   // home the cursor after a clear
                end else
                    osd_clear_addr <= `WRAP_SIM(#1) osd_clear_addr + 1'b1;
            end else if (osd_clear_pulse) begin
                osd_clear_busy <= `WRAP_SIM(#1) 1'b1;
                osd_clear_addr <= `WRAP_SIM(#1) 11'd0;
            end else if (osd_addr_we) begin
                osd_cursor <= `WRAP_SIM(#1) osd_addr_val;
            end else if (osd_data_we) begin
                osd_wr_en   <= `WRAP_SIM(#1) 1'b1;
                osd_wr_addr <= `WRAP_SIM(#1) osd_cursor;
                osd_wr_data <= `WRAP_SIM(#1) osd_data_val;
                osd_cursor  <= `WRAP_SIM(#1) (osd_cursor == OSD_CELLS - 1)
                                              ? 11'd0 : osd_cursor + 1'b1;
            end
        end
    end

endmodule
