"""OSD pseudographics charset — the single source of truth shared by the font
ROM generator (scripts/font_generator.py) and the host encoder (modbus_client).

The OSD font ROM is indexed by the raw byte the host sends. Codes 0x00..0xFF
carry the Latin-1 glyphs; box-drawing / block "pseudographics" have no Latin-1
codepoint, so they live in the otherwise-unused C1 control range 0x80..0x9F.
This table maps each pseudographic's Unicode character to the byte that selects
its glyph. The web palette offers these characters; modbus_client encodes them
to the byte below; font_generator paints the matching glyph at that byte.

No imports here on purpose — font_generator runs under the system Python, which
has no pyserial, so it must not pull in modbus_client.
"""

# (Unicode char, ROM byte). Bytes are contiguous 0x80..0x9F (32 entries).
PSEUDOGRAPHICS = [
    ("─", 0x80),  # ─ light horizontal
    ("│", 0x81),  # │ light vertical
    ("┌", 0x82),  # ┌ light down+right
    ("┐", 0x83),  # ┐ light down+left
    ("└", 0x84),  # └ light up+right
    ("┘", 0x85),  # ┘ light up+left
    ("├", 0x86),  # ├ light vertical+right
    ("┤", 0x87),  # ┤ light vertical+left
    ("┬", 0x88),  # ┬ light down+horizontal
    ("┴", 0x89),  # ┴ light up+horizontal
    ("┼", 0x8A),  # ┼ light cross
    ("═", 0x8B),  # ═ double horizontal
    ("║", 0x8C),  # ║ double vertical
    ("╔", 0x8D),  # ╔ double down+right
    ("╗", 0x8E),  # ╗ double down+left
    ("╚", 0x8F),  # ╚ double up+right
    ("╝", 0x90),  # ╝ double up+left
    ("╠", 0x91),  # ╠ double vertical+right
    ("╣", 0x92),  # ╣ double vertical+left
    ("╦", 0x93),  # ╦ double down+horizontal
    ("╩", 0x94),  # ╩ double up+horizontal
    ("╬", 0x95),  # ╬ double cross
    ("█", 0x96),  # █ full block
    ("▀", 0x97),  # ▀ upper half block
    ("▄", 0x98),  # ▄ lower half block
    ("▌", 0x99),  # ▌ left half block
    ("▐", 0x9A),  # ▐ right half block
    ("░", 0x9B),  # ░ light shade
    ("▒", 0x9C),  # ▒ medium shade
    ("▓", 0x9D),  # ▓ dark shade
    ("■", 0x9E),  # ■ black square
    ("·", 0x9F),  # · middle dot
]

PSEUDO_BY_CHAR = {ch: b for ch, b in PSEUDOGRAPHICS}
PSEUDO_CHARS = [ch for ch, _ in PSEUDOGRAPHICS]


def osd_byte(ch):
    """Map one character to its OSD ROM byte: a pseudographic's C1 code if it is
    one, else its Latin-1 code, else '?' (0x3F) for anything beyond 0xFF."""
    code = PSEUDO_BY_CHAR.get(ch)
    if code is not None:
        return code
    o = ord(ch)
    return o if o <= 0xFF else 0x3F
