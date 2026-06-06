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
| `detection_dataset.py` | Build the device-format dataset from a YOLO **face-detection** set (e.g. `/mnt/data/datasets/Face-Detection-Dataset`): crops face bboxes (face) + non-overlapping regions (no-face) from the same images → real in-context faces + real backgrounds. The best source for this task. |
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
