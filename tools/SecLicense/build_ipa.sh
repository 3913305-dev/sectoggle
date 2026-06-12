#!/usr/bin/env bash
# 在 Mac 上打包 SecLicense.ipa（TrollStore 侧载）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT/SecLicenseApp"
BUILD="$ROOT/build"
PAYLOAD="$BUILD/Payload/SecLicense.app"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

rm -rf "$BUILD"
mkdir -p "$PAYLOAD"

clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=13.0 \
  -fobjc-arc -Wno-deprecated-declarations \
  -framework UIKit -framework Foundation -framework Security \
  -o "$PAYLOAD/SecLicense" \
  "$APP_DIR/main.m" \
  "$APP_DIR/AppDelegate.m" \
  "$APP_DIR/IssueViewController.m" \
  "$APP_DIR/ViewController.m" \
  "$APP_DIR/SecDeviceID.m" \
  "$APP_DIR/SecLicenseCore.m"

cp "$APP_DIR/Info.plist" "$PAYLOAD/Info.plist"

cd "$BUILD"
zip -qr SecLicense.ipa Payload
echo "Built: $BUILD/SecLicense.ipa"
file "$PAYLOAD/SecLicense"
