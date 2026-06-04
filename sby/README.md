# Formal verification (SymbiYosys / SBY)

Formal property checks for the project's self-contained, single-clock control
modules, complementing the Icarus testbenches under [`sim/`](../sim). Each `.sby`
file drives [SymbiYosys](https://github.com/YosysHQ/sby) over one module; the
properties themselves live in the RTL behind `` `ifdef FORMAL `` so synthesis
(Gowin) and the Icarus sims never see them.

## Toolchain

SBY ships in the **OSS CAD Suite** (bundles `yosys`, `sby`, `sv2v`, and SMT
solvers — `yices`, `boolector`, `z3`). Download a release for your platform from
<https://github.com/YosysHQ/oss-cad-suite-build/releases>, extract it, and add it
to `PATH`:

```sh
# example
tar xzf oss-cad-suite-linux-x64-*.tgz
source oss-cad-suite/environment   # or: export PATH=$PWD/oss-cad-suite/bin:$PATH
yosys --version && sby --version    # sanity check
```

## Running

From the repo root:

```sh
sby -f sby/wb_interconnect.sby        # run all tasks (bmc + cover)
sby -f sby/wb_interconnect.sby bmc    # assertions only
sby -f sby/wb_interconnect.sby cover  # reachability covers only
```

`-f` overwrites the previous work directory (`sby/wb_interconnect/`). A clean run
ends with `PASS`; on failure SBY writes a counterexample trace (`.vcd`) under the
work directory.

### Without SBY — yosys built-in SAT (no SMT solver needed)

`wb_interconnect` is purely combinational, so its assertions can be proven
**exhaustively** with just `yosys` (no `sby`, no external SMT solver) via the
built-in SAT solver. This is the form that runs today (verified PASS on
Yosys 0.33):

```sh
yosys -p "read_verilog -sv -formal -DFORMAL src/modbus/wb_interconnect.sv; \
          prep -top wb_interconnect; \
          chformal -cover -remove; \
          sat -verify -prove-asserts -show-all"
```

`chformal -cover -remove` drops the `cover()` cells (the `sat` pass only consumes
asserts); `-verify` makes yosys exit non-zero if any property fails, so it slots
straight into CI. A clean run prints `SAT proof finished - no model found:
SUCCESS!`. The `cover()` reachability is meanwhile demonstrated concretely by the
simulation test `sim/unit/wb_interconnect/decode.sv`, which exercises every
routing path (sccb / sysregs / grab-reg / stream / osd / unmapped).

This SAT shortcut works only for combinational (or shallow) properties; the
sequential FSM slaves below will need `sby` (BMC / k-induction) and a solver.

## What's covered

| `.sby` | DUT | Kind | Properties |
| ------ | --- | ---- | ---------- |
| `wb_interconnect.sby` | `src/modbus/wb_interconnect.sv` | combinational, depth-1 BMC (exhaustive) | decode matches the register map; strobes mutually exclusive; every active access claimed by exactly one path (no bus hang); default-ack with 0 for unmapped addresses; ack/data routed from the selected slave |

This is the pilot. Good next candidates (single-clock, no Gowin IP): `arbiter`
(round-robin mutual exclusion + fairness), `watchdog` (sticky hang, bounded
timeout), and the FSM bus slaves `wb_sysregs` / `wb_osd` / `wb_grab`. Modules that
instantiate Gowin IP or cross clock domains (`psram_ch1`, the video path) need the
IP black-boxed and clock abstraction first.

> Note: these targets are not yet wired into CTest (the toolchain isn't assumed
> present). Once OSS CAD Suite is on the CI/dev path, a `formal` CTest label gated
> on tool detection — mirroring how `Gowin_PATH` gates the `hw_*` targets — is the
> natural next step.
