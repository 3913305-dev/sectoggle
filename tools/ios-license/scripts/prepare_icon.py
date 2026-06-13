#!/usr/bin/env python3
"""Generate all App Icon sizes for home screen + asset catalog."""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSET_DIR = ROOT / "SijiLicenseTool/Assets.xcassets/AppIcon.appiconset"
ICON_DIR = ROOT / "SijiLicenseTool/Icons"
RGB = (33, 101, 192)


def _chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def write_png(path: Path, width: int, height: int, rgb: tuple[int, int, int] = RGB) -> None:
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
    sizes = [
        (120, ASSET_DIR / "AppIcon-60@2x.png", ICON_DIR / "AppIcon60x60@2x.png"),
        (180, ASSET_DIR / "AppIcon-60@3x.png", ICON_DIR / "AppIcon60x60@3x.png"),
        (1024, ASSET_DIR / "AppIcon-1024.png", ICON_DIR / "AppIcon-1024.png"),
    ]
    for px, asset_path, bundle_path in sizes:
        write_png(asset_path, px, px)
        write_png(bundle_path, px, px)
        print(f"OK: {asset_path.name} ({px}px)")


if __name__ == "__main__":
    main()
