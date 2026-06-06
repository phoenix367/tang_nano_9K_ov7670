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

    Mirrors the C step for step: brightness, 2x2 block-average downsample (>>2),
    8-neighbour LBP bits (neighbour >= centre, TL,T,TR,L,R,BL,B,BR order), literal
    packing (feature then negation, LSB-first), clause AND-compare, signed vote.
    Must equal infer_packed on the same featurization.
    """
    a = [int(p) for p in roi565]                  # row-major 14x22 RGB565
    # 2x2 block sums -> downsampled channels (brightness, R, G->5bit, B)
    dsBr = [[0] * tm.DSW for _ in range(tm.DSH)]
    dsR = [[0] * tm.DSW for _ in range(tm.DSH)]
    dsG5 = [[0] * tm.DSW for _ in range(tm.DSH)]
    dsB = [[0] * tm.DSW for _ in range(tm.DSH)]
    for r in range(tm.DSH):
        for c in range(tm.DSW):
            rs = gs = bs = 0
            for (rr, cc) in ((2 * r, 2 * c), (2 * r, 2 * c + 1), (2 * r + 1, 2 * c), (2 * r + 1, 2 * c + 1)):
                p = a[rr * tm.ROI_COLS + cc]
                rs += (p >> 11) & 0x1F; gs += (p >> 5) & 0x3F; bs += p & 0x1F
            dsBr[r][c] = (rs + gs + bs) >> 2
            dsR[r][c] = rs >> 2; dsG5[r][c] = gs >> 3; dsB[r][c] = bs >> 2
    n = tm.N_FEATURES
    nwords = (2 * n + 31) // 32
    lit = [0] * nwords
    idx = 0

    def setf(cond):
        nonlocal idx
        k = idx if cond else (n + idx)
        lit[k >> 5] |= 1 << (k & 31)
        idx += 1

    for r in range(1, tm.DSH - 1):
        for c in range(1, tm.DSW - 1):
            ctr = dsBr[r][c]
            for dr, dc in tm.LBP_OFFSETS:
                setf(dsBr[r + dr][c + dc] >= ctr)
    for r in range(tm.DSH):
        for c in range(tm.DSW):
            setf(dsR[r][c] > dsG5[r][c])
    for r in range(tm.DSH):
        for c in range(tm.DSW):
            setf(dsR[r][c] > dsB[r][c])
    for r in range(tm.DSH):
        for c in range(tm.DSW):
            setf(dsR[r][c] > dsG5[r][c] and dsG5[r][c] >= dsB[r][c] and (dsR[r][c] - dsB[r][c]) >= 2)
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


ROI_CELLS = tm.ROI_COLS * tm.ROI_ROWS      # 308 RGB565 cells per ROI patch


def test_featurize_shape_and_determinism():
    """LBP featurization yields exactly N_FEATURES bits and is deterministic."""
    for roi in random_rois(20, ROI_CELLS, seed=11):
        f = tm.featurize(roi)
        assert f.shape == (tm.N_FEATURES,) and f.dtype == bool
        assert np.array_equal(f, tm.featurize(roi))
    assert tm.N_FEATURES == ((tm.DSW - 2) * (tm.DSH - 2)) * 8 + 3 * tm.DSW * tm.DSH


def test_mcu_mirror_matches_reference():
    """The Python mirror of roi_tm.c == the numpy inference (infer_packed)."""
    machine = tm.TsetlinMachine(tm.N_FEATURES, clauses=32, seed=2)
    X, Y = _synth(120, tm.N_FEATURES, seed=2)
    machine.fit(X, Y, epochs=20)
    masks = machine.masks()
    for roi in random_rois(80, ROI_CELLS, seed=7):
        feat = tm.featurize(roi)
        ref_pred, ref_vote = tm.infer_packed(masks, tm.pack_literals(feat), machine.pos)
        c_pred, c_vote = mcu_mirror(roi, masks, machine.pos)
        assert (c_pred, c_vote) == (ref_pred, ref_vote)


def test_exported_header_roundtrips():
    machine = tm.TsetlinMachine(tm.N_FEATURES, clauses=16, seed=4)
    X, Y = _synth(60, tm.N_FEATURES, seed=4)
    machine.fit(X, Y, epochs=10)
    masks = machine.masks()
    out = os.path.join(HERE, "_test_model.h")
    try:
        tm.export_header(out, masks, tm.N_FEATURES, machine.pos, meta="unit test")
        sizes, parsed = parse_header(out)
        assert sizes["TM_N"] == tm.N_FEATURES and sizes["TM_CLAUSES"] == 16 and sizes["TM_POS"] == 8
        assert sizes["TM_NWORDS"] == masks.shape[1]
        assert np.array_equal(parsed, masks)
    finally:
        if os.path.exists(out):
            os.remove(out)


def test_committed_model_header_is_valid():
    """The checked-in default tm_model.h parses and matches the LBP feature count."""
    sizes, masks = parse_header(os.path.join(HERE, "tm_model.h"))
    assert masks.shape == (sizes["TM_CLAUSES"], sizes["TM_NWORDS"])
    assert sizes["TM_N"] == tm.N_FEATURES
    assert sizes["TM_NLIT"] == 2 * sizes["TM_N"]
    assert sizes["TM_NWORDS"] == (sizes["TM_NLIT"] + 31) // 32


_HARNESS = r"""
#include <stdio.h>
#include <stdint.h>
#include "roi_features.h"
int main(void){
    uint16_t roi[ROI_CELLS]; uint32_t lit[TM_NWORDS];
    for (int i=0;i<ROI_CELLS;i++){ unsigned v; if(scanf("%u",&v)!=1) return 1; roi[i]=(uint16_t)v; }
    roi_featurize(roi, lit);
    for (int w=0; w<TM_NWORDS; w++) printf("%u\n", lit[w]);
    return 0;
}
"""


def test_c_featurize_matches_host():
    """Compile the ACTUAL roi_features.h and assert its literal vector equals the
    Python featurize/pack_literals bit-for-bit. This exercises the real C (not a
    Python re-implementation), so macro/shadowing-class bugs can't slip through."""
    import shutil
    import subprocess
    gcc = shutil.which("gcc")
    if gcc is None:
        pytest.skip("gcc not available")
    src = os.path.join(HERE, "_c_featurize_harness.c")
    exe = os.path.join(HERE, "_c_featurize_harness")
    open(src, "w").write(_HARNESS)
    try:
        subprocess.run([gcc, "-O2", "-I", HERE, src, "-o", exe], check=True,
                       capture_output=True)
        nw = (2 * tm.N_FEATURES + 31) // 32
        for roi in random_rois(40, ROI_CELLS, seed=3):
            out = subprocess.run([exe], input="\n".join(map(str, roi)),
                                 capture_output=True, text=True, check=True)
            c_lit = [int(x) for x in out.stdout.split()]
            py_lit = [int(x) for x in tm.pack_literals(tm.featurize(roi))]
            assert len(c_lit) == nw and c_lit == py_lit
    finally:
        for f in (src, exe):
            if os.path.exists(f):
                os.remove(f)


def test_tm_learns_separable_problem():
    X, Y = _synth(400, tm.N_FEATURES, seed=5)
    machine = tm.TsetlinMachine(tm.N_FEATURES, clauses=64, seed=5)
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
