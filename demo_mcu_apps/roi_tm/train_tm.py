#!/usr/bin/env python3
"""Train the fixed-ROI face-presence Tsetlin Machine and export it for the MCU.

Pipeline:
    1. collect_samples.py  -> samples.jsonl  (labelled RGB565 ROI patches)
    2. train_tm.py         -> tm_model.h     (baked into the roi_tm overlay)
    3. cmake --build build --target serv_firmware ; upload build/serv_fw/roi_tm.bin
       (the MCU runs the same bitwise inference on the live ROI)

This script featurizes each ROI patch (one "brighter than the ROI mean" bit per
cell -- see tm_common.featurize), trains a two-class Tsetlin Machine on the host,
reports train/validation accuracy, and writes:
    tm_model.h     -- the packed clause masks + sizes the roi_tm overlay #includes
    tm_model.json  -- the same model + metadata, for inspection / re-export

Usage:
    .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py            # train on samples.jsonl
    .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py --synthetic   # self-test / default model
    .venv/bin/python demo_mcu_apps/roi_tm/train_tm.py --clauses 96 --epochs 300

The featurization + literal layout + voting live in tm_common.py, shared verbatim
with the C inference, so the host accuracy reported here is what the MCU computes.
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tm_common as tm  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SAMPLES = os.path.join(os.path.dirname(HERE), "roi_collect", "samples.jsonl")
DEFAULT_HEADER = os.path.join(HERE, "tm_model.h")
DEFAULT_MODEL = os.path.join(HERE, "tm_model.json")


def load_samples(path):
    """Read samples.jsonl -> (list of roi565 lists, labels array)."""
    rois, labels = [], []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            rois.append(rec["roi565"])
            labels.append(int(rec["label"]))
    if not rois:
        raise SystemExit(f"no samples in {path}")
    n = len(rois[0])
    if any(len(r) != n for r in rois):
        raise SystemExit("inconsistent ROI lengths in the dataset")
    return rois, np.asarray(labels, dtype=np.int8)


def synthetic(n_features=tm.N_FEATURES, n=400, seed=3):
    """A separable face/no-face-like dataset for self-test + a buildable default model.

    A "face" lights a fixed central band of feature bits with high probability; a
    "no-face" lights them with low probability. Trains to high accuracy, so it
    exercises the whole train -> export -> infer path without real captures.
    """
    rng = np.random.default_rng(seed)
    band = np.zeros(n_features, dtype=bool)
    band[n_features // 3: 2 * n_features // 3] = True
    X = np.empty((n, n_features), dtype=bool)
    Y = np.empty(n, dtype=np.int8)
    for i in range(n):
        y = i % 2
        pin = np.where(band, 0.85 if y else 0.15, 0.5)
        X[i] = rng.random(n_features) < pin
        Y[i] = y
    return X, Y


def confusion(y_true, y_pred):
    tp = int(((y_true == 1) & (y_pred == 1)).sum())
    tn = int(((y_true == 0) & (y_pred == 0)).sum())
    fp = int(((y_true == 0) & (y_pred == 1)).sum())
    fn = int(((y_true == 1) & (y_pred == 0)).sum())
    return tp, tn, fp, fn


def main():
    ap = argparse.ArgumentParser(
        description="Train + export the ROI face-presence Tsetlin Machine")
    ap.add_argument("-i", "--samples", default=DEFAULT_SAMPLES,
                    help="JSONL dataset (collect_samples.py)")
    ap.add_argument("--synthetic", action="store_true",
                    help="train on synthetic data (self-test / default model)")
    ap.add_argument("--clauses", type=int, default=tm.DEFAULT_CLAUSES)
    ap.add_argument("--states", type=int, default=tm.DEFAULT_STATES)
    ap.add_argument("--s", type=float, default=tm.DEFAULT_S)
    ap.add_argument("--T", type=int, default=tm.DEFAULT_T)
    ap.add_argument("--epochs", type=int, default=tm.DEFAULT_EPOCHS)
    ap.add_argument("--val-split", type=float, default=0.25,
                    help="fraction held out for validation")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--threshold", type=int, default=tm.THRESHOLD,
                    help="decision threshold: face when vote >= this "
                         "(raise to cut empty-scene flicker)")
    ap.add_argument("--augment", type=int, default=0, metavar="N",
                    help="add N photometric augmentations per TRAIN sample (brightness/WB/"
                         "contrast/flip) for luminance robustness; val stays clean")
    ap.add_argument("--header", default=DEFAULT_HEADER)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    if args.synthetic:
        X, Y = synthetic()
        idx = rng.permutation(X.shape[0])
        nval = int(round(X.shape[0] * args.val_split))
        val, trn = idx[:nval], idx[nval:]
        X_trn, Y_trn, X_val, Y_val = X[trn], Y[trn], X[val], Y[val]
        n_features, src, ntot = X.shape[1], "synthetic", X.shape[0]
    else:
        rois, Y = load_samples(args.samples)
        src, ntot = os.path.relpath(args.samples), len(rois)
        idx = rng.permutation(ntot)
        nval = int(round(ntot * args.val_split))
        val, trn = (idx[:nval], idx[nval:]) if nval < ntot else (np.array([], int), idx)
        X_val = (tm.featurize_matrix([rois[i] for i in val]) if len(val)
                 else np.zeros((0, tm.N_FEATURES), bool))
        Y_val = Y[val]
        # training split: each sample + N photometric augmentations (val stays clean)
        aug_rng = np.random.default_rng(args.seed + 1)
        tr_rois, tr_y = [], []
        for i in trn:
            tr_rois.append(rois[i])
            tr_y.append(int(Y[i]))
            for _ in range(args.augment):
                tr_rois.append(tm.augment(rois[i], aug_rng))
                tr_y.append(int(Y[i]))
        X_trn, Y_trn = tm.featurize_matrix(tr_rois), np.asarray(tr_y, np.int8)
        n_features = X_trn.shape[1]
    print(f"data: {ntot} samples ({int((Y==1).sum())} face / {int((Y==0).sum())} no-face) "
          f"from {src}; train {X_trn.shape[0]} (aug x{args.augment}) / val {X_val.shape[0]}")
    if ntot < 8:
        print("WARNING: very few samples -- collect more for a usable model")

    machine = tm.TsetlinMachine(n_features, clauses=args.clauses, states=args.states,
                                s=args.s, T=args.T, seed=args.seed)
    print(f"training: {args.clauses} clauses, s={args.s}, T={args.T}, {args.epochs} epochs ...")
    machine.fit(X_trn, Y_trn, epochs=args.epochs,
                log=lambda ep, acc: print(f"  epoch {ep:4d}: train acc {acc:.3f}"))

    masks = machine.masks()
    tr_acc = float((machine.predict(X_trn) == Y_trn).mean())
    line = f"train acc {tr_acc:.3f}"
    if len(Y_val):
        va_pred = machine.predict(X_val)
        va_acc = float((va_pred == Y_val).mean())
        tp, tn, fp, fn = confusion(Y_val, va_pred)
        line += f"   val acc {va_acc:.3f}  (tp={tp} tn={tn} fp={fp} fn={fn})"
    else:
        va_acc = None
    print(line)

    nonempty = int((masks != 0).any(axis=1).sum())
    bits = int(np.unpackbits(masks.view(np.uint8)).sum())
    print(f"model: {args.clauses} clauses ({nonempty} non-empty), {bits} included literals, "
          f"{masks.shape[1]} words/clause ({masks.size * 4} bytes)")

    meta = (f"source={src}  clauses={args.clauses} states={args.states} s={args.s} T={args.T} "
            f"epochs={args.epochs} augment={args.augment}  train_acc={tr_acc:.3f}"
            + (f" val_acc={va_acc:.3f}" if va_acc is not None else ""))
    tm.export_header(args.header, masks, n_features, machine.pos,
                     threshold=args.threshold, meta=meta)
    with open(args.model, "w") as f:
        json.dump({"n_features": n_features, "clauses": args.clauses, "pos": machine.pos,
                   "threshold": args.threshold, "states": args.states, "s": args.s, "T": args.T,
                   "epochs": args.epochs, "train_acc": tr_acc, "val_acc": va_acc,
                   "masks": masks.astype(np.uint32).tolist()}, f)
    print(f"wrote {os.path.relpath(args.header)} and {os.path.relpath(args.model)}")
    print("next: cmake --build build --target serv_firmware  ->  upload build/serv_fw/roi_tm.bin")


if __name__ == "__main__":
    main()
