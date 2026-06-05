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

- **featurize** — an 8-neighbour **Local Binary Pattern**. The 22×14 ROI is
  2×2 block-averaged to an 11×7 brightness grid, then each interior cell emits 8
  bits (`neighbour ≥ centre`, in order TL,T,TR,L,R,BL,B,BR) → 45 cells × 8 = **360
  boolean features**. LBP is relative to each local neighbourhood, so it captures
  texture/edge structure and is robust to overall lighting. Integer compares only —
  no multiply/divide/float, so the overlay is libgcc-free.
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

## Baseline (does the pipeline even work?)

Before any on-device capture, [`baseline_dataset.py`](baseline_dataset.py) converts
public datasets into the **exact device format** (22×14 RGB565 patches, same JSONL)
so `train_tm.py` trains on them unchanged. Two source pairs:

```
# easy: clean lab faces vs crops of two natural photos
.venv/bin/python demo_mcu_apps/roi_tm/baseline_dataset.py -o demo_mcu_apps/roi_tm/samples_baseline.jsonl
# hardened: LFW faces-in-the-wild vs CIFAR-10 (diverse scenes + animal-face hard negatives)
.venv/bin/python demo_mcu_apps/roi_tm/baseline_dataset.py --hard -o demo_mcu_apps/roi_tm/samples_hard.jsonl
.venv/bin/python demo_mcu_apps/roi_tm/train_tm.py -i <dataset> --header /tmp/tm.h --model /tmp/tm.json
```

| dataset | face / no-face | 5-fold CV (64 clauses) |
| --- | --- | --- |
| easy   | Olivetti / 2-photo crops | **0.979 ± 0.008** |
| hard   | LFW / CIFAR-10           | **0.944 ± 0.013** |

The LBP features are clearly learnable at 22×14. More clauses help on the hard set
(holdout: 64→0.93, 128→0.95, 200→0.965) but the masks grow `clauses × 23 × 4` B and
must fit the ~15 KB overlay RAM — so **64 is the safe default, ~128 the practical
ceiling** (~12 KB masks); 200 (18 KB) needs a bigger MCU RAM build. These are still
*optimistic* (cropped/centred faces, dataset backgrounds ≠ your room); real accuracy
needs `collect_samples.py` captures. Both downloads + `scikit-learn`/`pillow` are dev
requirements (LFW ≈200 MB, CIFAR ≈170 MB, cached under the sklearn data home).

## Files

| File | Role |
| --- | --- |
| `tm_common.py` | featurize, the numpy TM (train + reference inference), bit-packing, header export — shared by trainer and tests. |
| `train_tm.py` | CLI: load `samples.jsonl` → train → evaluate → emit `tm_model.h` + `tm_model.json`. `--synthetic` self-tests the whole path. |
| `roi_tm.c` | SERV overlay: read ROI → featurize → bitwise TM inference → OSD label + heartbeat. |
| `tm_model.h` | **Generated.** Clause masks + sizes. A default (trained on synthetic data) is committed so the build works before you retrain — its face predictions are meaningless until you train on real captures. |
| `visualize_dataset.py` | Render a `samples*.jsonl` dataset: a colour PNG montage grouped by label (`--ascii` for terminal luma previews). Eyeball alignment / balance / mislabels. |
| `test_tm_pipeline.py` | Pure-host pipeline tests (no hardware). |

## Notes

- The committed `tm_model.h` is a **placeholder** from `--synthetic`. It builds and
  runs, but won't recognise faces until you collect data and retrain.
- The model is ~`TM_CLAUSES × TM_NWORDS × 4` bytes of `.rodata` (default 64×20×4 =
  5 KB), uploaded word-by-word through the bootloader mailbox — a one-time ~10 s
  upload. Bigger `--clauses` ⇒ larger/slower upload, more capacity.
- Changing the ROI size means retraining: `roi_tm.c` has a `#if TM_N != ROI_CELLS`
  guard that fails the build if `tm_model.h` no longer matches the geometry.
