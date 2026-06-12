#!/usr/bin/env python3
"""从 Icons/AppIcon-1024.png 生成 @2x/@3x 桌面图标。"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent / "SecLicenseApp" / "Icons"
SRC = ROOT / "AppIcon-1024.png"

if not SRC.exists():
    raise SystemExit(f"缺少源图: {SRC}")

img = Image.open(SRC)
img.resize((120, 120), Image.Resampling.LANCZOS).save(ROOT / "AppIcon60x60@2x.png")
img.resize((180, 180), Image.Resampling.LANCZOS).save(ROOT / "AppIcon60x60@3x.png")
print("已生成 AppIcon60x60@2x.png / @3x.png")
