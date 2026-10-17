#!/usr/bin/env python3
"""Render the HAPanel app icons (green square + white pulse line) as PNGs, stdlib only.

Usage: python3 tools/make_icons.py panel/
"""
import math
import struct
import sys
import zlib

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
BG = (22, 163, 74)        # accent green
FG = (255, 255, 255)
# Pulse line on a 24x24 grid: M3 12 h4 l3-8 4 16 3-8 h4
PTS = [(3, 12), (7, 12), (10, 4), (14, 20), (17, 12), (21, 12)]


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def render(size):
    # Content sits in the central 56% so it survives Android's maskable-icon crop
    scale, off = size * 0.56 / 24, size * 0.22
    pts = [(off + x * scale, off + y * scale) for x, y in PTS]
    half_w = 2.2 * scale / 2
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            d = min(seg_dist(x + .5, y + .5, *pts[i], *pts[i + 1]) for i in range(len(pts) - 1))
            a = max(0.0, min(1.0, half_w - d + .5))       # 1px anti-aliased edge, round caps/joins
            row += bytes(round(BG[c] + (FG[c] - BG[c]) * a) for c in range(3)) + b"\xff"
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", raw) + chunk(b"IEND", b""))


for name, size in (("icon-192.png", 192), ("icon-512.png", 512), ("apple-touch-icon.png", 180)):
    with open(f"{OUT}/{name}", "wb") as f:
        f.write(render(size))
    print(name, size)
