`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`elsif FORMAL
// formal (SymbiYosys/yosys): only WRAP_SIM is needed from the project headers and
// it is a no-op outside Icarus -- define it empty so the read is self-contained.
`define WRAP_SIM(x)
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`default_nettype wire

// Wishbone B4 classic-standard slave: channel-1 frame grab + streaming download.
//
// Split out of the old monolithic modbus_cam_backend. Owns:
//   * 0xF3 -> write 1 = arm grab, 2 = read-trigger; read: [0]=busy [1]=calib
//   * 0xF4 -> write: ch1 read addr [15:0]
//   * 0xF5 -> write: ch1 read addr [20:16]
//   * 0xF6 -> read: ch1 word [31:16]
//   * 0xF7 -> read: ch1 word [15:0]
//   * 0xF8 -> write: rewind the download stream to ch1 pixel 0
//   * >= 0x1000 (read) -> the next 16-bit pixel of the captured frame; the pointer
//     advances so a host walks the whole frame with back-to-back FC03 bursts.
//
// Two response timings behind one Wishbone slave:
//   * register accesses (F3..F8) take a fixed 1-wait-state path (G_IDLE -> S_RESP);
//   * a stream read fetches a full 8-word (16-pixel) ch1 burst the first time, then
//     drains 16 pixels from the buffer before the next fetch. While fetching, the
//     slave HOLDS wb_ack_o low (classic-standard wait states) so the master stalls,
//     exactly as the old monolith held be_ready low.
//
// wb_ack_o is a Moore output asserted only in S_RESP (one cycle); wb_dat_o is
// registered and stable while acked. Writes to >= 0x1000 never reach this slave
// (the interconnect routes only stream READs here and acks stray writes itself),
// so the stream band is read-only by construction.

