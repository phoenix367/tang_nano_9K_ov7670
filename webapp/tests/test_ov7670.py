"""Tests for the OV7670 control model: register set, decode, gamma curve math,
and the color-matrix decode/transform."""

import ov7670
from fake_modbus import default_registers


def test_needed_registers_covers_identity_and_controls():
    regs = set(ov7670.needed_registers())
    for a in (0x0A, 0x0B, 0x1C, 0x1D):          # identity
        assert a in regs
    for a in (0x55, 0x56, 0x00, 0x10, 0x13, 0x1E, 0x3A, 0x3B, 0x3D, 0x70, 0x71):
        assert a in regs
    assert (ov7670.GAM_BASE + ov7670.GAMMA_SAMPLE_INDEX) in regs   # gamma estimate breakpoint
    assert 0xF0 not in regs                      # status regs are health-only, not settings


def test_decode_all_identity_and_controls():
    d = ov7670.decode_all(default_registers())
    ident = {row["addr"]: row for row in d["identity"]}
    assert ident[0x0A]["value"] == 0x76 and ident[0x0A]["ok"]
    c = d["controls"]
    assert c["agc"] is True and c["awb"] is True and c["aec"] is True   # COM8=0xE7
    assert c["mirror"] is False and c["vflip"] is False                 # MVFP=0x00
    assert c["brightness"] == 0x80
    assert c["pattern"] == "none"                                       # 0x70/0x71 no bit7


def test_decode_pattern_colorbar():
    snap = default_registers()
    snap[0x71] |= 0x80                            # SCALING_YSC test bit -> color bar
    assert ov7670.decode_all(snap)["controls"]["pattern"] == "colorbar"


def test_gamma_linear_reproduces_breakpoints():
    regs = ov7670.gamma_registers(1.0)
    gam = [regs[ov7670.GAM_BASE + i] for i in range(len(ov7670.GAM_BREAKPOINTS))]
    assert gam == ov7670.GAM_BREAKPOINTS          # out = in
    assert regs[ov7670.SLOP_REG] == 0x40          # slope 1.0 * 64


def test_gamma_curve_is_monotonic():
    for g in (0.30, 0.45, 1.0, 2.2):
        regs = ov7670.gamma_registers(g)
        gam = [regs[ov7670.GAM_BASE + i] for i in range(len(ov7670.GAM_BREAKPOINTS))]
        assert all(gam[i] <= gam[i + 1] for i in range(len(gam) - 1))


def test_gamma_estimate_roundtrips():
    for v in (40, 45, 100, 220):
        regs = ov7670.gamma_registers(v / ov7670.GAMMA_SCALE)
        assert abs(ov7670.estimate_gamma(regs) - v) <= 3


def test_gamma_curve_points_shape():
    pts = ov7670.gamma_curve_points(ov7670.gamma_registers(1.0))
    assert len(pts) == len(ov7670.GAM_BREAKPOINTS) + 2     # origin + knees + endpoint
    assert pts[0] == [0, 0]
    assert pts[-1][0] == 255 and pts[-1][1] == 255          # linear reaches full scale


def test_matrix_decode_default():
    signed, meta, mtxs = ov7670.decode_matrix(default_registers())
    assert signed == [128, -128, 0, -34, -94, 128]
    assert mtxs == 0x9E
    assert len(meta) == 6


def test_matrix_apply_reproduces_colors_at_default():
    signed, _, _ = ov7670.decode_matrix(default_registers())
    assert ov7670.matrix_apply(signed, 255, 255, 255) == [255, 255, 255]
    assert ov7670.matrix_apply(signed, 128, 128, 128) == [128, 128, 128]   # gray stays gray
    r = ov7670.matrix_apply(signed, 255, 0, 0)
    assert r[0] > 240 and r[1] < 16                                        # red stays red-ish


def test_matrix_swatches_cover_all_refs():
    signed, _, _ = ov7670.decode_matrix(default_registers())
    sw = ov7670.matrix_swatches(signed)
    assert len(sw) == len(ov7670.MATRIX_REF_COLORS)
    assert all("in" in s and "out" in s and "name" in s for s in sw)
