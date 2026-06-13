#!/bin/bash
# 巨魔/TrollStore 友好打包：仅 ad-hoc 签名 + 手动 Payload 打 IPA
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SCHEME="SijiLicenseTool"
PROJECT="SijiLicenseTool.xcodeproj"
BUILD_DIR="$ROOT/build/troll"
APP="$BUILD_DIR/Build/Products/Release-iphoneos/$SCHEME.app"
PAYLOAD="$BUILD_DIR/Payload"
IPA_OUT="$ROOT/SEC授权工具_troll.ipa"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

python3 "$ROOT/scripts/prepare_icon.py"

echo "==> Build Release for device (ad-hoc)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM="" \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  build 2>&1 | tee "$BUILD_DIR/xcodebuild.log"

if [ ! -d "$APP" ]; then
  echo "未找到 $APP"
  echo "=== xcodebuild log (tail) ==="
  tail -80 "$BUILD_DIR/xcodebuild.log" || true
  exit 1
fi

ICON_DIR="$ROOT/SijiLicenseTool/Icons"
if [ -d "$ICON_DIR" ]; then
  echo "==> 写入桌面图标到 App 包"
  cp "$ICON_DIR/AppIcon60x60@2x.png" "$APP/" 2>/dev/null || true
  cp "$ICON_DIR/AppIcon60x60@3x.png" "$APP/" 2>/dev/null || true
  cp "$ICON_DIR/AppIcon-1024.png" "$APP/" 2>/dev/null || true
fi

if command -v ldid >/dev/null 2>&1; then
  echo "==> ldid 伪签名（可选，部分巨魔环境更稳）"
  ldid -S "$APP/$SCHEME"
fi

rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"
cp -R "$APP" "$PAYLOAD/"

rm -f "$IPA_OUT"
(cd "$BUILD_DIR" && zip -qr "$IPA_OUT" Payload)

echo ""
echo "OK: $IPA_OUT"
echo "传到 iPhone 后用 TrollStore 安装。"
