"""Pipeline tests for the ROI Tsetlin Machine (pure host, no hardware).

Run with:  .venv/bin/python -m pytest demo_mcu_apps/roi_tm/test_tm_pipeline.py -v

These lock down the contract between the host trainer and the MCU inference:
  * the float-free ROI-mean feature is identical to the b*N>sum definition,
  * a faithful mirror of roi_tm.c's *integer* inference equals the numpy reference
    (infer_packed) -- so the C transcription is provably correct,
  * the exported tm_model.h round-trips the trained masks,
  * the TM actually learns a separable problem.
"""
import os
import re
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tm_common as tm  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def mcu_mirror(roi565, masks, pos, threshold=tm.THRESHOLD):
    """Bit-exact reimplementation of roi_tm.c's integer inference, in Python.

    Mirrors the C step for step: brightness, ROI mean by floor division, one
    feature bit per cell (b > mean), literal packing (feature then negation,
    LSB-first), clause AND-compare, signed vote. Must equal infer_packed.
    """
    n = len(roi565)
    b = [tm.brightness(int(p)) for p in roi565]
    mean = sum(b) // n                         # the C repeated-subtraction floor mean
    nwords = (2 * n + 31) // 32
    lit = [0] * nwords
    for i in range(n):
        k = i if b[i] > mean else (n + i)
        lit[k >> 5] |= 1 << (k & 31)
    vote = 0
    for j in range(masks.shape[0]):
        out = 1
        for w in range(nwords):
            mw = int(masks[j][w])
            if (lit[w] & mw) != mw:
                out = 0
                break
        if out:
            vote += 1 if j < pos else -1
    return (1 if vote >= threshold else 0), vote


def parse_header(path):
    """Pull TM_* sizes and the tm_mask[][] values out of a generated tm_model.h."""
    txt = open(path).read()
    sizes = {k: int(v) for k, v in re.findall(r"#define\s+(TM_\w+)\s+(-?\d+)", txt)}
    rows = re.findall(r"\{\s*((?:0x[0-9a-fA-F]+u,?\s*)+)\}", txt)
    masks = np.array([[int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", r)] for r in rows],
                     dtype=np.uint32)
    return sizes, masks


def random_rois(n_samples, n_cells, seed=0):
    rng = np.random.default_rng(seed)
    return [[int(p) for p in rng.integers(0, 0x10000, n_cells)] for _ in range(n_samples)]


def test_feature_definition_is_division_free_and_exact():
    rng = np.random.default_rng(1)
    for _ in range(200):
        b = rng.integers(0, 126, 308)
        s = int(b.sum())
        ref = (b * 308) > s                    # the documented b*N>sum definition
        floor = b > (s // 308)                 # what the MCU computes (mean by floor)
        assert np.array_equal(ref, floor)


def test_mcu_mirror_matches_reference():
    """The Python mirror of roi_tm.c == the numpy inference (infer_packed)."""
    machine = tm.TsetlinMachine(308, clauses=32, seed=2)
    X, Y = _synth(120, 308, seed=2)
    machine.fit(X, Y, epochs=20)
    masks = machine.masks()
    for roi in random_rois(80, 308, seed=7):
        feat = tm.featurize(roi)
        ref_pred, ref_vote = tm.infer_packed(masks, tm.pack_literals(feat), machine.pos)
        c_pred, c_vote = mcu_mirror(roi, masks, machine.pos)
        assert (c_pred, c_vote) == (ref_pred, ref_vote)


def test_exported_header_roundtrips():
    machine = tm.TsetlinMachine(308, clauses=16, seed=4)
    X, Y = _synth(60, 308, seed=4)
    machine.fit(X, Y, epochs=10)
    masks = machine.masks()
    out = os.path.join(HERE, "_test_model.h")
    try:
        tm.export_header(out, masks, 308, machine.pos, meta="unit test")
        sizes, parsed = parse_header(out)
        assert sizes["TM_N"] == 308 and sizes["TM_CLAUSES"] == 16 and sizes["TM_POS"] == 8
        assert sizes["TM_NWORDS"] == masks.shape[1]
        assert np.array_equal(parsed, masks)
    finally:
        if os.path.exists(out):
            os.remove(out)


def test_committed_model_header_is_valid():
    """The checked-in default tm_model.h parses and matches its sizes."""
    sizes, masks = parse_header(os.path.join(HERE, "tm_model.h"))
    assert masks.shape == (sizes["TM_CLAUSES"], sizes["TM_NWORDS"])
    assert sizes["TM_NLIT"] == 2 * sizes["TM_N"]
    assert sizes["TM_NWORDS"] == (sizes["TM_NLIT"] + 31) // 32


def test_tm_learns_separable_problem():
    X, Y = _synth(400, 308, seed=5)
    n = X.shape[0]
    machine = tm.TsetlinMachine(308, clauses=64, seed=5)
    machine.fit(X[:300], Y[:300], epochs=40)
    acc = float((machine.predict(X[300:]) == Y[300:]).mean())
    assert acc > 0.9, f"TM failed to learn separable data (acc={acc:.3f})"


def _synth(n, nf, seed):
    rng = np.random.default_rng(seed)
    band = np.zeros(nf, dtype=bool)
    band[nf // 3: 2 * nf // 3] = True
    X = np.empty((n, nf), dtype=bool)
    Y = np.empty(n, dtype=np.int8)
    for i in range(n):
        y = i % 2
        X[i] = rng.random(nf) < np.where(band, 0.85 if y else 0.15, 0.5)
        Y[i] = y
    return X, Y


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
