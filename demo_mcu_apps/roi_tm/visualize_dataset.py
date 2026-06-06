#!/usr/bin/env python3
"""Visualize a face/no-face ROI dataset (the samples*.jsonl format).

Renders the 22x14 RGB565 ROI patches from collect_samples.py / baseline_dataset.py
so you can eyeball the data: are the faces aligned and filling the box? are the
no-face samples actually face-free? is the set balanced?

By default it writes a colour PNG montage grouped by label (green border = face,
red = no-face), upscaled for visibility. `--ascii` instead prints luma previews to
the terminal (no display / Pillow needed) -- handy over SSH.

    .venv/bin/python demo_mcu_apps/roi_tm/visualize_dataset.py \
        demo_mcu_apps/roi_collect/samples.jsonl
    .venv/bin/python demo_mcu_apps/roi_tm/visualize_dataset.py \
        demo_mcu_apps/roi_tm/samples_hard.jsonl -o /tmp/hard.png
    .venv/bin/python demo_mcu_apps/roi_tm/visualize_dataset.py <dataset> --ascii --per-class 4
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tm_common as tm  # noqa: E402

W, H = tm.ROI_COLS, tm.ROI_ROWS          # 22 x 14
DEFAULT_DATASET = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                               "roi_collect", "samples.jsonl")
RAMP = " .:-=+*#%@"


def load(path):
    recs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                r = json.loads(line)
                if len(r["roi565"]) != W * H:
                    raise SystemExit(f"{path}: ROI length {len(r['roi565'])} != {W*H} "
                                     f"(wrong ROI geometry?)")
                recs.append(r)
    if not recs:
        raise SystemExit(f"no samples in {path}")
    return recs


def rgb565_to_rgb(arr):
    """(N,) RGB565 ints -> (N,3) uint8 RGB888."""
    arr = np.asarray(arr, dtype=np.int32)
    r = (arr >> 11) & 0x1F
    g = (arr >> 5) & 0x3F
    b = arr & 0x1F
    return np.stack([(r * 527 + 23) >> 6, (g * 259 + 33) >> 6, (b * 527 + 23) >> 6],
                    axis=-1).astype(np.uint8)


def patch_rgb(roi565):
    """ROI patch -> (H, W, 3) uint8 image."""
    return rgb565_to_rgb(roi565).reshape(H, W, 3)


def sample_by_label(recs, per_class, seed=0):
    """Return (faces, nonfaces) lists of roi565, up to per_class each (shuffled)."""
    rng = np.random.default_rng(seed)
    out = {0: [], 1: []}
    for lab in (1, 0):
        idx = [i for i, r in enumerate(recs) if r["label"] == lab]
        rng.shuffle(idx)
        out[lab] = [recs[i]["roi565"] for i in idx[:per_class]]
    return out[1], out[0]


def ascii_preview(roi565):
    return ["".join(RAMP[min(len(RAMP) - 1, tm.brightness(p) * len(RAMP) // 126)]
                    for p in roi565[r * W:(r + 1) * W]) for r in range(H)]


def make_montage(faces, nonfaces, cols, scale, out):
    from PIL import Image, ImageDraw

    pw, ph, pad, bd = W * scale, H * scale, 4, 2
    title_h = 18
    bg = (24, 24, 24)

    def section_h(n):
        rows = (n + cols - 1) // cols if n else 0
        return title_h + (rows * (ph + 2 * bd + pad) + pad if rows else pad)

    cw = pad + cols * (pw + 2 * bd + pad)
    ch = section_h(len(faces)) + section_h(len(nonfaces))
    img = Image.new("RGB", (cw, max(ch, title_h)), bg)
    draw = ImageDraw.Draw(img)

    def draw_section(y0, title, patches, color):
        draw.text((pad, y0 + 4), title, fill=color)
        y = y0 + title_h
        for i, roi in enumerate(patches):
            r, c = divmod(i, cols)
            x = pad + c * (pw + 2 * bd + pad)
            yy = y + r * (ph + 2 * bd + pad)
            draw.rectangle([x, yy, x + pw + 2 * bd - 1, yy + ph + 2 * bd - 1], fill=color)
            p = Image.fromarray(patch_rgb(roi)).resize((pw, ph), Image.NEAREST)
            img.paste(p, (x + bd, yy + bd))
        return y0 + section_h(len(patches))

    y = draw_section(0, f"FACE ({len(faces)})", faces, (40, 200, 40))
    draw_section(y, f"NO-FACE ({len(nonfaces)})", nonfaces, (210, 50, 50))
    img.save(out)


def main():
    ap = argparse.ArgumentParser(
        description="Visualize a face/no-face ROI dataset (samples*.jsonl)")
    ap.add_argument("dataset", nargs="?", default=DEFAULT_DATASET, help="JSONL dataset")
    ap.add_argument("-o", "--out", help="output PNG (default: <dataset>.png)")
    ap.add_argument("--cols", type=int, default=20, help="patches per row in the montage")
    ap.add_argument("--scale", type=int, default=8, help="upscale factor per patch")
    ap.add_argument("--per-class", type=int, default=120, help="max patches shown per label")
    ap.add_argument("--ascii", action="store_true", help="print luma previews instead of a PNG")
    args = ap.parse_args()

    recs = load(args.dataset)
    nf = sum(1 for r in recs if r["label"] == 1)
    nn = sum(1 for r in recs if r["label"] == 0)
    print(f"{args.dataset}: {len(recs)} samples ({nf} face, {nn} no-face)")
    faces, nonfaces = sample_by_label(recs, args.per_class)

    if args.ascii:
        npc = min(args.per_class, 6)
        for title, patches in (("FACE", faces[:npc]), ("NO-FACE", nonfaces[:npc])):
            for k, roi in enumerate(patches):
                print(f"\n{title} #{k}")
                print("\n".join("  " + ln for ln in ascii_preview(roi)))
        return

    out = args.out or (os.path.splitext(args.dataset)[0] + ".png")
    make_montage(faces, nonfaces, args.cols, args.scale, out)
    print(f"wrote {out}  ({len(faces)} face + {len(nonfaces)} no-face shown, "
          f"{W}x{H} patches x{args.scale})")


if __name__ == "__main__":
    main()
