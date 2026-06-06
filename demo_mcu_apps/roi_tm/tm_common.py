"""Shared Tsetlin Machine pieces for the fixed-ROI face-presence classifier.

This module is the single source of truth for the parts that MUST agree bit-for-bit
between the offline host trainer (train_tm.py) and the on-MCU inference (roi_tm.c):

  * featurize()  -- RGB565 ROI cells -> a boolean feature per cell. The MCU
    recomputes the identical bits, so the threshold is integer-exact (compare
    b[i]*N to the ROI brightness sum, i.e. "brighter than the ROI mean", with no
    division -- RV32I has no divide).
  * the literal layout -- literal k<N is feature k, literal N+k is its negation;
    bit k lives in word k>>5 at position k&31. pack_literals()/pack_clause() and
    the C inference use this same packing.
  * infer_packed() -- the exact bitwise vote the MCU computes, used here as the
    training-time evaluator AND as the reference the C port is checked against.

A Tsetlin Machine classifies by a vote: each clause is a conjunction (AND) of
included literals; the first POS clauses vote +1 when they fire, the rest -1.
predict = (vote >= THRESHOLD). Inference is pure AND/compare/accumulate -- ideal
for the bit-serial soft core. Training (the TsetlinMachine class) stays on the host.
"""
import numpy as np

# ---- defaults (overridable from the trainer CLI) ----
DEFAULT_CLAUSES = 64        # total clauses (half positive, half negative)
DEFAULT_STATES = 100        # TA states per side; include if state > STATES
DEFAULT_S = 3.9             # specificity
DEFAULT_T = 15              # vote target / feedback threshold
DEFAULT_EPOCHS = 200
THRESHOLD = 0               # classify face when vote >= THRESHOLD


def brightness(p):
    """RGB565 -> 0..125 brightness (R5 + G6 + B5). Matches the MCU's brightness()."""
    return ((p >> 11) & 0x1F) + ((p >> 5) & 0x3F) + (p & 0x1F)


# ---- feature geometry (MUST match roi_tm.c) ----
# The ROI grid as stored by collect_samples (22x14 = 308 RGB565 cells). We 2x2
# block-average to an 11x7 grid, then build two feature families on it:
#   * luma LBP   -- 8 "neighbour brightness >= centre" bits per interior cell (texture)
#   * colour     -- 3 chroma bits per cell: R>G, R>B, and a skin cue (R>G>=B & R-B>=2)
# Colour is the big discriminator for faces vs background (ablation: +7% over LBP-only).
ROI_COLS = 22
ROI_ROWS = 14
DS = 2
DSW = ROI_COLS // DS                  # 11
DSH = ROI_ROWS // DS                  # 7
LBP_CELLS = (DSW - 2) * (DSH - 2)     # 9*5 = 45 interior cells
COLOR_CELLS = DSW * DSH               # 11*7 = 77 cells
N_LBP = LBP_CELLS * 8                 # 360 luma LBP bits
N_FEATURES = N_LBP + 3 * COLOR_CELLS  # 360 + 231 = 591
# neighbour scan order (dr, dc): TL, T, TR, L, R, BL, B, BR -- MUST match roi_tm.c
LBP_OFFSETS = ((-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1))


def _downsample_channels(roi565):
    """ROI RGB565 -> 2x2-block-summed channels, then scaled to (DSH,DSW) grids:
    brightness (0..125), R (0..31), G->5bit (0..31), B (0..31). All integer, exactly
    reproducible on the MCU (per-block sums >> shift)."""
    a = np.asarray(roi565, dtype=np.int32).reshape(ROI_ROWS, ROI_COLS)
    R = (a >> 11) & 0x1F
    G = (a >> 5) & 0x3F
    B = a & 0x1F
    blk = lambda ch: ch.reshape(DSH, DS, DSW, DS).sum(axis=(1, 3))   # noqa: E731
    Rs, Gs, Bs = blk(R), blk(G), blk(B)
    return (Rs + Gs + Bs) >> 2, Rs >> 2, Gs >> 3, Bs >> 2            # bright, r, g5, b


