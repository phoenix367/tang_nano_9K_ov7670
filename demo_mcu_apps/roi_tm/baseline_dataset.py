#!/usr/bin/env python3
"""Build a face / no-face baseline dataset in the device's ROI format.

To sanity-check that the LBP + Tsetlin Machine pipeline can separate faces from
non-faces *at all* -- before any tedious on-device capture -- this turns a small
public dataset into the exact representation the device produces: 22x14 RGB565 ROI
patches, written to the same JSONL format as collect_samples.py. So train_tm.py
trains on it unchanged, and the accuracy it reports is a real baseline for the
on-MCU featurization.

Sources (both via scikit-learn, small + reliable):
  * FACE     -- Olivetti faces (400 cropped frontal faces, 64x64 grayscale): a face
                that fills the ROI box, like a user aligned to the guide.
  * NO-FACE  -- random crops of the bundled natural photos (china.jpg, flower.jpg):
                buildings / plants / sky / ground, no faces.

Everything is resized to 22x14 and packed to RGB565 with numpy (no Pillow needed
for the resize; Pillow is only used by sklearn to decode the sample JPEGs).

    .venv/bin/python demo_mcu_apps/roi_tm/baseline_dataset.py
    .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py -i demo_mcu_apps/roi_tm/samples_baseline.jsonl \
        --header /tmp/tm_baseline.h --model /tmp/tm_baseline.json

Caveat: this is a *pipeline* baseline. Olivetti faces are clean lab portraits and
the non-faces come from two photos, so accuracy here is optimistic vs. the real
camera + room backgrounds. It proves the features are learnable, not that this
exact model will work on the board -- for that, collect real samples and retrain.
"""
import argparse
import json
import os

import numpy as np
from sklearn.datasets import fetch_olivetti_faces, load_sample_images

# device ROI grid (must match collect_samples.py / tm_common.py)
ROI_COLS, ROI_ROWS = 22, 14
ROI_CELLS = ROI_COLS * ROI_ROWS

DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples_baseline.jsonl")


def resize_area(img, out_h, out_w):
    """Area-average resize of a (H,W) or (H,W,3) image to (out_h,out_w[,3])."""
    H, W = img.shape[:2]
    ys = np.linspace(0, H, out_h + 1).astype(int)
    xs = np.linspace(0, W, out_w + 1).astype(int)
    tail = img.shape[2:]
    out = np.zeros((out_h, out_w) + tail, dtype=np.float64)
    for i in range(out_h):
        for j in range(out_w):
            block = img[ys[i]:ys[i + 1], xs[j]:xs[j + 1]]
            out[i, j] = block.reshape(-1, *tail).mean(axis=0) if tail else block.mean()
    return out


def to_rgb565(rgb):
    """(out_h,out_w,3) uint8/float 0..255 -> list of row-major RGB565 ints."""
    rgb = np.clip(rgb, 0, 255).astype(np.int32)
    r = (rgb[..., 0] >> 3) & 0x1F
    g = (rgb[..., 1] >> 2) & 0x3F
    b = (rgb[..., 2] >> 3) & 0x1F
    return ((r << 11) | (g << 5) | b).reshape(-1).tolist()


def face_patches(n, flip=True):
    """n Olivetti faces resized to the ROI grid, RGB565 (grayscale -> R=G=B)."""
    imgs = fetch_olivetti_faces().images          # (400, 64, 64) float 0..1
    rng = np.random.default_rng(0)
    idx = rng.permutation(len(imgs))
    out = []
    for k in idx:
        g = imgs[k]
        if flip and len(out) % 2:                 # mix in horizontal flips for variety
            g = g[:, ::-1]
        gray = resize_area(g * 255.0, ROI_ROWS, ROI_COLS)        # (14,22)
        rgb = np.repeat(gray[..., None], 3, axis=2)              # grayscale -> RGB
        out.append(to_rgb565(rgb))
        if len(out) >= n:
            break
    return out


def nonface_patches(n, seed=1):
    """n random crops of the natural sample photos, resized to the ROI grid, RGB565."""
    imgs = [im.astype(np.float64) for im in load_sample_images().images]   # (427,640,3)
    rng = np.random.default_rng(seed)
    out = []
    while len(out) < n:
        img = imgs[rng.integers(len(imgs))]
        H, W = img.shape[:2]
        ch = int(rng.integers(40, H))                            # random crop size
        cw = int(rng.integers(int(ch * 1.2), int(ch * 1.8) + 1)) # ~ROI landscape aspect
        cw = min(cw, W)
        y = int(rng.integers(0, H - ch + 1))
        x = int(rng.integers(0, W - cw + 1))
        crop = img[y:y + ch, x:x + cw]
        out.append(to_rgb565(resize_area(crop, ROI_ROWS, ROI_COLS)))
    return out


def main():
    ap = argparse.ArgumentParser(description="Build a face/no-face baseline dataset (device ROI format)")
    ap.add_argument("-o", "--out", default=DEFAULT_OUT)
    ap.add_argument("--faces", type=int, default=400)
    ap.add_argument("--nonfaces", type=int, default=400)
    args = ap.parse_args()

    faces = face_patches(args.faces)
    nonfaces = nonface_patches(args.nonfaces)
    assert all(len(p) == ROI_CELLS for p in faces + nonfaces), "patch size != ROI_CELLS"

    recs = [{"label": 1, "roi565": p} for p in faces] + \
           [{"label": 0, "roi565": p} for p in nonfaces]
    with open(args.out, "w") as f:
        for rec in recs:
            f.write(json.dumps(rec) + "\n")
    print(f"wrote {len(recs)} samples to {os.path.relpath(args.out)} "
          f"({len(faces)} face, {len(nonfaces)} no-face)")
    print("train:  .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py "
          f"-i {os.path.relpath(args.out)} --header /tmp/tm_baseline.h --model /tmp/tm_baseline.json")


if __name__ == "__main__":
    main()
