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


def featurize(roi565):
    """One boolean feature per ROI cell: brighter than the ROI mean.

    Uses b[i]*N > sum(b) (integer-exact, division-free) so the MCU produces the
    identical bit. `roi565` is the row-major ROI patch as stored by collect_samples.
    Returns a (N,) bool array.
    """
    b = np.asarray([brightness(int(p)) for p in roi565], dtype=np.int64)
    n = b.shape[0]
    return (b * n) > int(b.sum())


def featurize_matrix(rois):
    """featurize() over a list of ROI patches -> (samples, N) bool matrix."""
    return np.stack([featurize(r) for r in rois]).astype(bool)


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


def export_header(path, masks, n_features, pos, threshold=THRESHOLD, meta=""):
    """Write tm_model.h: the packed clause masks + sizes the MCU inference needs."""
    m, w = masks.shape
    lines = [
        "/* GENERATED by demo_mcu_apps/roi_tm/train_tm.py -- do not edit by hand.",
        " * Regenerate after collecting/retraining: it bakes the trained Tsetlin",
        " * Machine clause masks into the roi_tm overlay.",
    ]
    if meta:
        lines += [" *", " * " + meta.replace("\n", "\n * ")]
    lines += [
        " */",
        "#ifndef TM_MODEL_H",
        "#define TM_MODEL_H",
        "",
        f"#define TM_N         {n_features}   /* ROI cells == features */",
        f"#define TM_NLIT      {2 * n_features}   /* literals: feature then negation */",
        f"#define TM_NWORDS    {w}   /* uint32 words per literal/clause vector */",
        f"#define TM_CLAUSES   {m}",
        f"#define TM_POS       {pos}   /* clauses 0..TM_POS-1 vote +1, rest vote -1 */",
        f"#define TM_THRESHOLD {threshold}   /* face when vote >= TM_THRESHOLD */",
        "",
        "static const unsigned int tm_mask[TM_CLAUSES][TM_NWORDS] = {",
    ]
    for j in range(m):
        vals = ", ".join(f"0x{int(v):08x}u" for v in masks[j])
        lines.append(f"    {{ {vals} }},")
    lines += ["};", "", "#endif /* TM_MODEL_H */", ""]
    with open(path, "w") as f:
        f.write("\n".join(lines))
