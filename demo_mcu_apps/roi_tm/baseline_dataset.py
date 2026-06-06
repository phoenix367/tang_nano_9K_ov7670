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
    .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py \
        -i demo_mcu_apps/roi_tm/samples_baseline.jsonl \
        --header /tmp/tm_baseline.h --model /tmp/tm_baseline.json

Caveat: this is a *pipeline* baseline. Olivetti faces are clean lab portraits and
the non-faces come from two photos, so accuracy here is optimistic vs. the real
camera + room backgrounds. It proves the features are learnable, not that this
exact model will work on the board -- for that, collect real samples and retrain.
"""
import argparse
import json
import os
import pickle
import tarfile
import urllib.request

import numpy as np
from sklearn.datasets import (
    fetch_lfw_people,
    fetch_olivetti_faces,
    get_data_home,
    load_sample_images,
)

# device ROI grid (must match collect_samples.py / tm_common.py)
ROI_COLS, ROI_ROWS = 22, 14
ROI_CELLS = ROI_COLS * ROI_ROWS

DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples_baseline.jsonl")
CIFAR_URL = "https://www.cs.toronto.edu/~kriz/cifar-10-python.tar.gz"


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


def _to_gray(rgb):
    """(...,3) RGB -> grayscale broadcast back to 3 channels (Rec.601 luma)."""
    luma = rgb @ np.array([0.299, 0.587, 0.114])
    return np.repeat(luma[..., None], 3, axis=2)


def lfw_face_patches(n, seed=0):
    """n LFW "faces in the wild" (COLOR) resized to the ROI grid, RGB565.

    Harder than Olivetti: varied pose, lighting, expression, background. Color, to
    match the board's RGB565 camera and to avoid a grayscale-vs-color class artifact
    against the color no-face sets.
    """
    data = fetch_lfw_people(resize=0.4, color=True)              # (N, h, w, 3) float
    imgs = data.images
    scale = 255.0 / float(imgs.max() or 1.0)
    rng = np.random.default_rng(seed)
    return [to_rgb565(resize_area(imgs[k] * scale, ROI_ROWS, ROI_COLS))
            for k in rng.permutation(len(imgs))[:n]]


def nonface_patches(n, seed=1, gray=False):
    """n random crops of the natural sample photos, resized to the ROI grid, RGB565.

    `gray` grayscales them (to match a grayscale face set, e.g. Olivetti) so the two
    classes don't differ by a colour artifact.
    """
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
        if gray:
            crop = _to_gray(crop)
        out.append(to_rgb565(resize_area(crop, ROI_ROWS, ROI_COLS)))
    return out


def _cifar_images():
    """Download (cached) + load all 50k CIFAR-10 train images as (N,32,32,3) uint8."""
    tgz = os.path.join(get_data_home(), "cifar-10-python.tar.gz")
    if not os.path.exists(tgz):
        os.makedirs(os.path.dirname(tgz), exist_ok=True)
        print(f"downloading CIFAR-10 (~170 MB) to {tgz} ...")
        urllib.request.urlretrieve(CIFAR_URL, tgz)
    batches = []
    with tarfile.open(tgz) as tf:
        for m in tf.getmembers():
            if "/data_batch_" in m.name:
                d = pickle.load(tf.extractfile(m), encoding="bytes")
                batches.append(np.asarray(d[b"data"], dtype=np.uint8))
    data = np.concatenate(batches).reshape(-1, 3, 32, 32).transpose(0, 2, 3, 1)
    return data


def cifar_nonface_patches(n, seed=1, gray=False):
    """n CIFAR-10 images resized to the ROI grid, RGB565.

    CIFAR-10 has no person/face class (planes, cars, ships, trucks + animals), so
    every image is a non-(human-)face. The animal classes are useful HARD negatives
    (cat/dog faces look face-ish), forcing the classifier to be more discriminative.
    `gray` grayscales them to match a grayscale face set.
    """
    imgs = _cifar_images().astype(np.float64)
    rng = np.random.default_rng(seed)
    out = []
    for k in rng.permutation(len(imgs))[:n]:
        im = _to_gray(imgs[k]) if gray else imgs[k]
        out.append(to_rgb565(resize_area(im, ROI_ROWS, ROI_COLS)))
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Build a face/no-face baseline dataset (device ROI format)")
    ap.add_argument("-o", "--out", default=DEFAULT_OUT)
    ap.add_argument("--faces", type=int, default=400)
    ap.add_argument("--nonfaces", type=int, default=400)
    ap.add_argument("--face-source", choices=["olivetti", "lfw"], default="olivetti",
                    help="olivetti = clean lab faces; lfw = harder faces-in-the-wild")
    ap.add_argument("--nonface-source", choices=["samples", "cifar"], default="samples",
                    help="samples = crops of 2 photos; "
                         "cifar = diverse objects/scenes + hard negatives")
    ap.add_argument("--hard", action="store_true",
                    help="shortcut for --face-source lfw --nonface-source cifar")
    args = ap.parse_args()

    fsrc = "lfw" if args.hard else args.face_source
    nsrc = "cifar" if args.hard else args.nonface_source
    # match the no-face colour treatment to the face set: Olivetti is grayscale, so
    # grayscale the no-faces too; LFW is colour, so keep colour (and match the camera).
    gray = (fsrc == "olivetti")
    faces = (lfw_face_patches if fsrc == "lfw" else face_patches)(args.faces)
    nonfaces = (cifar_nonface_patches if nsrc == "cifar" else nonface_patches)(
        args.nonfaces, gray=gray)
    print(f"faces: {fsrc}   no-faces: {nsrc}   ({'grayscale' if gray else 'colour'} both)")
    assert all(len(p) == ROI_CELLS for p in faces + nonfaces), "patch size != ROI_CELLS"

    recs = [{"label": 1, "roi565": p} for p in faces] + \
           [{"label": 0, "roi565": p} for p in nonfaces]
    with open(args.out, "w") as f:
        for rec in recs:
            f.write(json.dumps(rec) + "\n")
    print(f"wrote {len(recs)} samples to {os.path.relpath(args.out)} "
          f"({len(faces)} face, {len(nonfaces)} no-face)")
    print("train:  .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py "
          f"-i {os.path.relpath(args.out)} "
          "--header /tmp/tm_baseline.h --model /tmp/tm_baseline.json")


if __name__ == "__main__":
    main()
