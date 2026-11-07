#!/usr/bin/env python3
"""Generate the VDP init script ROM for the Mojo V3 -> PICO9918 test.

Outputs (written next to the RTL):
  rtl/init_rom.hex   12-bit words, one per line, for $readmemh
  rtl/layout.vh      VRAM addresses shared with the Verilog

ROM word = {op[3:0], arg[7:0]}:
  0 END     stop, hand over to the RTL test and frame loop
  1 WCTRL   write arg to the control port (MODE=1)
  2 WDATA   write arg to the data port (MODE=0)
  3 CNTHI   fill count[15:8] = arg
  4 CNTLO   fill count[7:0]  = arg
  5 FILL    write arg to the data port `count` times
  6 RSTAT   read the status register (resets the address/register latch)

The font comes from the PICO9918 firmware (src/res/font.png): 8x8 cells,
16 per row, ASCII 0x20-0x5F, 5x5 glyphs in the top-left of each cell.
"""
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, "..", "rtl")

OP_END, OP_WCTRL, OP_WDATA, OP_CNTHI, OP_CNTLO, OP_FILL, OP_RSTAT = range(7)

# --- VRAM layout (Graphics I) ------------------------------------------------
PATTERN = 0x0000   # R4 = 0x00
NAME = 0x1800      # R2 = 0x06
SAT = 0x1B00       # R5 = 0x36
COLOR = 0x2000     # R3 = 0x80
TEST = 0x3000      # readback test area (256 bytes, not displayed)
SPRPAT = 0x3800    # R6 = 0x07

BAR_PAT = 0x80     # patterns 0x80-0xFF are solid blocks; one colour per group of 8

R1_OFF = 0x82      # 16K, display blank, no IRQ, 16x16 sprites
R1_ON = 0xE2       # 16K, display on, IRQ on, 16x16 sprites

