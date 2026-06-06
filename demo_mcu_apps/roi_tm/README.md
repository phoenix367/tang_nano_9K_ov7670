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
   .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py                       # train on samples.jsonl
   .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py --augment 3           # + luminance augmentation
   .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py --clauses 96 --epochs 300
   ```
   Reports train/validation accuracy and writes **`tm_model.h`** (baked into the
   overlay) and `tm_model.json` (inspection). Needs `numpy`.

   **`--augment N`** adds N photometric copies per training sample — random
   brightness, per-channel white-balance jitter, contrast, and horizontal flip (in
   RGB565 space, re-quantized). The colour features (especially the absolute
   `R−B≥2` skin cue) drift with exposure and the OV7670's wobbly AWB; augmenting
   across those makes the model robust to luminance instead of memorising the
   dataset's lighting. The committed model uses `--augment 3`. Validation stays
   clean (un-augmented), so the reported accuracy is honest.

3. **Deploy** — see the next section. (A trained `tm_model.h` is already committed,
   so you can deploy the demo *without* collecting/training first.)

## Deploy roi_tm to the device

`roi_tm` is a **host-uploaded SERV overlay** — no FPGA reflash needed, just a
SERV-enabled bitstream already on the board (`platform.json` `serv_mcu.enable=true`;
see [`../../doc/serv.md`](../../doc/serv.md)). The committed `tm_model.h` is a ready
model, so these steps work as-is.

1. **Build the overlay** (compiles the committed `tm_model.h` into the binary):
   ```
   cmake --build build --target serv_firmware     # -> build/serv_fw/roi_tm.bin (~3.9 KB)
   ```

2. **Upload it** to the SERV core, either:
   - **CLI** ([`scripts/serv_upload.py`](../../scripts/serv_upload.py) — uploads + resets
     the MCU into it via the bootloader mailbox; takes an overlay name or a `.bin` path):
     ```
     scripts/serv_upload.py -p /dev/ttyGowin roi_tm           # or --verify to watch 0xE0
     ```
   - **Web app:** the **Firmware** tab → select `build/serv_fw/roi_tm.bin` → Upload.

   (Free the serial port first — stop the web app if it holds `/dev/ttyGowin`.)

3. **Use it.** The overlay draws the ROI box on the LCD; align your face to it. The
   left border shows the live result: **"FACE"/"----"**, **"FPS NN"** (processing
   rate — loop iterations/sec, ~12 fps), and the confidence as two clause tallies
   **"F NN N NN"** — `F` = face clauses that fired, `N` = non-face clauses; the gap
   between them is how decisive the call is (net vote = F − N). The heartbeat
   register `0xE0` encodes the result: `bit7 = present`, `bits[6:0] = vote + 64`
   (decode `vote = (0xE0 & 0x7F) - 64`). `serv_upload.py ... --verify` prints `0xE0`
   for a few seconds; or watch it live:
   ```
   .venv/bin/python -c "import sys,time; sys.path.insert(0,'webapp'); \
     from modbus_client import ModbusRTU,REG_HEARTBEAT as H; mb=ModbusRTU('/dev/ttyGowin'); \
     [print('vote',(mb.read_reg(H)&0x7F)-64,'present',mb.read_reg(H)>>7) or time.sleep(0.4) for _ in range(40)]"
   ```
   Empty scene → a clearly negative vote (no-face); face filling the box → vote rises
   past `TM_THRESHOLD` (+4) → `present=1`. A valid live heartbeat decodes to a vote in
   `[-32, +32]`; `0x00` (vote −64) means the overlay isn't running (MCU still in the
   bootloader) — re-upload.

The hardware smoke test `test_serv_roi_tm` in
[`../../webapp/tests/test_device_hw.py`](../../webapp/tests/test_device_hw.py) also
uploads and checks it (`OV7670_PORT=/dev/ttyGowin OV7670_SERV=1 pytest -k roi_tm`).

## The committed model (exact recipe)

The `tm_model.h` checked in here was trained as follows (the header's first comment
line records the same provenance):

**Dataset** — the Kaggle *Face Detection Dataset* (fareselmenshawii,
<https://www.kaggle.com/datasets/fareselmenshawii/face-detection-dataset>), a
YOLO-format set (`images/` + `labels/`, class 0 = face). Converted to the device's
22×14 RGB565 ROI format with [`detection_dataset.py`](detection_dataset.py):

```
python demo_mcu_apps/roi_tm/detection_dataset.py \
    --root /mnt/data/datasets/Face-Detection-Dataset --split train \
    --faces 4000 --nonfaces 4000 --min-face-px 32 --margin 1.3 --seed 1 \
    -o demo_mcu_apps/roi_tm/samples_det.jsonl