module wb_grab (
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

    // channel-1 PSRAM bring-up loopback (to/from psram_ch1 via VGA_timing)
    output reg         grab_arm,        // pulse: capture the next frame into ch1
    output reg         grab_rd_req,     // pulse: read the ch1 burst at grab_rd_addr
    output reg [20:0]  grab_rd_addr,    // ch1 read address (burst-aligned)
    input  wire        grab_busy,
    input  wire [255:0] grab_rd_data,   // full 8-word burst returned by a ch1 read
    input  wire        grab_calib
);
    localparam [15:0] ADDR_GRAB      = 16'h00F3,
                      ADDR_RDADDR_LO = 16'h00F4,
                      ADDR_RDADDR_HI = 16'h00F5,
                      ADDR_RDDATA_HI = 16'h00F6,
                      ADDR_RDDATA_LO = 16'h00F7,
                      ADDR_STREAM    = 16'h00F8,
                      STREAM_BASE    = 16'h1000;

    localparam [20:0] BSTEP = 21'd16;                // ch1 burst-address increment

    localparam [2:0]
        G_IDLE   = 3'd0,
        S_FETCH0 = 3'd1,   // pulse grab_rd_req for the burst at s_baddr
        S_FETCH1 = 3'd2,   // wait for grab_busy to assert
        S_FETCH2 = 3'd3,   // wait for grab_busy to deassert, capture the burst
        S_SERVE  = 3'd4,   // latch the current 16-bit pixel, advance the pointer
        S_RESP   = 3'd5;   // assert ack for one cycle

    reg [2:0] state;

    // ---- streaming download pointer (one pixel per backend read) ----
    reg [20:0]  s_baddr;        // ch1 burst address of the buffered burst
    reg [2:0]   s_widx;         // current 32-bit word within the burst (0..7)
    reg         s_half;         // 0 = low pixel [15:0], 1 = high pixel [31:16]
    reg         s_loaded;       // s_burst holds the burst at s_baddr
    reg [255:0] s_burst;        // buffered 8-word burst
    wire [31:0] s_word = s_burst[s_widx*32 +: 32];

    wire sel       = wb_stb_i & wb_cyc_i;
    wire is_stream = sel & ~wb_we_i & (wb_adr_i >= STREAM_BASE);

    // Moore ack: one cycle in S_RESP only.
    assign wb_ack_o = (state == S_RESP);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state        <= `WRAP_SIM(#1) G_IDLE;
            wb_dat_o     <= `WRAP_SIM(#1) 16'h0000;
            grab_arm     <= `WRAP_SIM(#1) 1'b0;
            grab_rd_req  <= `WRAP_SIM(#1) 1'b0;
            grab_rd_addr <= `WRAP_SIM(#1) 21'd0;
            s_baddr      <= `WRAP_SIM(#1) 21'd0;
            s_widx       <= `WRAP_SIM(#1) 3'd0;
            s_half       <= `WRAP_SIM(#1) 1'b0;
            s_loaded     <= `WRAP_SIM(#1) 1'b0;
            s_burst      <= `WRAP_SIM(#1) 256'd0;
        end else begin
            grab_arm    <= `WRAP_SIM(#1) 1'b0;   // 1-cycle pulse defaults
            grab_rd_req <= `WRAP_SIM(#1) 1'b0;

            case (state)
                G_IDLE: begin
                    if (sel) begin
                        if (is_stream) begin
                            // frame download: serve from buffer or fetch a burst
                            state <= `WRAP_SIM(#1) s_loaded ? S_SERVE : S_FETCH0;
                        end else begin
                            // register access (F3..F8): single wait-state response
                            case (wb_adr_i)
                                ADDR_GRAB: begin
                                    wb_dat_o <= `WRAP_SIM(#1) {14'd0, grab_calib, grab_busy};
                                    if (wb_we_i) begin
                                        if (wb_dat_i[1:0] == 2'd1) grab_arm    <= `WRAP_SIM(#1) 1'b1;
                                        if (wb_dat_i[1:0] == 2'd2) grab_rd_req <= `WRAP_SIM(#1) 1'b1;
                                    end
                                end
                                ADDR_RDADDR_LO: begin
                                    wb_dat_o <= `WRAP_SIM(#1) 16'd0;
                                    if (wb_we_i) grab_rd_addr[15:0] <= `WRAP_SIM(#1) wb_dat_i;
                                end
                                ADDR_RDADDR_HI: begin
                                    wb_dat_o <= `WRAP_SIM(#1) 16'd0;
                                    if (wb_we_i) grab_rd_addr[20:16] <= `WRAP_SIM(#1) wb_dat_i[4:0];
                                end
                                ADDR_RDDATA_HI:
                                    wb_dat_o <= `WRAP_SIM(#1) grab_rd_data[31:16];
                                ADDR_RDDATA_LO:
                                    wb_dat_o <= `WRAP_SIM(#1) grab_rd_data[15:0];
                                ADDR_STREAM: begin
                                    // rewind the download stream to ch1 pixel 0
                                    wb_dat_o <= `WRAP_SIM(#1) 16'd0;
                                    if (wb_we_i) begin
                                        s_baddr  <= `WRAP_SIM(#1) 21'd0;
                                        s_widx   <= `WRAP_SIM(#1) 3'd0;
                                        s_half   <= `WRAP_SIM(#1) 1'b0;
                                        s_loaded <= `WRAP_SIM(#1) 1'b0;
                                    end
                                end
                                default:
                                    wb_dat_o <= `WRAP_SIM(#1) 16'd0;
                            endcase
                            state <= `WRAP_SIM(#1) S_RESP;
                        end
                    end
                end

                // ---- streaming burst fetch (holds ack low: master stalls) ----
                S_FETCH0: begin
                    grab_rd_addr <= `WRAP_SIM(#1) s_baddr;
                    grab_rd_req  <= `WRAP_SIM(#1) 1'b1;     // 1-cycle pulse
                    state        <= `WRAP_SIM(#1) S_FETCH1;
                end
                S_FETCH1: if (grab_busy) state <= `WRAP_SIM(#1) S_FETCH2;
                S_FETCH2: if (!grab_busy) begin
                    s_burst  <= `WRAP_SIM(#1) grab_rd_data;
                    s_loaded <= `WRAP_SIM(#1) 1'b1;
                    state    <= `WRAP_SIM(#1) S_SERVE;
                end

                S_SERVE: begin
                    // latch the current pixel, then advance the pointer
                    wb_dat_o <= `WRAP_SIM(#1) s_half ? s_word[31:16] : s_word[15:0];
                    if (!s_half) begin
                        s_half <= `WRAP_SIM(#1) 1'b1;
                    end else begin
                        s_half <= `WRAP_SIM(#1) 1'b0;
                        if (s_widx == 3'd7) begin     // burst drained -> next burst
                            s_widx   <= `WRAP_SIM(#1) 3'd0;
                            s_baddr  <= `WRAP_SIM(#1) s_baddr + BSTEP;
                            s_loaded <= `WRAP_SIM(#1) 1'b0;
                        end else
                            s_widx <= `WRAP_SIM(#1) s_widx + 3'd1;
                    end
                    state <= `WRAP_SIM(#1) S_RESP;
                end

                S_RESP:  // ack asserted (combinational) this cycle; return to idle
                    state <= `WRAP_SIM(#1) G_IDLE;

                default: state <= `WRAP_SIM(#1) G_IDLE;
            endcase
        end
    end

`ifdef FORMAL
    // ---- Formal verification (yosys k-induction + SBY liveness; see
    // sby/CMakeLists.txt, sby/wb_grab*.sby). ----
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    always @(posedge clk) begin
        // ack is a Moore output, high only in S_RESP; state is always defined
        assert (wb_ack_o == (state == S_RESP));
        assert (state <= S_RESP);

        if (f_past_valid && reset_n && $past(reset_n)) begin
            // ack and the ch1 control pulses are single-cycle (never held two
            // cycles -> psram_ch1 is never spuriously re-triggered, master sees
            // exactly one ack per access)
            assert (!(wb_ack_o    && $past(wb_ack_o)));
            assert (!(grab_arm    && $past(grab_arm)));
            assert (!(grab_rd_req && $past(grab_rd_req)));

            // FSM progress: every state advances deterministically EXCEPT the two
            // fetch waits, which advance exactly when grab_busy moves. So the only
            // way to stall is the ch1 engine (the environment), never the FSM.
            if ($past(state) == S_FETCH0)                      assert (state == S_FETCH1);
            if ($past(state) == S_FETCH1 &&  $past(grab_busy)) assert (state == S_FETCH2);
            if ($past(state) == S_FETCH1 && !$past(grab_busy)) assert (state == S_FETCH1);
            if ($past(state) == S_FETCH2 && !$past(grab_busy)) assert (state == S_SERVE);
            if ($past(state) == S_FETCH2 &&  $past(grab_busy)) assert (state == S_FETCH2);
            if ($past(state) == S_SERVE)                       assert (state == S_RESP);
            if ($past(state) == S_RESP)                        assert (state == G_IDLE);

            // stream pointer: finishing the 16th pixel of a burst (high half of
            // word 7) advances to the next burst and marks the buffer empty
            if ($past(state) == S_SERVE && $past(s_half) && $past(s_widx) == 3'd7) begin
                assert (s_widx   == 3'd0);
                assert (s_baddr  == ($past(s_baddr) + BSTEP));
                assert (s_loaded == 1'b0);
            end
        end
    end

`ifdef SBY_LIVE
    // ---- Full temporal liveness (SBY `mode live`). The conditional-progress
    // asserts above already prove there is no INTERNAL deadlock -- the only stalls
    // are the two grab_busy waits. This block adds the temporal closure: given a
    // fair ch1 engine (grab_busy does not stay stuck in either wait), the slave
    // ALWAYS eventually returns to idle. Requires an aiger liveness engine
    // (suprove / avy, e.g. from OSS CAD Suite) -- not run by `ctest -L formal`
    // (yosys's built-in SAT does safety only). See sby/README.md.
    always @(posedge clk) begin
        assume (s_eventually ((state != S_FETCH1) ||  grab_busy));
        assume (s_eventually ((state != S_FETCH2) || !grab_busy));
        assert (s_eventually (state == G_IDLE));
    end
`endif
`endif

endmodule
