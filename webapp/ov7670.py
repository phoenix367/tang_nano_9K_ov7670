"""OV7670 register map and a declarative model of the user-facing controls.

Each control maps to one register (or, for the test pattern, two, and for the
gamma curve, sixteen). Bit-field controls are applied read-modify-write so
unrelated bits are preserved. Register addresses match src/ov7670_regs.vh.
"""

import math

# Read-only identity registers (address, label, expected value for an OV7670)
IDENTITY = [
    (0x0A, "Product ID (PID)", 0x76),
    (0x0B, "Version (VER)", 0x73),
    (0x1C, "Manufacturer ID high (MIDH)", 0x7F),
    (0x1D, "Manufacturer ID low (MIDL)", 0xA2),
]

# Test pattern spans SCALING_XSC[7] (0x70) and SCALING_YSC[7] (0x71). The low
# bits hold the scaling values and must be preserved (defaults 0x3A / 0x35).
PATTERN_REGS = (0x70, 0x71)
PATTERN_OPTIONS = [
    {"id": "none",      "label": "None (live image)", "xsc": 0, "ysc": 0},
    {"id": "colorbar",  "label": "8-bar color bar",   "xsc": 0, "ysc": 1},
    {"id": "shifting1", "label": "Shifting \"1\"",     "xsc": 1, "ysc": 0},
    {"id": "fadegray",  "label": "Fade to gray bars", "xsc": 1, "ysc": 1},
]

# Gamma curve: COM13[7] enables it; SLOP (0x7A) + GAM1..GAM15 (0x7B..0x89) are a
# 15-knee piecewise-linear curve. The curve is generated from a single exponent
# g: out = 255*(in/255)^g  (g<1 brightens midtones, ~0.45 is standard gamma
# correction, g>1 darkens). GAM_i is the output at the fixed input breakpoints
# below; SLOP is the slope of the final segment up to full scale. The current
# exponent is estimated from one mid-curve breakpoint readback (the curve can't
# be cheaply round-tripped exactly, but this positions the slider sensibly).
GAMMA_ENABLE_REG = 0x3D
GAMMA_ENABLE_MASK = 0x80
SLOP_REG = 0x7A
GAM_BASE = 0x7B
GAM_BREAKPOINTS = [4, 8, 16, 32, 40, 48, 56, 64, 72, 80, 96, 112, 144, 176, 208]
GAMMA_SAMPLE_INDEX = 7          # breakpoint x=64 -> GAM8 -> 0x82
GAMMA_SCALE = 100               # exponent is carried as round(g*100)
GAMMA_MIN = 30                  # g = 0.30
GAMMA_MAX = 250                 # g = 2.50
GAMMA_DEFAULT = 45              # g = 0.45 (standard correction)


# The OV7670 encodes the final-segment slope as slope*64 (1/64 LSB units): the
# default curve (GAM15=0xE5, SLOP=0x24) reaches full scale only under this
# scaling, and a linear curve maps to SLOP=0x40.
SLOP_UNIT = 64


def gamma_register_addrs():
    """All gamma register addresses, SLOP first then GAM1..GAM15."""
    return [SLOP_REG] + [GAM_BASE + i for i in range(len(GAM_BREAKPOINTS))]


def gamma_registers(exponent):
    """{addr: byte} for SLOP + GAM1..GAM15 implementing out=255*(in/255)^g."""
    g = max(0.10, float(exponent))
    regs = {}
    last_y = 0
    for i, x in enumerate(GAM_BREAKPOINTS):
        y = max(0, min(255, round(255 * (x / 255.0) ** g)))
        regs[GAM_BASE + i] = y
        last_y = y
    x_last = GAM_BREAKPOINTS[-1]
    slope = round(SLOP_UNIT * (255 - last_y) / (255 - x_last))
    regs[SLOP_REG] = max(0, min(255, slope))
    return regs


def gamma_curve_points(regs):
    """Reconstruct the piecewise-linear curve vertices [[x, y], ...] the
    hardware produces from a {addr: byte} gamma register set: origin, the 15
    knee points, then the SLOP-defined final segment extrapolated to input 255.
    """
    pts = [[0, 0]]
    for i, x in enumerate(GAM_BREAKPOINTS):
        pts.append([x, regs.get(GAM_BASE + i, 0)])
    last_y = regs.get(GAM_BASE + len(GAM_BREAKPOINTS) - 1, 0)
    x_last = GAM_BREAKPOINTS[-1]
    slope = regs.get(SLOP_REG, 0) / float(SLOP_UNIT)
    y_end = max(0, min(255, round(last_y + slope * (255 - x_last))))
    pts.append([255, y_end])
    return pts


