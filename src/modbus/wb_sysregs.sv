`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`elsif FORMAL
// formal (SymbiYosys/yosys): the only thing this module needs from the project
// headers is WRAP_SIM, which is a no-op outside Icarus -- define it empty so the
// read is self-contained (no include-path juggling under sby's flat file copy).
`define WRAP_SIM(x)
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
                      ADDR_REINIT    = 16'h00FA,
                      // Scratch/heartbeat register: a co-master (the SERV soft
                      // core, Phase 2) writes an incrementing counter here and the
                      // host reads it back to confirm the CPU is live on the bus.
                      // Reads 0 on a build without SERV. RW, no side effects.
                      ADDR_HEARTBEAT = 16'h00E0,
                      // SERV bootloader mailbox (host = producer, SERV = consumer).
                      // BOOT_DATA is written only by the host and read only by SERV,
                      // so the slave tells producer from consumer by wb_we_i.
                      // Word-aligned register numbers (0xE0/E4/E8/EC) so SERV's
                      // RV32I lw/sw are aligned (be_addr = byte adr[15:0]).
                      ADDR_BOOT_LEN    = 16'h00E4,   // host writes overlay length (words) -> start
                      ADDR_BOOT_DATA   = 16'h00E8,   // host write -> pending; SERV read -> clears
                      ADDR_BOOT_STATUS = 16'h00EC;   // read: bit1=start, bit0=pending

    wire sel = wb_stb_i & wb_cyc_i;       // this slave is addressed this cycle

    reg [15:0] uptime;          // free-running seconds-ish, 0 on reset
    reg [15:0] uptime_latch;    // captured on a high-byte read for a coherent pair
    reg [31:0] uptime_div;
    reg [15:0] heartbeat;       // co-master scratch (0xE0); 0 until something writes it
    reg [15:0] boot_len;        // overlay length in 16-bit words (host -> SERV)
    reg [15:0] boot_data;       // current overlay word in the mailbox
    reg        boot_pending;    // a word is waiting for SERV to consume
    reg        boot_start;      // host has written BOOT_LEN (upload begun)

    // single-cycle slave: acknowledge immediately
    assign wb_ack_o = sel;

    // combinational read decode (valid while the master holds the address)
    always @* begin
        case (wb_adr_i)
            ADDR_MAGIC:     wb_dat_o = {8'h00, STATUS_MAGIC};
            ADDR_UPTIME_HI: wb_dat_o = {8'h00, uptime[15:8]};
            ADDR_UPTIME_LO: wb_dat_o = {8'h00, uptime_latch[7:0]};
            ADDR_HEALTH:    wb_dat_o = {11'd0, wd_health};
            ADDR_HEARTBEAT: wb_dat_o = heartbeat;
            ADDR_BOOT_LEN:    wb_dat_o = boot_len;
            ADDR_BOOT_DATA:   wb_dat_o = boot_data;
            ADDR_BOOT_STATUS: wb_dat_o = {14'd0, boot_start, boot_pending};
            default:        wb_dat_o = 16'h0000;     // 0xFA + any unowned address
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cam_reinit   <= `WRAP_SIM(#1) 1'b0;
            uptime       <= `WRAP_SIM(#1) 16'h0000;
            uptime_latch <= `WRAP_SIM(#1) 16'h0000;
            uptime_div   <= `WRAP_SIM(#1) 32'h0;
            heartbeat    <= `WRAP_SIM(#1) 16'h0000;
            boot_len     <= `WRAP_SIM(#1) 16'h0000;
            boot_data    <= `WRAP_SIM(#1) 16'h0000;
            boot_pending <= `WRAP_SIM(#1) 1'b0;
            boot_start   <= `WRAP_SIM(#1) 1'b0;
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
                // heartbeat (0xE0) is a plain RW scratch register
                if (wb_we_i && wb_adr_i == ADDR_HEARTBEAT)
                    heartbeat <= `WRAP_SIM(#1) wb_dat_i;

                // --- bootloader mailbox ---
                // host writes the overlay length -> begin upload (start). SERV
                // reads BOOT_LEN to consume it, which CLEARS start -- so an overlay
                // can jump back to the bootloader and it re-arms for the next upload
                // (without this it would re-trigger on the stale length and hang).
                if (wb_we_i && wb_adr_i == ADDR_BOOT_LEN) begin
                    boot_len   <= `WRAP_SIM(#1) wb_dat_i;
                    boot_start <= `WRAP_SIM(#1) 1'b1;
                end else if (!wb_we_i && wb_adr_i == ADDR_BOOT_LEN) begin
                    boot_start <= `WRAP_SIM(#1) 1'b0;
                end
                // host writes a word -> pending; SERV reads it -> consumed.
                // (the arbiter serializes the bus, so write-set and read-clear of
                // the same address never collide.)
                if (wb_we_i && wb_adr_i == ADDR_BOOT_DATA) begin
                    boot_data    <= `WRAP_SIM(#1) wb_dat_i;
                    boot_pending <= `WRAP_SIM(#1) 1'b1;
                end else if (!wb_we_i && wb_adr_i == ADDR_BOOT_DATA) begin
                    boot_pending <= `WRAP_SIM(#1) 1'b0;
                end
            end
        end
    end

`ifdef FORMAL
    // ---- Formal verification (yosys k-induction; see sby/CMakeLists.txt and
    // sby/wb_sysregs.sby). Properties reference the internal uptime/uptime_latch.
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

`ifdef SBY_COVER
    // Cover-only (SBY): start from a genuine reset so the covers are reached
    // through real operation (a 0xFA write, the counter ticking) rather than a
    // hand-picked initial state. Kept OUT of the k-induction proof: a start-only
    // assumption is unsound in the inductive step.
    always @(posedge clk)
        if (!f_past_valid)
            assume (!reset_n);
`endif

    always @(posedge clk) begin
        // --- combinational read decode: correct for EVERY address, whether or
        // not this slave is selected (the interconnect muxes on the strobe) ---
        assert (wb_ack_o == (wb_stb_i & wb_cyc_i));     // single-cycle ack
        if (wb_adr_i == ADDR_MAGIC)
            assert (wb_dat_o == {8'h00, STATUS_MAGIC});
        if (wb_adr_i == ADDR_UPTIME_HI)
            assert (wb_dat_o == {8'h00, uptime[15:8]});
        if (wb_adr_i == ADDR_UPTIME_LO)
            assert (wb_dat_o == {8'h00, uptime_latch[7:0]});
        if (wb_adr_i == ADDR_HEALTH)
            assert (wb_dat_o == {11'd0, wd_health});
        if (wb_adr_i == ADDR_HEARTBEAT)
            assert (wb_dat_o == heartbeat);
        if (wb_adr_i == ADDR_BOOT_LEN)
            assert (wb_dat_o == boot_len);
        if (wb_adr_i == ADDR_BOOT_DATA)
            assert (wb_dat_o == boot_data);
        if (wb_adr_i == ADDR_BOOT_STATUS)
            assert (wb_dat_o == {14'd0, boot_start, boot_pending});
        if (wb_adr_i != ADDR_MAGIC && wb_adr_i != ADDR_UPTIME_HI &&
            wb_adr_i != ADDR_UPTIME_LO && wb_adr_i != ADDR_HEALTH &&
            wb_adr_i != ADDR_HEARTBEAT && wb_adr_i != ADDR_BOOT_LEN &&
            wb_adr_i != ADDR_BOOT_DATA && wb_adr_i != ADDR_BOOT_STATUS)
            assert (wb_dat_o == 16'h0000);              // incl 0xFA + unowned

        // heartbeat changes only on a write to its own address
        if (f_past_valid && reset_n && $past(reset_n) && heartbeat != $past(heartbeat))
            assert ($past(sel) && $past(wb_we_i) && $past(wb_adr_i) == ADDR_HEARTBEAT);

        // boot mailbox flags move only on their defined accesses:
        if (f_past_valid && reset_n && $past(reset_n)) begin
            // start sets on a BOOT_LEN write, clears on a BOOT_LEN read (re-arm)
            if (boot_start && !$past(boot_start))
                assert ($past(sel) && $past(wb_we_i) && $past(wb_adr_i) == ADDR_BOOT_LEN);
            if (!boot_start && $past(boot_start))
                assert ($past(sel) && !$past(wb_we_i) && $past(wb_adr_i) == ADDR_BOOT_LEN);
            // pending sets on a BOOT_DATA write, clears on a BOOT_DATA read
            if (boot_pending && !$past(boot_pending))
                assert ($past(sel) && $past(wb_we_i) && $past(wb_adr_i) == ADDR_BOOT_DATA);
            if (!boot_pending && $past(boot_pending))
                assert ($past(sel) && !$past(wb_we_i) && $past(wb_adr_i) == ADDR_BOOT_DATA);
        end

        // --- sequential invariants (only while running, i.e. no reset edge) ---
        if (f_past_valid && reset_n && $past(reset_n)) begin
            // uptime is monotonic: it can only hold or step by exactly one
            // (so a host that sees it move never sees a spurious jump/backstep,
            // except the genuine wrap, which is +1 mod 2^16). Inductive for any
            // UPTIME_DIV -- no need to unroll to a tick.
            assert (uptime == $past(uptime) || uptime == ($past(uptime) + 16'd1));

            // uptime_latch only changes on a high-byte read, capturing live uptime
            if (uptime_latch != $past(uptime_latch)) begin
                assert ($past(sel) && !$past(wb_we_i) && $past(wb_adr_i) == ADDR_UPTIME_HI);
                assert (uptime_latch == $past(uptime));
            end

            // cam_reinit pulses ONLY in response to a 0xFA write with bit0 set
            if (cam_reinit)
                assert ($past(sel) && $past(wb_we_i) &&
                        $past(wb_adr_i) == ADDR_REINIT && $past(wb_dat_i[0]));
        end
    end

    // reachability (cover task; run with a small UPTIME_DIV so a tick is in reach)
    always @(posedge clk) begin
        cover (cam_reinit);
        cover (uptime != 16'h0000);        // the uptime counter actually ticked
        cover (uptime_latch != 16'h0000);  // a high-byte read latched a value
    end
`endif

endmodule
