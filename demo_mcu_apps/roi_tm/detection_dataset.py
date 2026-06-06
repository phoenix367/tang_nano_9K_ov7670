#!/usr/bin/env python3
"""Build a face/no-face ROI dataset from a YOLO face-detection dataset.

Converts a detection dataset (images + YOLO labels: `class cx cy w h`, normalized,
class 0 = face) into the device's 22x14 RGB565 ROI format (same JSONL as
collect_samples.py), so train_tm.py trains on it unchanged.

Why this is a better baseline than LFW/CIFAR: the faces are in-context (real
backgrounds, varied size/pose) and -- crucially -- the NO-FACE samples are real
background regions cropped from the SAME images (non-overlapping with any face),
which is much closer to what the camera sees than CIFAR objects. Crops are
aspect-matched to the device ROI region (~22*16 : 14*30) and kept in colour to
match the RGB565 camera.

    .venv/bin/python demo_mcu_apps/roi_tm/detection_dataset.py \
        --root /mnt/data/datasets/Face-Detection-Dataset --split train \
        --faces 4000 --nonfaces 4000 -o demo_mcu_apps/roi_tm/samples_det.jsonl
"""
import argparse
import glob
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from baseline_dataset import ROI_COLS, ROI_ROWS, resize_area, to_rgb565  # noqa: E402

# device ROI region aspect (width / height): cols*COL_STEP : rows*ROW_STEP_rows
ROI_ASPECT = (ROI_COLS * 16) / (ROI_ROWS * 30)     # ~0.84 (slightly taller than wide)
DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples_det.jsonl")


def read_label(path):
    """YOLO label -> list of (cx, cy, w, h) normalized face boxes (class 0)."""
    boxes = []
    if not os.path.exists(path):
        return boxes
    for line in open(path):
        p = line.split()
        if len(p) == 5 and p[0] == "0":
            boxes.append(tuple(float(v) for v in p[1:]))
    return boxes


def aspect_crop(cx, cy, w, h, W, H, margin):
    """Pixel crop box (x0,y0,x1,y1) centred on (cx,cy), grown to margin + ROI aspect."""
    cx, cy, w, h = cx * W, cy * H, w * W * margin, h * H * margin
    if w / h > ROI_ASPECT:
        h = w / ROI_ASPECT
    else:
        w = h * ROI_ASPECT
    x0, y0 = int(cx - w / 2), int(cy - h / 2)
    x1, y1 = int(cx + w / 2), int(cy + h / 2)
    return max(0, x0), max(0, y0), min(W, x1), min(H, y1)


def overlaps(rect, boxes_px, thresh=0.1):
    """True if `rect` (x0,y0,x1,y1) overlaps any face box by >thresh of rect area."""
    x0, y0, x1, y1 = rect
    area = max(1, (x1 - x0) * (y1 - y0))
    for bx0, by0, bx1, by1 in boxes_px:
        ix, iy = max(0, min(x1, bx1) - max(x0, bx0)), max(0, min(y1, by1) - max(y0, by0))
        if ix * iy > thresh * area:
            return True
    return False


def patch565(img, rect):
    crop = img[rect[1]:rect[3], rect[0]:rect[2]]
    if crop.shape[0] < 2 or crop.shape[1] < 2:
        return None
    return to_rgb565(resize_area(crop.astype(np.float64), ROI_ROWS, ROI_COLS))


def main():
    ap = argparse.ArgumentParser(
        description="Build ROI face/no-face dataset from a YOLO detection set")
    ap.add_argument("--root", default="/mnt/data/datasets/Face-Detection-Dataset")
    ap.add_argument("--split", default="train", choices=["train", "val"])
    ap.add_argument("-o", "--out", default=DEFAULT_OUT)
    ap.add_argument("--faces", type=int, default=4000)
    ap.add_argument("--nonfaces", type=int, default=4000)
    ap.add_argument("--min-face-px", type=int, default=32, help="skip faces smaller than this")
    ap.add_argument("--margin", type=float, default=1.3, help="bbox grow factor (context)")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    img_dir = os.path.join(args.root, "images", args.split)
    lbl_dir = os.path.join(args.root, "labels", args.split)
    label_files = sorted(glob.glob(os.path.join(lbl_dir, "*.txt")))
    if not label_files:
        sys.exit(f"no labels in {lbl_dir}")
    rng = np.random.default_rng(args.seed)
    rng.shuffle(label_files)

    faces, nonfaces = [], []
    scanned = 0
    for lf in label_files:
        if len(faces) >= args.faces and len(nonfaces) >= args.nonfaces:
            break
        base = os.path.splitext(os.path.basename(lf))[0]
        imgs = glob.glob(os.path.join(img_dir, base + ".*"))
        if not imgs:
            continue
        boxes = read_label(lf)
        try:
            img = np.asarray(Image.open(imgs[0]).convert("RGB"))
        except Exception:
            continue
        H, W = img.shape[:2]
        scanned += 1
        boxes_px = [(int((cx - w / 2) * W), int((cy - h / 2) * H),
                     int((cx + w / 2) * W), int((cy + h / 2) * H)) for cx, cy, w, h in boxes]

        # faces
        if len(faces) < args.faces:
            for cx, cy, w, h in boxes:
                if w * W < args.min_face_px or h * H < args.min_face_px:
                    continue
                p = patch565(img, aspect_crop(cx, cy, w, h, W, H, args.margin))
                if p is not None:
                    faces.append(p)
                if len(faces) >= args.faces:
                    break

        # negatives: random ROI-aspect crops not overlapping any face
        if len(nonfaces) < args.nonfaces:
            tries = 6 if boxes else 3
            for _ in range(tries):
                ch = int(rng.integers(40, max(41, H)))
                cw = int(ch * ROI_ASPECT)
                if cw >= W or ch >= H:
                    continue
                x0 = int(rng.integers(0, W - cw))
                y0 = int(rng.integers(0, H - ch))
                rect = (x0, y0, x0 + cw, y0 + ch)
                if overlaps(rect, boxes_px):
                    continue
                p = patch565(img, rect)
                if p is not None:
                    nonfaces.append(p)
                if len(nonfaces) >= args.nonfaces:
                    break

    recs = [{"label": 1, "roi565": p} for p in faces] + \
           [{"label": 0, "roi565": p} for p in nonfaces]
    rng.shuffle(recs)
    with open(args.out, "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
    print(f"scanned {scanned} images -> {len(recs)} samples "
          f"({len(faces)} face, {len(nonfaces)} no-face); wrote {os.path.relpath(args.out)}")


if __name__ == "__main__":
    main()