def estimate_gamma(snapshot):
    """Estimate g*GAMMA_SCALE from a mid-curve breakpoint readback."""
    x = GAM_BREAKPOINTS[GAMMA_SAMPLE_INDEX]
    y = snapshot.get(GAM_BASE + GAMMA_SAMPLE_INDEX)
    if not y or y <= 0 or y >= 255:
        return GAMMA_SCALE          # g = 1.0 fallback
    try:
        g = math.log(y / 255.0) / math.log(x / 255.0)
    except (ValueError, ZeroDivisionError):
        return GAMMA_SCALE
    return max(GAMMA_MIN, min(GAMMA_MAX, round(g * GAMMA_SCALE)))


# Color correction matrix: MTX1..MTX6 (0x4F..0x54) are 8-bit magnitudes; MTXS
# (0x58) holds a sign bit per coefficient (bit i = MTX(i+1), 1 = negative) plus
# bit 7 = auto contrast-center adjust. The six coefficients form a 2x3 matrix
# that generates the two chroma channels from RGB (row 0 ~ Cr/R-Y, row 1 ~
# Cb/B-Y), scaled by 1/256 -- the canonical default (80 80 00 22 5E 80 / 9E)
# matches the BT.601 chroma generators, so it reproduces colors faithfully.
# Bridge status registers (served by modbus_cam_backend, not the camera).
STATUS_MAGIC_ADDR = 0xF0     # reads firmware magic 0xA5
STATUS_MAGIC = 0xA5
STATUS_UPTIME_ADDR = 0xF1    # 0xF1 = uptime hi, 0xF2 = uptime lo (16-bit, 0 on reset)

MTX_REGS = [0x4F, 0x50, 0x51, 0x52, 0x53, 0x54]
MTXS_REG = 0x58
MTX_SCALE = 256
MTXS_AUTO_CONTRAST = 0x80       # MTXS[7]
MATRIX_ROWS = ["Cr (R−Y)", "Cb (B−Y)"]
MATRIX_COLS = ["R", "G", "B"]

# Reference colors for the before->after swatches (sRGB 0..255).
MATRIX_REF_COLORS = [
    ("White", (255, 255, 255)),
    ("Red", (255, 0, 0)),
    ("Green", (0, 255, 0)),
    ("Blue", (0, 0, 255)),
    ("Cyan", (0, 255, 255)),
    ("Magenta", (255, 0, 255)),
    ("Yellow", (255, 255, 0)),
    ("Skin", (240, 184, 160)),
    ("Gray", (128, 128, 128)),
]


def _clamp8(x):
    return max(0, min(255, int(round(x))))


def decode_matrix(snapshot):
    """Return (signed_coeffs[6], coeff_meta[6], mtxs) from a register snapshot."""
    mtxs = snapshot.get(MTXS_REG, 0)
    signed, meta = [], []
    for i, addr in enumerate(MTX_REGS):
        mag = snapshot.get(addr, 0)
        neg = bool(mtxs & (1 << i))
        val = -mag if neg else mag
        signed.append(val)
        meta.append({
            "index": i, "addr": addr, "raw": mag, "neg": neg, "signed": val,
            "value": round(val / float(MTX_SCALE), 3),
        })
    return signed, meta, mtxs


def matrix_apply(signed, r, g, b):
    """Apply the 2x3 chroma matrix to an sRGB triple and reconstruct RGB
    (BT.601 luma + the matrix-generated Cr/Cb). Approximate but faithful at the
    default matrix."""
    y = 0.299 * r + 0.587 * g + 0.114 * b
    cr = (signed[0] * r + signed[1] * g + signed[2] * b) / float(MTX_SCALE)
    cb = (signed[3] * r + signed[4] * g + signed[5] * b) / float(MTX_SCALE)
    return [
        _clamp8(y + 1.402 * cr),
        _clamp8(y - 0.344 * cb - 0.714 * cr),
        _clamp8(y + 1.772 * cb),
    ]


def matrix_swatches(signed):
    """before->after chips for each reference color."""
    return [
        {"name": name, "in": list(rgb), "out": matrix_apply(signed, *rgb)}
        for name, rgb in MATRIX_REF_COLORS
    ]


