`include "timescale.v"

`default_nettype wire

// Health watchdog for the video pipeline.
//
// Monitors an "activity heartbeat" from each of three subsystems and lights a
// status LED accordingly:
//   * LCD rendering        -- e.g. LCD_VSYNC (per displayed frame)
//   * memory subsystem     -- e.g. PSRAM rd_data_valid | cmd_en (per access)
//   * OV7670 frame capture -- e.g. camera vsync (per captured frame)
//
// Each heartbeat is a free-running signal that toggles/pulses regularly while
// its subsystem is healthy. The three beats arrive on unrelated clock domains
// (screen_clk / fb_clk / pixel clk), so each is brought into `clk` with a
// CDC_Bit_Synchronizer (from FPGADesignElements) and edge-detected: any
// transition counts as activity and resets that subsystem's timeout counter.
// After a startup grace period (so the design has time to come out of reset /
// PSRAM calibration / first frame), a subsystem that shows no activity for
// TIMEOUT cycles latches a sticky hang flag.
//
//   hang  = any subsystem stalled (sticky until reset)
//   blink = free-running heartbeat (~clk / 2^(BLINK+1))
//
// Intended LED hookup on an active-low pin:
//   assign led = ~(hang | blink);   // blinks while healthy, solid-on on a hang
//
// `beats[0]` = LCD, `beats[1]` = memory, `beats[2]` = camera.

module watchdog #(
    parameter integer STARTUP = 54_000_000,  // grace before arming   (~2 s   @ 27 MHz)
    parameter integer TIMEOUT = 13_500_000,  // max gap between beats  (~0.5 s @ 27 MHz)
    parameter integer BLINK   = 23           // heartbeat bit: ~1.6 Hz @ 27 MHz
)
(
    input  wire       clk,
    input  wire       reset_n,
    input  wire [2:0] beats,           // {camera, memory, lcd} activity heartbeats
    output wire       hang,            // 1 once any monitored subsystem stalls (sticky)
    output wire       blink,           // healthy-state heartbeat for the LED
    output wire [2:0] subsystem_hang,  // sticky per-subsystem hang {camera, memory, lcd}
    output wire       monitoring       // armed: past the startup grace
);
    localparam integer CW = (TIMEOUT <= 1) ? 1 : $clog2(TIMEOUT + 1);
    localparam integer SW = (STARTUP <= 1) ? 1 : $clog2(STARTUP + 1);

    // ---- startup grace: don't flag hangs until the pipeline has had time to
    // come up (reset release, PSRAM calibration, first camera/LCD frame). ----
    reg [SW-1:0] start_cnt;
    reg          armed;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            start_cnt <= 'd0;
            armed     <= 1'b0;
        end else if (!armed) begin
            if (start_cnt >= STARTUP[SW-1:0]) armed <= 1'b1;
            else                              start_cnt <= start_cnt + 1'b1;
        end
    end
    assign monitoring = armed;

    // ---- one monitor per subsystem (subsystem_hang is the output port) ----
    genvar i;
    generate
        for (i = 0; i < 3; i = i + 1) begin : mon
            wire         synced;        // heartbeat brought into clk
            reg          synced_d;      // previous value, for edge detect
            reg [CW-1:0] cnt;           // cycles since last activity
            reg          tout;          // sticky timeout (hang) for this subsystem
            wire         active = synced ^ synced_d;   // any edge = activity

            // metastability-hardened CDC into clk (3 FF: depth 2 + 1 extra)
            CDC_Bit_Synchronizer #(.EXTRA_DEPTH(1)) beat_sync (
                .receiving_clock(clk),
                .bit_in(beats[i]),
                .bit_out(synced)
            );

            always @(posedge clk or negedge reset_n) begin
                if (!reset_n) begin
                    synced_d <= 1'b0;
                    cnt      <= 'd0;
                    tout     <= 1'b0;
                end else begin
                    synced_d <= synced;
                    if (!armed || active)            cnt  <= 'd0;       // healthy / pre-arm
                    else if (cnt >= TIMEOUT[CW-1:0]) tout <= 1'b1;      // stalled -> latch
                    else                             cnt  <= cnt + 1'b1;
                end
            end
            assign subsystem_hang[i] = tout;
        end
    endgenerate

    assign hang = |subsystem_hang;

    // ---- free-running heartbeat ----
    reg [BLINK:0] blink_cnt;
    always @(posedge clk or negedge reset_n)
        if (!reset_n) blink_cnt <= 'd0;
        else          blink_cnt <= blink_cnt + 1'b1;
    assign blink = blink_cnt[BLINK];

`ifdef FORMAL
    // ---- Formal verification (yosys k-induction; see sby/CMakeLists.txt,
    // sby/watchdog.sby). These invariants are scale-invariant -- they prove at the
    // shipped STARTUP/TIMEOUT counters; the .sby cover shrinks them via chparam so
    // a hang is reachable within BMC depth.
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

`ifdef SBY_COVER
    // cover-only: start from a real reset so covers reflect real operation
    // (arming, then a timeout) rather than a hand-picked initial state.
    always @(posedge clk) if (!f_past_valid) assume (!reset_n);
`endif

    always @(posedge clk) begin
        // hang is exactly the OR of the per-subsystem sticky flags
        assert (hang == (|subsystem_hang));
        // a hang can only exist once the startup grace has armed monitoring
        assert (monitoring || !hang);

        if (f_past_valid && reset_n && $past(reset_n)) begin
            // per-subsystem hang is sticky: no bit goes 1 -> 0 while running
            assert ((~subsystem_hang & $past(subsystem_hang)) == 3'b000);
            // monitoring is sticky: once armed, stays armed while running
            assert (!($past(monitoring) && !monitoring));
        end
    end

    // reachability (cover task; run from a real reset via SBY_COVER, params
    // shrunk via chparam so a hang is in reach)
    always @(posedge clk) begin
        cover (monitoring);                 // the grace period ends
        cover (hang);                       // a subsystem actually times out
        cover (blink);                      // heartbeat reaches 1
        if (f_past_valid)
            cover (!blink && $past(blink));  // ... and toggles back to 0
    end
`endif

endmodule