def featurize(roi565):
    """Luma-LBP + colour boolean features of the ROI patch (N_FEATURES,) bool.

    Layout (MUST match roi_tm.c): [0..359] 8-neighbour LBP over the downsampled
    brightness interior (LBP_OFFSETS order); then per-cell colour bits over all
    DSH*DSW cells, row-major: [360..436] R>G, [437..513] R>B, [514..590] skin.
    `roi565` is the row-major ROI patch as stored by collect_samples.
    """
    bright, r, g5, b = _downsample_channels(roi565)
    feats = np.zeros(N_FEATURES, dtype=bool)
    idx = 0
    for rr in range(1, DSH - 1):
        for cc in range(1, DSW - 1):
            ctr = bright[rr, cc]
            for dr, dc in LBP_OFFSETS:
                feats[idx] = bright[rr + dr, cc + dc] >= ctr
                idx += 1
    feats[idx:idx + COLOR_CELLS] = (r > g5).reshape(-1)
    idx += COLOR_CELLS
    feats[idx:idx + COLOR_CELLS] = (r > b).reshape(-1)
    idx += COLOR_CELLS
    feats[idx:idx + COLOR_CELLS] = ((r > g5) & (g5 >= b) & ((r - b) >= 2)).reshape(-1)
    return feats


def featurize_matrix(rois):
    """featurize() over a list of ROI patches -> (samples, N_FEATURES) bool matrix."""
    return np.stack([featurize(r) for r in rois]).astype(bool)


def augment(roi565, rng, bright=(0.55, 1.7), wb=0.15, contrast=(0.75, 1.30), flip=True):
    """Photometrically augment an ROI patch (in RGB565 space) for luminance/colour
    robustness. Simulates what varies on the device but not in the dataset: exposure
    /lighting (global gain), the OV7670's wobbly white balance (per-channel gain),
    contrast, and left/right pose (flip). Returns a new RGB565 patch (list of ints).

    The colour features (R>G, R>B, skin R-B>=2) are the luminance-sensitive ones --
    a global gain barely moves R>G but shrinks the absolute R-B at low light, so
    training across gains teaches the threshold to generalise."""
    a = np.asarray(roi565, dtype=np.int64).reshape(ROI_ROWS, ROI_COLS)
    R = ((a >> 11) & 0x1F) * (255.0 / 31)
    G = ((a >> 5) & 0x3F) * (255.0 / 63)
    B = (a & 0x1F) * (255.0 / 31)
    if flip and rng.random() < 0.5:
        R, G, B = R[:, ::-1], G[:, ::-1], B[:, ::-1]
    g = rng.uniform(*bright)
    R *= g * rng.uniform(1 - wb, 1 + wb)        # global gain + per-channel WB jitter
    G *= g * rng.uniform(1 - wb, 1 + wb)
    B *= g * rng.uniform(1 - wb, 1 + wb)
    c = rng.uniform(*contrast)
    R = (R - 128) * c + 128
    G = (G - 128) * c + 128
    B = (B - 128) * c + 128
    r5 = np.clip(R, 0, 255).astype(np.int64) >> 3
    g6 = np.clip(G, 0, 255).astype(np.int64) >> 2
    b5 = np.clip(B, 0, 255).astype(np.int64) >> 3
    return ((r5 << 11) | (g6 << 5) | b5).reshape(-1).tolist()


def nwords(nlit):
    return (nlit + 31) // 32


def pack_bits(bits):
    """Pack a 1-D bool array into uint32 words, LSB-first (bit k -> word k>>5, k&31).

    The exact layout the MCU uses for both the literal vector and the clause masks.
    """
    words = np.zeros(nwords(bits.shape[0]), dtype=np.uint32)
    for k in np.nonzero(bits)[0]:
        words[k >> 5] |= np.uint32(1) << np.uint32(int(k) & 31)
    return words


