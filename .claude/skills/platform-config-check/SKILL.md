---
name: platform-config-check
description: Audit that a platform.json parameter is wired through every component that needs it (generated SV header, RTL, host loader, web app + its form, sim tests, webapp tests, host-device tests, scripts, docs). Use after adding or changing a key in platform.json, or when the user asks whether all required components were updated for a config parameter. Not every component needs every parameter — the skill applies a per-kind expectation table.
---

You are auditing whether the platform configuration in `platform.json` is fully
wired through the codebase. `platform.json` is the single source of truth for the
frame geometry, system clock, Modbus identity, and UART framing; CMake bakes it
into `src/platform_config.vh` for the gateware, and `platform_config.py` (repo
root) loads the same file for the host. A new or changed parameter must reach
every component that depends on it — but **which** components depend on it varies
by the parameter's kind, so part of this job is judgment, not just grep.

## Steps

1. **Run the checker.** From the repo root:

   ```bash
   python3 .claude/skills/platform-config-check/check_platform_config.py
   ```

   Audit a specific key (e.g. the one just added) by passing it:

   ```bash
   python3 .claude/skills/platform-config-check/check_platform_config.py addr_limit
   ```

   It prints two things:
   - a **generation-chain** table (json → CMake → `platform_config.vh.in` → RTL),
   - a **reference map** of which component buckets mention each parameter,
   - a **Findings** list of hard problems.

2. **Treat the Findings as hard failures.** These are mechanical and
   unambiguous — fix every one:
   - `[DEAD]` — the key is in `platform.json` but nothing reads it (no CMake
     parse, no host loader constant). Either wire it up or remove it.
   - `[GAP]` — parsed in CMake but not emitted in `platform_config.vh.in`
     (the value is computed and thrown away). Add the `` `define `` to the
     template.
   - `[WARN]` — the macro is generated but never used in any RTL file. Either
     it's reserved for a pending change (note that) or the RTL wire-up is
     missing.

3. **Apply the expectation table to the reference map.** A blank (`—`) cell is
   only a problem if that bucket is **required** for the parameter's kind. Look
   up each changed parameter below; for every *required* bucket showing `—`,
   investigate it as a likely miss. Optional/`N/A` blanks are fine.

   | Parameter kind | Examples | Required buckets | Optional | N/A |
   |---|---|---|---|---|
   | **geometry** | `input_frame_width`, `screen_height`, `emit_row_size` | RTL, host-loader, docs | sim-tests | webapp, webapp-front, web-tests, device-tests, scripts |
   | **clock** | `sys_clk_hz` | RTL, host-loader, docs | sim-tests | webapp-front, web-tests, device-tests, scripts |
   | **connection identity / link** | `device_id`, `baud` | RTL, host-loader, webapp, webapp-front (connect form), web-tests, device-tests, scripts, docs | sim-tests | — |
   | **Modbus protocol limit** | `addr_limit`, `max_read_qty` | RTL, host-loader, webapp, docs | web-tests, device-tests, scripts | webapp-front |
   | **UART framing** | `data_bits`, `parity`, `stop_bits` | RTL, host-loader, webapp, device-tests, scripts, docs | web-tests, sim-tests | webapp-front |

   Rationale for the common `N/A`s:
   - **geometry / clock are not connection parameters** — they never appear in
     the web app's connect form or the Modbus host/device tests; the host only
     *exposes* them via the loader (for geometry math) and documents them.
   - **protocol limits and framing are not user-facing** — the connect form only
     offers port/baud/slave, so `addr_limit`/`max_read_qty`/`data_bits`/… should
     **not** be in `webapp-front`.
   - **`max_read_qty` is RTL-side** in practice: a spec-compliant master caps
     FC03 at 125 < the device's 127 ceiling, so there's no host request that
     exercises it — a host test for it is impossible, not missing.
   - **sim-tests** legitimately use their own small local geometries (e.g.
     23×17) and hardcoded params rather than the platform header, so a `—` there
     is expected; only add a sim reference if a test genuinely needs to track the
     real value.

4. **Verify before concluding.** The reference map follows ALL_CAPS re-exports
   (`DEFAULT_BAUD = UART_BAUD`) and `render_template()` kwargs (for the connect
   form) transitively, but it can still miss deeper indirection. Before
   declaring a required bucket missed, open the file and confirm — and before
   declaring one covered, sanity-check that the reference is the real wire-up and
   not a coincidental mention.

5. **Report.** Lead with a one-line verdict:
   - `Fully wired.` — no Findings, and every *required* bucket for each changed
     parameter is present.
   - `Gaps found.` — at least one Finding, or a required bucket is missing.

   Then list, per changed parameter, the required buckets that are missing (with
   the file that should be touched), and ignore the N/A blanks. If you fixed
   anything, re-run the checker and show the clean result.

## What "wired up" means per bucket

- **CMake** — a `platform_json_int/hex/enum("<key>" PLATFORM_<VAR>)` line.
- **vh.in** — a `` `define PLATFORM_<VAR> @PLATFORM_<VAR>@ `` in
  `src/platform_config.vh.in`.
- **RTL** — a `` `PLATFORM_<VAR> `` reference in a synthesizable `src/*.{v,sv}`.
- **host-loader** — `platform_config.py` reads `["<key>"]` and exports a constant.
- **webapp** — `webapp/*.py` (e.g. `modbus_client.py`, `app.py`) uses the host
  constant (often re-exported as `DEFAULT_*`).
- **webapp-front** — `webapp/templates/` / `webapp/static/` shows it (the connect
  form injects it via a `render_template` kwarg).
- **web-tests** — `webapp/tests/*.py` except the `test_device_*` files (fake
  slave, app/client tests).
- **device-tests** — `webapp/tests/test_device_hw.py` /
  `test_device_conformance.py`.
- **scripts** — `scripts/*.py` (`modbus_test.py`, `frame_grab.py`).
- **docs** — `doc/*.md`, `CLAUDE.md`, `README.md`.

## Notes for the agent

- **Don't edit anything from this skill by reflex.** It reports; if it finds a
  gap, fix the specific component, then re-run to confirm.
- The skill is read-only and fast — safe to run repeatedly while wiring a new
  parameter.
- If you add a genuinely new *kind* of parameter that doesn't fit the table
  above, decide its required buckets from first principles (is it gateware-only?
  a connection parameter the user sets? a host-only runtime knob?) and update
  this table so the next audit has the rule.
