#!/usr/bin/env python3
"""Write a small waveform ICO next to this script. Stdlib only."""
from __future__ import annotations

import struct
import zlib
from pathlib import Path


def png(size: int) -> bytes:
    # Dark circle, white vertical bars — the idle pill glyph.
    rows = []
    cx = cy = (size - 1) / 2
    r = size * 0.46
    for y in range(size):
        row = bytearray()
        row.append(0)  # filter none
        for x in range(size):
            dx, dy = x - cx, y - cy
            inside = dx * dx + dy * dy <= r * r
            a = 255 if inside else 0
            # waveform bars
            bars = 5
            white = 0
            if inside:
                nx = (x - size * 0.22) / (size * 0.56)
                if 0 <= nx <= 1:
                    i = int(nx * bars)
                    frac = (nx * bars) - i
                    if frac < 0.55:
                        heights = [0.35, 0.7, 1.0, 0.55, 0.4]
                        h = heights[min(i, bars - 1)]
                        if abs(y - cy) / r <= h * 0.7:
                            white = 1
            if white:
                row += bytes([255, 255, 255, a])
            else:
                row += bytes([18, 18, 18, a])
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def ico(images: list[bytes]) -> bytes:
    # ICO with PNG payloads (Vista+).
    count = len(images)
    header = struct.pack("<HHH", 0, 1, count)
    offset = 6 + 16 * count
    entries = b""
    payloads = b""
    for data in images:
        # Read PNG size from IHDR
        w, h = struct.unpack(">II", data[16:24])
        w = w if w < 256 else 0
        h = h if h < 256 else 0
        entries += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(data), offset)
        payloads += data
        offset += len(data)
    return header + entries + payloads


def main() -> None:
    out = Path(__file__).with_name("quill.ico")
    out.write_bytes(ico([png(16), png(32), png(64)]))
    print(f"wrote {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
