# Formal verification (SymbiYosys / SBY)

Formal property checks for the project's self-contained, single-clock control
modules, complementing the Icarus testbenches under [`sim/`](../sim). Each `.sby`
file drives [SymbiYosys](https://github.com/YosysHQ/sby) over one module; the
properties themselves live in the RTL behind `` `ifdef FORMAL `` so synthesis
(Gowin) and the Icarus sims never see them.

## Toolchain

`sby`'s default `smtbmc` engine needs an **SMT solver** on `PATH` (yices, z3,
boolector, …). Installing `sby` alone is not enough — and the solver-free `abc`
engine is *not* a reliable substitute (it currently crashes on this yosys/sby
combo and does not support `cover` mode). If you don't have a solver, use the
yosys built-in SAT path below instead.

The simplest way to get everything is the **OSS CAD Suite** (bundles `yosys`,
`sby`, `sv2v`, and the SMT solvers). Download a release for your platform from
<https://github.com/YosysHQ/oss-cad-suite-build/releases>, extract it, and add it
to `PATH`:

```sh
# example
tar xzf oss-cad-suite-linux-x64-*.tgz
source oss-cad-suite/environment   # or: export PATH=$PWD/oss-cad-suite/bin:$PATH
yosys --version && sby --version    # sanity check
```

## Running

`wb_interconnect`'s proof is split across two fast paths (see the header comment
in `wb_interconnect.sby` for why):

**1. Safety assertions → yosys built-in SAT (the ctest target).** The module is
purely combinational, so the assertions are proven **exhaustively** by yosys's
built-in SAT solver in ~0.1 s — no `sby`, no external SMT solver. This is what
`ctest -L formal` runs:

```sh
ctest -L formal                       # via CMake (formal_wb_interconnect)
# or directly:
yosys -p "read_verilog -sv -formal -DFORMAL src/modbus/wb_interconnect.sv; \
          prep -top wb_interconnect; \
          chformal -cover -remove; \
          sat -verify -prove-asserts -show-all"
```

`chformal -cover -remove` drops the `cover()` cells (the `sat` pass only consumes
asserts); `-verify` makes yosys exit non-zero on failure. A clean run prints
`SAT proof finished - no model found: SUCCESS!`.

**2. Cover reachability → SBY + SMT solver.** Confirms every routing path is
exercisable (so the assertion proof isn't vacuous). From the repo root:

```sh
sby -f sby/wb_interconnect.sby        # cover task; PASS in <1 s with z3
```

`-f` overwrites the work directory. A clean run ends with `DONE (PASS)`; a failure
writes a `.vcd` trace under the work dir.

### Solver note (SAT vs SMT)

For this combinational bit-vector problem, **bit-level SAT massively outperforms
word-level SMT**: yosys `sat` proves the assertions in ~0.1 s, but z3 4.8.12's
assertion BMC did **not finish in 90 s**. Hence assertions go through yosys SAT
and only the (instant) `cover` reachability runs under SBY+z3. This SAT shortcut
applies to combinational / shallow properties; the **sequential** FSM slaves below
will genuinely need SBY (BMC / k-induction), where SMT is the right tool.

## What's covered

| `.sby` / target | DUT | Method | Properties |
| --------------- | --- | ------ | ---------- |
| `formal_wb_interconnect` (ctest, yosys SAT) | `src/modbus/wb_interconnect.sv` | combinational, exhaustive | decode matches the register map; strobes mutually exclusive; every active access claimed by exactly one path (no bus hang); default-ack with 0 for unmapped addresses; ack/data routed from the selected slave |
| `wb_interconnect.sby` (SBY+z3) | same | cover reachability | every routing path (sccb / sysregs / grab-reg / stream / osd / unmapped) is reachable |
| `formal_arbiter` (ctest, yosys SAT) | `src/arbiter.v` (width-4 via `arbiter_formal.sv`) | sequential, k-induction | `grant` always one-hot (mutual exclusion, even mid-transition); a grant lane was requested last cycle; no grant unless `enable` was high; `select` indexes the granted lane |
| `arbiter.sby` (SBY+z3) | same | cover reachability | each lane can be granted; the arbiter hands off between lanes (round-robin progress) |
| `formal_watchdog` (ctest, yosys SAT) | `src/watchdog.sv` (small-param via `watchdog_formal.sv`) | sequential, k-induction | `hang == OR(subsystem_hang)`; each subsystem-hang bit is sticky (no flapping); `monitoring` is sticky once armed; no hang before `monitoring` |
| `watchdog.sby` (SBY+z3) | same | cover reachability | `monitoring` arms, a subsystem actually times out (hang), and `blink` toggles — reached through a real reset→arm→timeout path |
| `formal_wb_sysregs` (ctest, yosys SAT) | `src/modbus/wb_sysregs.sv` | sequential, k-induction | single-cycle `ack == stb&cyc`; read decode correct for every address (magic / uptime hi/lo / health / default-0); uptime is monotonic (+1 or hold, any `UPTIME_DIV`); `uptime_latch` captures live uptime only on a hi-byte read; `cam_reinit` pulses only on a 0xFA write with bit0 |
| `wb_sysregs.sby` (SBY+z3) | same | cover reachability | `cam_reinit` fires (real 0xFA write), the uptime counter ticks, and a hi-byte read latches it — reached from a real reset (UPTIME_DIV shrunk via chparam) |
| `formal_wb_osd` (ctest, yosys SAT) | `src/modbus/wb_osd.sv` | sequential, k-induction | decode correctness; the clear-sweep address stays in-grid, blanks each cell, and ends + homes the cursor at the last cell; cursor auto-increment/wrap on a data write; `osd_enable` changes only on a 0xFB write. The 1020-cell sweep is proven correct **without unrolling 1020 cycles**. |

The CTest targets are gated on `yosys` being found (see the top-level
`CMakeLists.txt`); `ctest -L formal` runs them all.

| `formal_wb_grab` (ctest, yosys SAT) | `src/modbus/wb_grab.sv` | sequential, k-induction | Moore ack; ack + ch1 control pulses (`grab_arm`/`grab_rd_req`) are single-cycle; state always defined; **deterministic FSM progress** — every state advances, the only stalls are the two `grab_busy` fetch-waits (no internal deadlock); stream pointer advances a burst at the 16th pixel |

`wb_osd` and `wb_grab` have **no SBY cover task**: z3's word-level BMC can't handle
their wide signals (the 1020-cell comparisons / the 256-bit burst), timing out,
whereas yosys's bit-level SAT proves the asserts in ~0.2–1 s. Reachability is
instead demonstrated concretely by the sim tests `sim/unit/wb_osd/cursor.sv` and
`sim/unit/wb_grab/stream.sv`.

**Liveness.** The `wb_grab` safety proof already shows there is no *internal*
deadlock (progress is deterministic; the only stalls are the `grab_busy` waits).
Full *temporal* liveness — "given a fair ch1 engine, the slave always eventually
returns to idle" — is encoded behind `` `ifdef SBY_LIVE `` in `wb_grab.sv` using
`s_eventually`. It needs SBY `mode live` with an **aiger liveness engine
(`suprove`/`avy`, e.g. from OSS CAD Suite)**, which this dev env lacks, so it is
not part of the SAT-based `ctest -L formal` target.

All the clean single-clock, no-Gowin-IP modules are now covered. Remaining targets
(`psram_ch1`, the video datapath) instantiate Gowin IP and/or cross clock domains,
so they need the IP black-boxed and clock abstraction before they can be proven.