def pack_literals(feat):
    """Feature bits (N,) -> packed literal words (2N bits: feat then ~feat)."""
    n = feat.shape[0]
    lit = np.zeros(2 * n, dtype=bool)
    lit[:n] = feat
    lit[n:] = ~feat
    return pack_bits(lit)


def infer_packed(masks, litwords, pos, threshold=THRESHOLD):
    """The exact bitwise inference the MCU runs. Returns (predict, vote).

    `masks` is (clauses, nwords) uint32 clause include-masks; `litwords` is the
    packed literal vector for one sample; the first `pos` clauses vote +1, the rest
    -1. A clause fires iff every included literal is 1, i.e. (lit & mask) == mask in
    every word (an empty mask always fires -> a constant vote, exactly as on-MCU).
    """
    fires = np.all((litwords[None, :] & masks) == masks, axis=1)   # (clauses,)
    vote = int(fires[:pos].sum()) - int(fires[pos:].sum())
    return (1 if vote >= threshold else 0), vote


class TsetlinMachine:
    """A vanilla two-class Tsetlin Machine (Granmo 2018), trained on the host.

    Clauses 0..pos-1 vote +1 (recognise the positive class), pos..M-1 vote -1.
    Each clause keeps a Tsetlin automaton per literal (state in [1, 2*states]);
    a literal is INCLUDED when its state > states. Training nudges those automata
    with Type I feedback (reinforce firing patterns) and Type II feedback (make
    wrongly-firing clauses stop), the standard TM scheme.
    """

    def __init__(self, n_features, clauses=DEFAULT_CLAUSES, states=DEFAULT_STATES,
                 s=DEFAULT_S, T=DEFAULT_T, boost_true_positive=True, seed=1):
        if clauses % 2:
            raise ValueError("clauses must be even (half positive, half negative)")
        self.n = n_features
        self.nlit = 2 * n_features
        self.m = clauses
        self.pos = clauses // 2
        self.states = states
        self.s = float(s)
        self.T = int(T)
        self.boost = boost_true_positive
        self.rng = np.random.default_rng(seed)
        # start every automaton just on the exclude side -> clauses begin empty
        self.ta = np.full((self.m, self.nlit), states, dtype=np.int16)
        # +1 for positive clauses, -1 for negative
        self.polarity = np.where(np.arange(self.m) < self.pos, 1, -1)

    def _include(self):
        return self.ta > self.states

    def _clause_outputs(self, lit, include):
        # clause fires unless an included literal is 0
        viol = include & (~lit)[None, :]
        return ~viol.any(axis=1)

    def _update_one(self, x, y):
        lit = np.concatenate([x, ~x])          # (N,) features -> (2N,) literals
        include = self._include()
        out = self._clause_outputs(lit, include)
        vote = int(np.dot(out.astype(np.int32), self.polarity))
        v = max(-self.T, min(self.T, vote))

        if y == 1:
            p = (self.T - v) / (2.0 * self.T)
            type1 = self.polarity == 1          # positive clauses reinforce class 1
        else:
            p = (self.T + v) / (2.0 * self.T)
            type1 = self.polarity == -1         # negative clauses reinforce class 0
        feedback = self.rng.random(self.m) < p
        t1 = feedback & type1                   # Type I clauses this sample
        t2 = feedback & ~type1                  # Type II clauses this sample

        inv_s = 1.0 / self.s
        inc_p = 1.0 if self.boost else (self.s - 1.0) / self.s
        r = self.rng.random((self.m, self.nlit))
        litrow = lit[None, :]
        o = out[:, None]

        # ---- Type I (reinforce firing patterns) ----
        inc1 = t1[:, None] & o & litrow & (r < inc_p)              # present literal -> include
        dec1 = t1[:, None] & ((o & ~litrow) | ~o) & (r < inv_s)    # absent / non-firing -> forget
        # ---- Type II (stop wrong firings: include a literal that is 0) ----
        inc2 = t2[:, None] & o & (~litrow) & ~include

        self.ta += inc1.astype(np.int16) + inc2.astype(np.int16) - dec1.astype(np.int16)
        np.clip(self.ta, 1, 2 * self.states, out=self.ta)

    def fit(self, X, Y, epochs=DEFAULT_EPOCHS, log=None):
        X = np.asarray(X, dtype=bool)
        Y = np.asarray(Y, dtype=np.int8)
        for ep in range(epochs):
            order = self.rng.permutation(X.shape[0])
            for i in order:
                self._update_one(X[i], int(Y[i]))
            if log and (ep % max(1, epochs // 10) == 0 or ep == epochs - 1):
                acc = (self.predict(X) == Y).mean()
                log(ep, acc)
        return self

    def masks(self):
        """Packed clause include-masks (clauses, nwords) uint32 -- the exported model."""
        include = self._include()
        return np.stack([pack_bits(include[j]) for j in range(self.m)])

    def predict(self, X):
        masks = self.masks()
        X = np.asarray(X, dtype=bool)
        out = np.empty(X.shape[0], dtype=np.int8)
        for i in range(X.shape[0]):
            out[i], _ = infer_packed(masks, pack_literals(X[i]), self.pos)
        return out


def clause_literals(masks):
    """Packed dense masks -> per-clause sorted lists of included literal indices."""
    m, w = masks.shape
    out = []
    for j in range(m):
        idx = []
        for word in range(w):
            v = int(masks[j][word])
            while v:
                lsb = v & (-v)
                idx.append(word * 32 + lsb.bit_length() - 1)
                v ^= lsb
        out.append(idx)
    return out


def export_header(path, masks, n_features, pos, threshold=THRESHOLD, meta=""):
    """Write tm_model.h in a SPARSE (CSR) form: per-clause counts + the concatenated
    included-literal indices. Each clause includes only ~15 of ~1200 literals, so the
    dense [clauses][nwords] table is ~90% zeros; this is ~4-5x smaller and lets
    inference iterate only the included literals (no all-zero word compares)."""
    m, w = masks.shape
    lits = clause_literals(masks)
    lens = [len(c) for c in lits]
    flat = [L for c in lits for L in c]
    total = len(flat)

    def arr(name, ctype, values):
        rows = [", ".join(str(v) for v in values[i:i + 20]) for i in range(0, len(values), 20)]
        body = ",\n    ".join(rows) if rows else "0"
        return [f"static const {ctype} {name} = {{", f"    {body}", "};"]

    lines = [
        "/* GENERATED by demo_mcu_apps/roi_tm/train_tm.py -- do not edit by hand.",
        " * Regenerate after collecting/retraining: it bakes the trained Tsetlin",
        " * Machine clause masks (sparse) into the roi_tm overlay.",
    ]
    if meta:
        lines += [" *", " * " + meta.replace("\n", "\n * ")]
    lines += [
        " */",
        "#ifndef TM_MODEL_H",
        "#define TM_MODEL_H",
        "",
        f"#define TM_N          {n_features}   /* boolean features (luma LBP + colour) */",
        f"#define TM_NLIT       {2 * n_features}   /* literals: feature then negation */",
        f"#define TM_NWORDS     {w}   /* uint32 words per literal vector (lit[] sizing) */",
        f"#define TM_CLAUSES    {m}",
        f"#define TM_POS        {pos}   /* clauses 0..TM_POS-1 vote +1, rest vote -1 */",
        f"#define TM_THRESHOLD  {threshold}   /* face when vote >= TM_THRESHOLD */",
        f"#define TM_TOTAL_LITS {total}   /* sum of included literals over all clauses */",
        "",
        "/* CSR sparse model: clause j includes tm_clause_len[j] literals, whose indices",
        " * are the next tm_clause_len[j] entries of tm_lit. A clause fires iff all its",
        " * included literals are 1; an empty clause (len 0) always fires. */",
    ]
    lines += arr("tm_clause_len[TM_CLAUSES]", "unsigned short", lens)
    lines += [""]
    lines += arr("tm_lit[TM_TOTAL_LITS]", "unsigned short", flat)
    lines += ["", "#endif /* TM_MODEL_H */", ""]
    with open(path, "w") as f:
        f.write("\n".join(lines))
