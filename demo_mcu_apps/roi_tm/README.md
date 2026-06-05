# roi_tm — fixed-ROI face presence with a Tsetlin Machine

A trainable replacement for the unreliable skin-colour gate in `roi_presence`. The
camera's RGB565 skin rule doesn't separate faces from background robustly, so we
instead **learn** a face/no-face classifier for a *fixed* region of interest and run
it on the SERV soft core. A fixed ROI turns "find the face" (far too heavy for a
bit-serial core) into one cheap per-frame classification.

The classifier is a **Tsetlin Machine** (TM): inference is purely bitwise — each
clause is an AND of "included" literals, clauses vote ±1, and you threshold the
sum. No multiply, no divide, no floating point → it fits the bit-serial core with
room to spare (the model is a table of 32-bit clause masks).

## The loop

```
 ┌── collect_samples.py ──┐      ┌── train_tm.py ──┐      ┌── roi_tm.c ──┐
 │ label face/no-face ROI │ ───► │ train TM, export │ ──► │ bitwise infer │
 │  -> samples.jsonl      │      │  -> tm_model.h    │     │  on live ROI  │
 └────────────────────────┘      └───────────────────┘     └──────────────┘
        (roi_collect overlay        (host, numpy)            (SERV overlay)
         draws the box)
```

1. **Collect.** Upload the `roi_collect` overlay (draws the box, parks) and run
   [`../roi_collect/collect_samples.py`](../roi_collect/collect_samples.py). Align
   your face to the box and press `f`; clear the frame and press `n`. Aim for a few
   dozen of each, varied (distance, lighting, angle, different faces / backgrounds).
   Output: `../roi_collect/samples.jsonl`.

2. **Train.**
   ```
   .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py            # train on samples.jsonl
   .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py --clauses 96 --epochs 300
   ```
   Reports train/validation accuracy and writes **`tm_model.h`** (baked into the
   overlay) and `tm_model.json` (inspection). Needs `numpy`.

3. **Deploy.**
   ```
   cmake --build build --target serv_firmware     # compiles tm_model.h into roi_tm.bin
   ```
   Upload `build/serv_fw/roi_tm.bin` (web app Firmware tab, or `serv_boot_load`). The
   MCU draws the box, and a **"FACE"** label lights in the left border while a face
   is present. Heartbeat `0xE0` = `bit7 = present`, `bits[6:0] = vote + 64` (host
   decodes `vote = (0xE0 & 0x7F) - 64`).

## Why it stays in sync

[`tm_common.py`](tm_common.py) is the single source of truth for the three things
the host and MCU must agree on **bit-for-bit**:

- **featurize** — one bit per ROI cell, `b[i] > ROI mean`. The host writes it as
  `b[i]*N > sum`; the MCU computes `b[i] > sum / N` (integer floor division) — these
  are exactly equal for integer brightness (proven in the tests). The divide pulls in
  libgcc's `__divsi3` (~200 B; the overlay links with `-lgcc`); it runs once per
  frame, so it's free against the 308 PSRAM reads.
- **literal layout** — literal `k<N` is feature `k`, `k≥N` is its negation; bit `k`
  is in word `k>>5` at position `k&31`. Same packing in `pack_literals()` and the C.
- **voting** — clauses `0..TM_POS-1` vote +1, the rest −1; face when `vote ≥ TM_THRESHOLD`.

[`test_tm_pipeline.py`](test_tm_pipeline.py) locks this down: it reimplements
roi_tm.c's *integer* inference in Python and asserts it equals the numpy reference
(`infer_packed`) over many random inputs, checks the feature definition is
division-free-exact, round-trips the exported header, and confirms the TM learns a
separable problem. Run it with:

```
.venv/bin/python -m pytest demo_mcu_apps/roi_tm/test_tm_pipeline.py -v
```

## Files

| File | Role |
| --- | --- |
| `tm_common.py` | featurize, the numpy TM (train + reference inference), bit-packing, header export — shared by trainer and tests. |
| `train_tm.py` | CLI: load `samples.jsonl` → train → evaluate → emit `tm_model.h` + `tm_model.json`. `--synthetic` self-tests the whole path. |
| `roi_tm.c` | SERV overlay: read ROI → featurize → bitwise TM inference → OSD label + heartbeat. |
| `tm_model.h` | **Generated.** Clause masks + sizes. A default (trained on synthetic data) is committed so the build works before you retrain — its face predictions are meaningless until you train on real captures. |
| `test_tm_pipeline.py` | Pure-host pipeline tests (no hardware). |

## Notes

- The committed `tm_model.h` is a **placeholder** from `--synthetic`. It builds and
  runs, but won't recognise faces until you collect data and retrain.
- The model is ~`TM_CLAUSES × TM_NWORDS × 4` bytes of `.rodata` (default 64×20×4 =
  5 KB), uploaded word-by-word through the bootloader mailbox — a one-time ~10 s
  upload. Bigger `--clauses` ⇒ larger/slower upload, more capacity.
- Changing the ROI size means retraining: `roi_tm.c` has a `#if TM_N != ROI_CELLS`
  guard that fails the build if `tm_model.h` no longer matches the geometry.
