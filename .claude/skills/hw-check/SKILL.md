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

4. **Parse the timing report** with the Python snippet below. Pull:

   - Endpoints analyzed, setup-violated, hold-violated counts.
   - Per-clock Max Frequency Summary (Constraint vs Actual Fmax).
   - Per-clock Total Negative Slack Summary (Setup / Hold TNS).
   - Worst 3 setup paths from the Setup Paths Table.
   - Any hold paths with negative slack.

   ```bash
   python3 << 'PY'
   import re, html
   with open('impl/pnr/camera_ov7670_tr_content.html') as f:
       text = f.read()
   text = re.sub('<[^>]+>', '|', text)
   text = re.sub(r'\|+', '|', text)
   text = html.unescape(text)

   def grab_count(label):
       m = re.search(re.escape(label) + r'\|\s*\|(\d+)\|', text)
       return m.group(1) if m else "?"

   print("=== Endpoint counts ===")
   print(f"  Analyzed:        {grab_count('Numbers of Endpoints Analyzed')}")
   print(f"  Setup violated:  {grab_count('Numbers of Setup Violated Endpoints')}")
   print(f"  Hold violated:   {grab_count('Numbers of Hold Violated Endpoints')}")

   print("\n=== Max Frequency Summary ===")
   idx = text.find('Max Frequency Summary')
   end = text.find('Total Negative Slack', idx)
   block = text[idx:end]
   for m in re.finditer(
       r'\|\d+\|\s*\|([^|]+)\|\s*\|(Base|Generated)?\|?\s*\|?([0-9.]+)\(MHz\)\|\s*\|([0-9.]+)\(MHz\)\|\s*\|(\d+)\|',
       block):
       clk, _, constraint, fmax, levels = m.groups()
       fmax_f = float(fmax); cons_f = float(constraint)
       margin = fmax_f / cons_f
       flag = "  OK" if margin > 1.05 else ("  TIGHT" if margin > 1.0 else "  *** FAIL ***")
       print(f"  {clk.strip():40s} {cons_f:8.3f} -> {fmax_f:8.3f} MHz (x{margin:.2f}, {levels} levels){flag}")

   print("\n=== Total Negative Slack ===")
   idx = text.find('Total Negative Slack Summary')
   end = text.find('Path Slacks Table', idx)
   block = text[idx:end]
   for m in re.finditer(r'\|([^|]+)\|\s*\|(Setup|Hold)\|\s*\|(-?[0-9.]+)\|\s*\|(\d+)\|', block):
       clk, kind, tns, n = m.groups()
       if float(tns) != 0 or int(n) > 0:
           print(f"  {clk.strip():40s} {kind:5s} TNS={tns} ns over {n} endpoints  *** VIOLATION ***")
   print("  (entries with TNS=0 / 0 endpoints omitted)")

   print("\n=== Worst 3 setup paths ===")
   idx = text.find('Setup Paths Table')
   end = text.find('Hold Paths Table', idx)
   block = text[idx:end]
   paths = re.findall(
       r'\|\d+\|\s*\|(-?\d+\.\d{3})\|\s*\|([^|]+)\|\s*\|([^|]+)\|\s*\|([^|]+:\[[RF]\])\|\s*\|([^|]+:\[[RF]\])\|',
       block)
   for slack, fn, tn, fc, tc in paths[:3]:
       sign = " (VIOLATION)" if float(slack) < 0 else ""
       print(f"  slack={slack} ns  {fc.strip()} -> {tc.strip()}{sign}")
       print(f"    from: {fn.strip()}")
       print(f"    to:   {tn.strip()}")
   PY
   ```

5. **Check critical-path file** for any actual negative slack endpoints
   (a quick belt-and-braces against the HTML summary):

   ```bash
   awk '
   BEGIN { mode="" }
   /^=====$/ { mode=""; next }
   /^SETUP$/ { mode="SETUP"; getline s; if (s+0 < 0) setup++; next }
   /^HOLD$/  { mode="HOLD";  getline s; if (s+0 < 0) hold++;  next }
   END { printf "timing_paths file: setup<0 = %d, hold<0 = %d\n", setup+0, hold+0 }
   ' impl/pnr/camera_ov7670.timing_paths
   ```

6. **If a previous snapshot exists** (`/tmp/hw_check_prev_tr.html` from
   step 1), re-run the parsing snippet against it (substitute the path)
   and present a before/after delta table for the per-clock Fmax and the
   endpoint counts. Otherwise just present the absolute numbers.

7. **Report.** Lead with a one-line verdict — one of:

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
