#!/usr/bin/env python3
"""Generate AppIcon-1024.png for Xcode / CI builds."""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "SijiLicenseTool/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"


def _chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def write_png(path: Path, width: int, height: int, rgb: tuple[int, int, int] = (33, 101, 192)) -> None:
    row = b"\x00" + bytes(rgb) * width
    raw = row * height
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    payload = b"\x89PNG\r\n\x1a\n"
    payload += _chunk(b"IHDR", ihdr)
    payload += _chunk(b"IDAT", zlib.compress(raw, 9))
    payload += _chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def main() -> None:
    write_png(ICON, 1024, 1024)
    print(f"OK: {ICON}")


if __name__ == "__main__":
    main()