# scanned 1653 train images -> 8000 samples (4000 face bbox crops / 4000 background crops)
```

**Training** — [`train_tm.py`](train_tm.py) on that dataset:

```
python demo_mcu_apps/roi_tm/train_tm.py -i demo_mcu_apps/roi_tm/samples_det.jsonl \
    --clauses 64 --s 3.9 --T 15 --epochs 200 --states 100 \
    --val-split 0.2 --augment 3 --threshold 4 --seed 1
```

| parameter | value | |
| --- | --- | --- |
| features | 591 | ÷2 luma LBP (360) + ÷2 colour (231) |
| clauses | 64 | 32 face (+1) / 32 non-face (−1) |
| `s` / `T` / states | 3.9 / 15 / 100 | specificity / vote target / TA states |
| epochs | 200 | (more epochs + T=15 fit better than T=20/100 — train 0.812→0.831) |
| augment | ×3 | brightness / WB / contrast / flip per train sample |
| threshold | +4 | face when net vote ≥ 4 |
| val split | 0.2 | seed 1 (deterministic; re-running reproduces the masks) |
| **result** | train 0.831 / **val 0.818** | sparse model ~2 KB, overlay ~4 KB |

`--threshold` is a deployment knob, not used in the reported val accuracy (which is
at net-vote ≥ 0). On this model the val-set vote split is face mean +9 / no-face
mean −4.4; a threshold sweep peaks at +2 (val 0.825) but the camera's empty scene
sits around +2, so **+4** is used to avoid empty-scene false positives (val 0.818)
— erring toward not flickering "FACE", as desired.

Training is deterministic (fixed seeds), so re-running the two commands regenerates
the identical `tm_model.h`. The dataset JSONL is git-ignored (rebuild it from the
source). See **Experiments & findings** below for why these values were chosen.

## Why it stays in sync

[`tm_common.py`](tm_common.py) is the single source of truth for the three things
the host and MCU must agree on **bit-for-bit**:

- **featurize** — luma **LBP** + **colour**. The 22×14 ROI is 2×2 block-averaged to
  an 11×7 grid. Luma LBP: each interior cell emits 8 `neighbour ≥ centre` bits
  (order TL,T,TR,L,R,BL,B,BR) → 45×8 = 360 (texture/edge, lighting-robust). Colour:
  each cell emits 3 bits — `R>G`, `R>B`, and a skin cue (`R>G≥B & R−B≥2`) → 3×77 =
  231. Total **591 features**. Colour is the key face-vs-background discriminator
  (ablation on a real detection set: LBP-only RF 0.77 → +colour 0.84). Integer
  compares only — no multiply/divide/float, so the overlay is libgcc-free.
- **literal layout** — literal `k<N` is feature `k`, `k≥N` is its negation; bit `k`
  is in word `k>>5` at position `k&31`. Same packing in `pack_literals()` and the C.
- **voting** — clauses `0..TM_POS-1` vote +1, the rest −1; face when `vote ≥ TM_THRESHOLD`.

[`test_tm_pipeline.py`](test_tm_pipeline.py) locks this down: it **compiles the real
`roi_features.h`** with gcc and asserts its literal vector equals the Python
`featurize`/`pack_literals` bit-for-bit over many random inputs (this exercises the
actual C — a Python "mirror" once *missed* a macro variable-shadowing bug that
broke every colour feature on-device), checks featurize shape/determinism,
round-trips the exported (sparse) header, and confirms the TM learns a separable
problem. Run it with:

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

| dataset | face / no-face | accuracy |
| --- | --- | --- |
| easy   | Olivetti / 2-photo crops | 0.979 ± 0.008 (5-fold) |
| hard   | LFW / CIFAR-10           | 0.944 ± 0.013 (5-fold) |
| **realistic** | **YOLO detection set** ([`detection_dataset.py`](detection_dataset.py)) | **0.817 (holdout, LBP+colour)** |

The easy/hard sets are *optimistic* (centred faces, mismatched negatives). The
**detection set is the honest one** — real in-context faces + real background
negatives from the same images. On it, general detection at 22×14 caps around ~0.78
for *any* classifier on luma alone (a RandomForest upper-bound confirms it's a
resolution limit, not the TM); **adding colour features lifts it to ~0.84 (RF) /
0.82 (TM)** — colour is the main face-vs-background signal at this resolution.

The easy/hard numbers are *optimistic* (cropped/centred faces, dataset backgrounds ≠
your room); honest real-world accuracy needs `collect_samples.py` captures on your
own camera. `scikit-learn`/`pillow` are dev requirements; LFW (≈200 MB) and CIFAR
(≈170 MB) download once into the sklearn data home.

## Experiments & findings

The current design (64-clause TM, ÷2 luma LBP + ÷2 colour = 591 features, sparse
masks, threshold +4, photometric augmentation) is the result of these experiments —
recorded so the dead ends aren't re-explored:

| # | Tried | Result | Decision |
| --- | --- | --- | --- |
| 1 | **Feature ablation** on the detection set (RF upper-bound) | luma LBP only 0.77; +brightness-thermometer 0.78; **+colour 0.84**; full-res LBP 0.79 | **colour is the lever** at this resolution; keep it |
| 2 | **Clauses** 64 vs 128 (same data) | 0.817 vs 0.816 | no gain → **64 clauses**; the TM, not capacity, is the cap |
| 3 | **Higher resolution** (full-res 22×14 colour, 1284 feats) | RF 0.84→0.85 but **TM 0.817→0.809** even at 128 clauses | helps RF, not the TM → reverted; keep ÷2 colour |
| 4 | **Sparse (CSR) masks** vs dense `[64][37]` table | overlay 11.2 KB → 3.9 KB, faster inference | **adopted** (clauses include ~15 of ~1200 literals) |
| 5 | **Decision threshold** 0 → +4 | empty-scene flicker near vote 0 removed | **threshold +4** (empty −6…−13, face +12…+21) |
| 6 | **Luminance augmentation** (`--augment`) | brightened-val 0.783 → 0.791, clean unchanged | **adopted** (`--augment 3`); colour bits drift with exposure/AWB |
| 7 | **Graph Tsetlin Machine** (cair/HierarchicalGraphTsetlinMachine) | GPU-only; crashes on this Pascal GTX 1050; and its message-passing inference doesn't map to the MCU's bitwise loop | **abandoned** — not deployable here |

**Bottom line:** on a hard real detection set the *features/classifier* cap around
**0.82** at 22×14 (a RandomForest reaches ~0.84; the TM ~0.82 and is the part that
actually fits the MCU). Resolution and clause count are not the bottleneck — colour
features and matched data are. The biggest remaining lever is on-device capture
(`collect_samples.py`) so the model learns *your* camera's colour/exposure.

## Files

| File | Role |
| --- | --- |
| `tm_common.py` | featurize, the numpy TM (train + reference inference), bit-packing, `augment()`, sparse-header export — shared by trainer and tests. |
| `train_tm.py` | CLI: load `samples.jsonl` → train → evaluate → emit `tm_model.h` + `tm_model.json`. `--augment N` (luminance robustness), `--threshold`, `--synthetic` (self-test). |
| `roi_features.h` | the ROI→literal featurize in C, **shared** by `roi_tm.c` and the host compile-test (single source, so C and Python can't drift). |
| `roi_tm.c` | SERV overlay: read ROI → `roi_featurize()` → bitwise TM vote → OSD (FACE / FPS / F-N counters) + heartbeat. |
| `tm_model.h` | **Generated** (sparse CSR: `tm_clause_len` + `tm_lit`). The committed model is trained on the YOLO detection set (`--augment 3`), so the demo deploys and detects faces as-is; regenerate with `train_tm.py` to retrain. |
| `detection_dataset.py` | Build the device-format dataset from a YOLO **face-detection** set (e.g. `/mnt/data/datasets/Face-Detection-Dataset`): crops face bboxes (face) + non-overlapping regions (no-face) from the same images → real in-context faces + real backgrounds. The best source for this task. |
| `visualize_dataset.py` | Render a `samples*.jsonl` dataset: a colour PNG montage grouped by label (`--ascii` for terminal luma previews). Eyeball alignment / balance / mislabels. |
| `test_tm_pipeline.py` | Pure-host pipeline tests (no hardware). |

## Notes

- The committed `tm_model.h` is a **real model** (detection-set, `--augment 3`), so
  `roi_tm` detects faces out of the box; retrain on your own captures to close the
  domain gap to your camera.
- The model is stored **sparse** (CSR: per-clause literal-index lists) — ~2 KB of
  `.rodata`, ~3.9 KB overlay, uploaded through the bootloader mailbox in ~2–3 s.
- Changing the feature geometry means retraining: `roi_features.h` has a
  `#if TM_N != FEATURE_COUNT` guard that fails the build if `tm_model.h` no longer
  matches.
- `roi_features.h` (featurize) and `tm_common.featurize` must stay in lockstep — the
  compile-and-diff test guards it; the OV7670 outputs colour (RGB565), so the colour
  features assume a colour camera.
