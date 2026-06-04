// Formal harness for the health `watchdog` (src/watchdog.sv).
//
// The shipped parameters (STARTUP=54M, TIMEOUT=13.5M cycles) are far too large to
// model-check, so this wrapper instantiates a SMALL instance — exactly what the
// simulation test sim/unit/watchdog/health.sv does — where a hang is reachable in
// a few dozen cycles. The properties are scale-invariant (stickiness / ordering),
// so proving them small proves the structure for any size.
//
// Proven by k-induction with yosys's built-in SAT (no solver) via
// sby/CMakeLists.txt -> `ctest -L formal`; sby/watchdog.sby runs the cover
// reachability under SBY + an SMT solver.
//
// SAFETY invariants (k-induction):
//   * hang == OR of the per-subsystem flags                      (consistency)
//   * each subsystem_hang bit is STICKY — never clears while running (no flapping)
//   * monitoring (armed) is sticky once set                      (grace ends once)
//   * a hang can only exist once monitoring is asserted          (no pre-arm hang)
// Reachability (cover, in the .sby): a hang actually latches, monitoring is
// reached, and blink toggles — so the proof is not vacuous and the dog can bite.

`default_nettype none

module watchdog_formal #(
    parameter integer STARTUP = 8,   // small grace
    parameter integer TIMEOUT = 4,   // small timeout
    parameter integer BLINK   = 2    // fast blink
) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire [2:0] beats
);
    wire       hang, blink, monitoring;
    wire [2:0] subsystem_hang;

    watchdog #(.STARTUP(STARTUP), .TIMEOUT(TIMEOUT), .BLINK(BLINK)) dut (
        .clk(clk),
        .reset_n(reset_n),
        .beats(beats),
        .hang(hang),
        .blink(blink),
        .subsystem_hang(subsystem_hang),
        .monitoring(monitoring)
    );

    // $past is meaningless before the first clock. Proven with -set-init-zero so
    // the FFs power up cleared (matching reset_n), which is the only defined start.
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

`ifdef SBY_COVER
    // Cover-only (SBY): start from a genuine reset so the cover statements are
    // reached through real operation (grace arming, then a timeout) rather than a
    // hand-picked initial state. Kept OUT of the k-induction proof: an assumption
    // that only holds at the start is unsound in the inductive step.
    always @(posedge clk)
        if (!f_past_valid)
            assume (!reset_n);   // reset asserted (active-low) in the first step
`endif

    always @(posedge clk) begin
        // 1) hang is exactly the OR of the per-subsystem sticky flags
        assert (hang == (|subsystem_hang));

        // 2) a hang can only exist once the startup grace has armed monitoring
        assert (monitoring || !hang);

        // "running normally" = not in reset this cycle nor last cycle, so the
        // async reset did not clear the state across the $past window.
        if (f_past_valid && reset_n && $past(reset_n)) begin
            // 3) per-subsystem hang is sticky: no bit goes 1 -> 0 while running
            assert ((~subsystem_hang & $past(subsystem_hang)) == 3'b000);

            // 4) monitoring is sticky: once armed, stays armed while running
            assert (!($past(monitoring) && !monitoring));
        end
    end

    // ---- reachability (cover task) ----
    always @(posedge clk) begin
        cover (monitoring);                 // the grace period ends
        cover (hang);                       // a subsystem actually times out
        cover (blink);                      // heartbeat reaches 1
        if (f_past_valid)
            cover (!blink && $past(blink));  // ... and toggles back to 0
    end

endmodule

`default_nettype wire