# Declarative control list. Types:
#   byte    - full 8-bit value (slider 0..255)
#   bit     - single bit within `reg` (checkbox), applied read-modify-write
#   pattern - the two-register test-pattern selector (dropdown)
#   gamma   - SLOP + GAM1..GAM15 generated from an exponent (scaled slider)
CONTROLS = [
    {"id": "brightness", "name": "Brightness", "type": "byte", "reg": 0x55,
     "help": "BRIGHT (0x55). Signed magnitude; 0x00 darkest .. 0xFF brightest."},
    {"id": "contrast", "name": "Contrast", "type": "byte", "reg": 0x56,
     "help": "CONTRAS (0x56)."},
    {"id": "gain", "name": "Gain", "type": "byte", "reg": 0x00,
     "help": "GAIN (0x00). Takes effect only when Auto Gain (AGC) is off."},
    {"id": "exposure", "name": "Exposure", "type": "byte", "reg": 0x10,
     "help": "AECH (0x10), exposure 9:2. Takes effect only when Auto "
             "Exposure (AEC) is off."},

    {"id": "agc", "name": "Auto Gain (AGC)", "type": "bit", "reg": 0x13,
     "mask": 0x04, "help": "COM8[2]."},
    {"id": "awb", "name": "Auto White Balance (AWB)", "type": "bit",
     "reg": 0x13, "mask": 0x02, "help": "COM8[1]."},
    {"id": "aec", "name": "Auto Exposure (AEC)", "type": "bit", "reg": 0x13,
     "mask": 0x01, "help": "COM8[0]."},

    {"id": "mirror", "name": "Mirror (horizontal)", "type": "bit", "reg": 0x1E,
     "mask": 0x20, "help": "MVFP[5]."},
    {"id": "vflip", "name": "Vertical flip", "type": "bit", "reg": 0x1E,
     "mask": 0x10, "help": "MVFP[4]."},

    {"id": "negative", "name": "Negative image", "type": "bit", "reg": 0x3A,
     "mask": 0x20, "help": "TSLB[5]."},
    {"id": "night", "name": "Night mode", "type": "bit", "reg": 0x3B,
     "mask": 0x80, "help": "COM11[7]."},

    {"id": "gamma_enable", "name": "Gamma correction", "type": "bit",
     "reg": GAMMA_ENABLE_REG, "mask": GAMMA_ENABLE_MASK, "help": "COM13[7]."},
    {"id": "gamma", "name": "Gamma curve", "type": "gamma",
     "sample_reg": GAM_BASE + GAMMA_SAMPLE_INDEX,
     "min": GAMMA_MIN, "max": GAMMA_MAX, "step": 5, "scale": GAMMA_SCALE,
     "default": GAMMA_DEFAULT,
     "help": "Writes SLOP + GAM1..15. out = 255*(in/255)^g; "
             "<1 brightens, 1.0 linear, >1 darkens (~0.45 standard). "
             "Enable gamma correction for it to take effect."},

    {"id": "pattern", "name": "Test pattern", "type": "pattern",
     "regs": list(PATTERN_REGS), "options": PATTERN_OPTIONS,
     "help": "SCALING_XSC[7] (0x70) + SCALING_YSC[7] (0x71)."},
]

CONTROLS_BY_ID = {c["id"]: c for c in CONTROLS}


def needed_registers():
    """Every register address the settings page reads, de-duplicated, sorted."""
    regs = {a for a, _, _ in IDENTITY}
    for c in CONTROLS:
        if c["type"] == "pattern":
            regs.update(c["regs"])
        elif c["type"] == "gamma":
            regs.add(c["sample_reg"])   # only the breakpoint used for estimation
        else:
            regs.add(c["reg"])
    return sorted(regs)


def decode_control(control, snapshot):
    """Current value of `control` from a {addr: byte} snapshot."""
    if control["type"] == "byte":
        return snapshot.get(control["reg"], 0)
    if control["type"] == "bit":
        return bool(snapshot.get(control["reg"], 0) & control["mask"])
    if control["type"] == "pattern":
        xsc = 1 if snapshot.get(PATTERN_REGS[0], 0) & 0x80 else 0
        ysc = 1 if snapshot.get(PATTERN_REGS[1], 0) & 0x80 else 0
        for opt in PATTERN_OPTIONS:
            if opt["xsc"] == xsc and opt["ysc"] == ysc:
                return opt["id"]
        return "none"
    if control["type"] == "gamma":
        return estimate_gamma(snapshot)
    raise ValueError(f"unknown control type {control['type']}")


def decode_all(snapshot):
    """Decode the identity block and every control from a register snapshot."""
    identity = [
        {
            "addr": a,
            "label": label,
            "value": snapshot.get(a),
            "expected": exp,
            "ok": snapshot.get(a) == exp,
        }
        for a, label, exp in IDENTITY
    ]
    controls = {c["id"]: decode_control(c, snapshot) for c in CONTROLS}
    return {"identity": identity, "controls": controls}
