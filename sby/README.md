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

The CTest targets are gated on `yosys` being found (see the top-level
`CMakeLists.txt`); `ctest -L formal` runs them all.

Good next candidates (single-clock, no Gowin IP): `watchdog` (sticky hang,
bounded timeout), and the FSM bus slaves `wb_sysregs` / `wb_osd` / `wb_grab`.
Modules that instantiate Gowin IP or cross clock domains (`psram_ch1`, the video
path) need the IP black-boxed and clock abstraction first.
