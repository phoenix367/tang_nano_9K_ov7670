// Formal harness for the round-robin `arbiter` (src/arbiter.v, Kendall Correll's
// tree arbiter). Kept SEPARATE from the third-party RTL so that file stays
// pristine -- this wrapper instantiates the arbiter at a fixed width and states
// the properties. Proven with yosys (built-in SAT, k-induction) via
// sby/CMakeLists.txt -> `ctest -L formal`; sby/arbiter.sby runs the same under
// SBY + an SMT solver for cover/BMC traces.
//
// Width 4 exercises the full node tree and a non-trivial round-robin order; the
// deployed instance (video_controller's PSRAM arbiter) is width 2, a subcase.
//
// Properties:
//   * MUTUAL EXCLUSION -- the registered `grant` is at most one-hot. This is the
//     core correctness claim ("never assert an invalid grant, even mid-transition").
//   * GRANT FOLLOWS REQUEST -- a registered grant lane was requesting last cycle
//     (the node masks grant by req; the output is one register delayed).
//   * GRANT NEEDS ENABLE -- no grant unless `enable` was high last cycle.
//   * SELECT TRACKS GRANT -- when a lane is granted, `select` is its index.
//   * Liveness (bounded, cover-style): both/all lanes can be granted over time.

`default_nettype none

module arbiter_formal #(
    parameter WIDTH = 4,
    parameter SELW  = 2
) (
    input  wire             clock,
    input  wire             reset,
    input  wire             enable,
    input  wire [WIDTH-1:0] req
);
    wire [WIDTH-1:0] grant;
    wire [SELW-1:0]  select;
    wire             valid;

    arbiter #(.width(WIDTH), .select_width(SELW)) dut (
        .enable(enable),
        .req(req),
        .grant(grant),
        .select(select),
        .valid(valid),
        .clock(clock),
        .reset(reset)
    );

    // $past is meaningless before the first clock and right after reset.
    // The arbiter's outputs are only defined after power-up/reset clears the
    // grant/state/select registers, so the proof is run with `-set-init-zero`
    // (FFs power up to 0, matching `reset` and real Gowin power-up); without that
    // the solver could start `grant` in an arbitrary, non-one-hot state.
    reg f_past_valid = 1'b0;
    always @(posedge clock) f_past_valid <= 1'b1;

    integer i;
    reg [31:0] grant_count;   // popcount of grant, for the one-hot check

    always @(posedge clock) begin
        // ---- 1) mutual exclusion: at most one grant bit set, every cycle ----
        grant_count = 0;
        for (i = 0; i < WIDTH; i = i + 1)
            grant_count = grant_count + grant[i];
        assert (grant_count <= 1);

        if (f_past_valid && !$past(reset)) begin
            // ---- 2) a registered grant lane was requested last cycle ----
            assert ((grant & ~$past(req)) == {WIDTH{1'b0}});

            // ---- 3) no grant unless enable was asserted last cycle ----
            if (|grant)
                assert ($past(enable));

            // ---- 4) select points at the granted lane (when one is granted) ----
            if (|grant)
                assert (grant[select]);
        end
    end

    // ---- reachability (cover): the arbiter can actually grant each lane, and
    // can hand off between lanes (round-robin makes progress) ----
    always @(posedge clock) begin
        cover (grant[0]);
        cover (grant[WIDTH-1]);
        if (f_past_valid)
            cover (|grant && $past(|grant) && (grant != $past(grant)));  // a hand-off
    end

endmodule

`default_nettype wire