REGS = [0x00, R1_OFF, NAME // 0x400, COLOR // 0x40, PATTERN // 0x800,
        SAT // 0x80, SPRPAT // 0x800, 0xF4]   # R7: white text / dark blue backdrop

# --- Screen text: (row, col, text); fields the RTL fills in are marked ----------
TEXT = [
    (1, 3, "MOJO V3 -> PICO9918 TEST"),
    (4, 2, "FRAME     $????"),        # RTL writes 4 hex digits at col 13
    (5, 2, "STATUS    $??"),          # col 13
    (6, 2, "READBACK  ???? $??"),     # col 12: PASS/FAIL + error count
    (7, 2, "RESYNCS   $??"),          # col 13: watchdog re-inits
    (8, 2, "INT PIN   $??  POLLED $??"),  # cols 13, 25: frames per source
    (21, 2, "SPRITE + BARS = WRITES OK"),
]
FRAME_COL, STAT_COL, TEST_COL, RSYNC_COL, IPIN_COL, POLL_COL = 13, 13, 12, 13, 13, 25
BAR_ROWS = (10, 11, 12, 13)


def name_addr(row, col):
    return NAME + row * 32 + col


def load_font(path):
    im = Image.open(path).convert("L")
    px = im.load()
    font = {}
    for ch in range(0x20, 0x60):
        idx = ch - 0x20
        cx, cy = (idx % 16) * 8, (idx // 16) * 8
        rows = []
        for y in range(8):
            bits = 0
            for x in range(8):
                if px[cx + x, cy + y]:
                    bits |= 0x80 >> x
            rows.append(bits)
        # 5x5 glyph at the top-left: move it down a row and right a column
        rows = [0] + [r >> 1 for r in rows[:7]]
        font[ch] = rows
    return font


def main():
    rom = []

    def w(op, arg=0):
        assert 0 <= arg <= 0xFF
        rom.append((op << 8) | arg)

    def set_write_addr(addr):
        w(OP_WCTRL, addr & 0xFF)
        w(OP_WCTRL, 0x40 | (addr >> 8))

    def fill(addr, value, count):
        set_write_addr(addr)
        w(OP_CNTHI, count >> 8)
        w(OP_CNTLO, count & 0xFF)
        w(OP_FILL, value)

    def data(addr, values):
        set_write_addr(addr)
        for v in values:
            w(OP_WDATA, v)

    w(OP_RSTAT)                           # clear any half-written address latch
    for r, v in enumerate(REGS):
        w(OP_WCTRL, v)
        w(OP_WCTRL, 0x80 | r)

    fill(0x0000, 0x00, 0x4000)            # clear all 16K

    font = load_font(os.path.join(HERE, "font.png"))
    data(PATTERN + 0x20 * 8, [b for ch in range(0x20, 0x60) for b in font[ch]])
    fill(PATTERN + BAR_PAT * 8, 0xFF, 128 * 8)

    # Colour table: one entry per 8 patterns
    colors = [0x00] * 32
    for e in range(0x04, 0x0C):
        colors[e] = 0xF0                  # text: white on transparent
    colors[0x06] = colors[0x07] = 0xB0    # digits and :;<=>? in light yellow
    for i in range(16):
        colors[0x10 + i] = ((i + 1) & 0x0F) << 4   # bars: colours 1..15
    data(COLOR, colors)

    for row, col, text in TEXT:
        data(name_addr(row, col), [ord(c) for c in text])
    for row in BAR_ROWS:                  # 15 bars, 2 columns each, centred
        data(name_addr(row, 1), [BAR_PAT + 8 * (i // 2) for i in range(30)])

    # Sprite 0: 16x16 filled circle (four 8x8 quadrants: TL, BL, TR, BR)
    grid = [[(x - 7.5) ** 2 + (y - 7.5) ** 2 <= 7.6 ** 2 for x in range(16)] for y in range(16)]

    def quad(x0, y0):
        return [sum(0x80 >> x for x in range(8) if grid[y0 + y][x0 + x]) for y in range(8)]

    data(SPRPAT, quad(0, 0) + quad(0, 8) + quad(8, 0) + quad(8, 8))
    data(SAT, [96, 120, 0, 0x0F, 0xD0])   # sprite 0, then end-of-list marker

    w(OP_WCTRL, R1_ON)                    # display + frame interrupt on
    w(OP_WCTRL, 0x81)
    w(OP_END)

    depth = 1 << (len(rom) - 1).bit_length()
    if depth > 2048:
        sys.exit(f"ROM too big: {len(rom)} words")
    with open(os.path.join(RTL, "init_rom.hex"), "w") as f:
        for word in rom + [OP_END << 8] * (depth - len(rom)):
            f.write(f"{word:03x}\n")

    with open(os.path.join(RTL, "layout.vh"), "w") as f:
        f.write("// Generated by tools/gen_init_rom.py - do not edit\n")
        f.write(f"localparam ROM_DEPTH   = {depth};\n")
        f.write(f"localparam ROM_AW      = {max(1, (depth - 1).bit_length())};\n")
        f.write(f"localparam [13:0] VRAM_SAT    = 14'h{SAT:04x};\n")
        f.write(f"localparam [13:0] VRAM_TEST   = 14'h{TEST:04x};\n")
        f.write(f"localparam [13:0] VRAM_NAME   = 14'h{NAME:04x};\n")
        f.write(f"localparam [13:0] ADDR_FRAME  = 14'h{name_addr(4, FRAME_COL):04x};\n")
        f.write(f"localparam [13:0] ADDR_STATUS = 14'h{name_addr(5, STAT_COL):04x};\n")
        f.write(f"localparam [13:0] ADDR_TEST   = 14'h{name_addr(6, TEST_COL):04x};\n")
        f.write(f"localparam [13:0] ADDR_RESYNC = 14'h{name_addr(7, RSYNC_COL):04x};\n")
        f.write(f"localparam [13:0] ADDR_IPIN   = 14'h{name_addr(8, IPIN_COL):04x};\n")
        f.write(f"localparam [13:0] ADDR_POLL   = 14'h{name_addr(8, POLL_COL):04x};\n")

    print(f"{len(rom)} ROM words (depth {depth})")


if __name__ == "__main__":
    main()
