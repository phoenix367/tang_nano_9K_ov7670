#!/usr/bin/env python3
"""Generate the 8x16 OSD font table from a PC-VGA console bitmap font.

Reads a Linux console PSF font (the classic IBM-VGA 8x16 text-mode bitmap, e.g.
/usr/share/consolefonts/FullGreek-VGA16.psf.gz from the `kbd` package) and emits
src/font8x16_init.vh: 4096 assignments (font[glyph*16 + row] = 8'hXX;,
MSB = leftmost pixel) that initialise the OSD font ROM. PSF glyphs are already
8 wide x 16 tall, row-major, MSB-left -- a direct match for the ROM layout, so
the glyphs are pixel-crisp (no anti-alias/threshold fuzz from rendering a TTF).

PSF fonts carry a Unicode table; we map each Latin-1 codepoint 0x00..0xFF to its
glyph so the table matches the bytes the host sends (modbus_client uses Latin-1).
Control codes (0x00-0x1F, 0x7F-0x9F), space (0x20) and NBSP (0xA0) render blank.

Box-drawing / block "pseudographics" have no Latin-1 codepoint, so they are placed
in the otherwise-unused C1 range (0x80..0x9F) per webapp/osd_charset.py. Most are
in the VGA PSF (looked up by their Unicode char); the few half-block / dark-shade
glyphs the font lacks are synthesised geometrically (see SYNTH).

Using an `include keeps the path resolvable by both Icarus (-I src) and Gowin
(relative to the source file), unlike $readmemh.
"""
import gzip
import os
import struct
import sys

# webapp/osd_charset.py is the shared char->byte contract (no pyserial dep).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "webapp"))
from osd_charset import PSEUDOGRAPHICS  # noqa: E402

# Glyphs the VGA PSF lacks, synthesised as 16 row bitmaps (MSB = leftmost pixel).
SYNTH = {
    "▀": [0xFF] * 8 + [0x00] * 8,                 # upper half block
    "▄": [0x00] * 8 + [0xFF] * 8,                 # lower half block
    "▌": [0xF0] * 16,                             # left half block
    "▐": [0x0F] * 16,                             # right half block
    "▓": [0xDD, 0x77] * 8,                        # dark shade (dense dither)
}

# Source console font (override with argv[1]). FullGreek-VGA16 is the IBM-VGA 8x16
# typeface with a full repertoire: the same Latin glyphs as Lat15-VGA16 plus the
# genuine double-line box-drawing and half-block glyphs the stripped Lat15 lacks.
DEFAULT_FONT = "/usr/share/consolefonts/FullGreek-VGA16.psf.gz"
W, H = 8, 16
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "src", "font8x16_init.vh")

PSF1_MAGIC = b"\x36\x04"
PSF1_MODEHASTAB = 0x02
PSF1_MODEHASSEQ = 0x04
PSF1_SEPARATOR = 0xFFFF
PSF1_STARTSEQ = 0xFFFE

PSF2_MAGIC = b"\x72\xb5\x4a\x86"
PSF2_HAS_UNICODE_TABLE = 0x01
PSF2_SEPARATOR = 0xFFFF
PSF2_STARTSEQ = 0xFFFE


def is_printable(code):
    return (0x20 < code <= 0x7E) or (0xA0 < code <= 0xFF)


def read_font(path):
    raw = gzip.open(path, "rb").read() if path.endswith(".gz") else open(path, "rb").read()

    if raw[:2] == PSF1_MAGIC:
        mode, charsize = raw[2], raw[3]
        count = 512 if (mode & 0x01) else 256
        glyph_h = charsize
        glyphs = [raw[4 + i * charsize: 4 + (i + 1) * charsize] for i in range(count)]
        rest = raw[4 + count * charsize:]
        has_tab = bool(mode & PSF1_MODEHASTAB)
        unit, sep, startseq = 2, PSF1_SEPARATOR, PSF1_STARTSEQ
    elif raw[:4] == PSF2_MAGIC:
        (_version, hdr, flags, count, charsize,
         glyph_h, glyph_w) = struct.unpack("<7I", raw[4:32])
        glyphs = [raw[hdr + i * charsize: hdr + (i + 1) * charsize] for i in range(count)]
        rest = raw[hdr + count * charsize:]
        has_tab = bool(flags & PSF2_HAS_UNICODE_TABLE)
        unit, sep, startseq = 4, PSF2_SEPARATOR, PSF2_STARTSEQ
        if glyph_w != W:
            sys.exit(f"font is {glyph_w}px wide, need {W}")
    else:
        sys.exit("not a PSF1/PSF2 font")

    if glyph_h != H:
        sys.exit(f"font is {glyph_h}px tall, need {H}")

    # Unicode table: per glyph, a run of codepoints terminated by `sep`
    # (`startseq` begins a multi-codepoint sequence we ignore). Build code->glyph.
    code_to_glyph = {}
    if has_tab:
        gi, i = 0, 0
        while gi < len(glyphs) and i < len(rest):
            cp = int.from_bytes(rest[i:i + unit], "little")
            i += unit
            if cp == sep:
                gi += 1
            elif cp == startseq:
                while i < len(rest):
                    nxt = int.from_bytes(rest[i:i + unit], "little")
                    i += unit
                    if nxt in (sep, startseq):
                        if nxt == sep:
                            gi += 1
                        break
            else:
                code_to_glyph.setdefault(cp, gi)
    else:
        code_to_glyph = {i: i for i in range(len(glyphs))}   # identity (CP order)

    return glyphs, code_to_glyph


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_FONT
    glyphs, code_to_glyph = read_font(path)
    blank = bytes(H)

    # font ROM as one byte-bitmap per (code, row). Latin-1 first, then overlay
    # the pseudographics into their C1 codes (PSF glyph, or a synthesised one).
    rom = [blank] * 256
    for code in range(256):
        if is_printable(code) and code in code_to_glyph:
            rom[code] = glyphs[code_to_glyph[code]]
    pseudo_missing = []
    for ch, code in PSEUDOGRAPHICS:
        if ord(ch) in code_to_glyph:
            rom[code] = glyphs[code_to_glyph[ord(ch)]]   # genuine glyph from the font
        elif ch in SYNTH:
            rom[code] = bytes(SYNTH[ch])                 # fallback for stripped fonts
        else:
            pseudo_missing.append(ch)
    if pseudo_missing:
        sys.exit(f"font lacks pseudographics and no SYNTH: {''.join(pseudo_missing)}")

    lines = [
        "// Auto-generated by scripts/font_generator.py -- do not edit.",
        f"// 8x16 OSD font from {os.path.basename(path)} (IBM-VGA bitmap), 256 glyphs.",
        "// 0x00-0xFF Latin-1; 0x80-0x9F overlaid with box-drawing/block pseudographics.",
        "// font[glyph*16 + row] = row bitmap, MSB = leftmost pixel.",
    ]
    for code in range(256):
        rows = rom[code]
        for r in range(H):
            lines.append(f"font['h{code * 16 + r:03X}] = 8'h{rows[r]:02X};")

    with open(OUT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {OUT} ({len(lines)} lines, 256 glyphs incl. {len(PSEUDOGRAPHICS)} "
          f"pseudographics) from {path}")


if __name__ == "__main__":
    main()
