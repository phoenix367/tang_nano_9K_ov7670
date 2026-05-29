---
name: hw-check
description: Run the full Gowin synthesis + place-and-route + bitstream flow (hw_all) and summarize the timing report. Use when the user asks to "check timing", "run hw_all", "build the bitstream", or to verify a change didn't regress Fmax / introduce new violations.
---

You are running the project's hardware build and reporting on the timing
quality. The flow is owned by `cmake --build build --target hw_all` (synth
+ PnR + bitstream); the timing report ends up at
`impl/pnr/camera_ov7670_tr_content.html`.

## Steps

1. **Snapshot the current timing summary** before rebuilding, if a report
   exists, so you can show a before/after diff:

   ```bash
   if [ -f impl/pnr/camera_ov7670_tr_content.html ]; then
       cp impl/pnr/camera_ov7670_tr_content.html /tmp/hw_check_prev_tr.html
   fi
   ```

2. **Run the build.** Do not background it — the user wants the result
   this turn:

   ```bash
   cmake --build build --target hw_all
   ```

   If the configure step is missing (build dir not present, CMakeCache.txt
   absent, or `cmake` errors with "could not load cache"), reconfigure
   with the standard arguments:

   ```bash
   cmake -S . -B build \
       -D IVerilog_PATH=/usr/bin \
       -D Gowin_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux/IDE
   ```

   If the build fails with `License verification failed Server not
   responding` (Gowin's license check), retry once before reporting.

3. **Surface synthesis warnings.** Scan
   `impl/pnr/camera_ov7670.log` for `WARN` / `ERROR` lines. The
   architectural-impact ones to call out explicitly:

   - `TA1132` — generated clock inferred but not declared (means a new
     gen clock appeared without `create_generated_clock` in the SDC).
   - `PR1014` — clock signal routed through generic resource (placement
     couldn't reach the dedicated clock tree).
   - Any `ERROR (TA2003)` — constraint targets an object that doesn't
     exist; the SDC change in this build silently no-op'd.

4. **Parse the timing report** by running the `parse_timing.py` script
   that ships with this skill (path is relative to the skill's base
   directory — adjust if your cwd differs). It pulls all of:

   - Endpoints analyzed, setup-violated, hold-violated counts.
   - Per-clock Max Frequency Summary (Constraint vs Actual Fmax, with an
     OK / TIGHT / FAIL flag at the 1.05× threshold).
   - Per-clock Total Negative Slack Summary (Setup / Hold TNS).
   - Worst 3 setup paths from the Setup Paths Table.
   - Worst negative-slack hold paths.
   - The belt-and-braces scan of the `*.timing_paths` critical-path file
     (step 5 below, now folded in).
   - A before/after delta table when `--prev` is supplied (step 6 below).

   ```bash
   python3 .claude/skills/hw-check/parse_timing.py \
       --prev /tmp/hw_check_prev_tr.html
   ```

   Drop `--prev` if no snapshot was taken in step 1. Both the report path
   (`--report`) and the critical-path file (`--timing-paths`) default to
   their `impl/pnr/` locations and rarely need overriding. Run
   `parse_timing.py --help` for the full argument list.

   (The critical-path scan and the before/after diff are both produced by
   this script now; no separate snippet.)

5. **Report.** Lead with a one-line verdict — one of:

   - `Timing clean.` — TNS = 0.000 across every named clock, every Fmax >
     1.05 × constraint, no relevant warnings.
   - `Timing met but tight.` — TNS = 0.000 but at least one clock has
     Fmax / constraint < 1.05.
   - `Regression.` — at least one clock's TNS went negative this run that
     was clean before, OR Fmax dropped more than 2 MHz on a clock that
     was already tight.
   - `Violations.` — non-zero TNS on at least one named clock (the
     headline "Setup Violated Endpoints" count alone doesn't count — it
     can be high while all named clocks pass; the per-clock TNS table is
     the source of truth).

   Then list, in order:

   - The Max Frequency Summary table.
   - Any non-zero TNS rows.
   - Worst 3 setup paths if any have negative slack; otherwise just note
     the best-slack value.
   - Synthesis warnings worth raising (TA1132 / PR1014 / TA2003).
   - Before/after deltas if a previous snapshot existed.

   Keep the prose tight — the user is asking for status, not a tour of
   the report.

## Notes for the agent

- **Don't commit anything.** The skill builds and reports. The user
  decides whether to commit the constraint or RTL change that triggered
  the run.
- **Don't re-run synthesis to "check"** — if the user asks for a quick
  status without an RTL change, point them at the existing report in
  `impl/pnr/` instead of rebuilding.
- The Gowin TNS table reports zero per named clock even when the raw
  "Setup Violated Endpoints" count is high — the residual count belongs
  to unconstrained inferred clocks. Always check both, but trust the
  per-clock TNS for the verdict.
- The three remaining hold violations inside
  `u_psram_top{0,1}/u_psram_init/calib_0_s0` are vendor-IP paths that
  can't be cleared from user SDC (documented in `src/camera_control.sdc`).
  Mention them only if their count changes.
