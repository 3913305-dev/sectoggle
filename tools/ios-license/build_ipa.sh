#!/bin/bash
# 在 Mac 上打包 IPA，供 TrollStore（巨魔）安装。
# 用法: ./build_ipa.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SCHEME="SijiLicenseTool"
PROJECT="SijiLicenseTool.xcodeproj"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
IPA_OUT="$ROOT/SEC授权工具.ipa"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archive (Release, generic iOS device)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  archive

cat > "$BUILD_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>development</string>
	<key>compileBitcode</key>
	<false/>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>-</string>
	<key>provisioningProfiles</key>
	<dict/>
</dict>
</plist>
PLIST

echo "==> Export IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO

IPA=$(find "$EXPORT_DIR" -name "*.ipa" | head -1)
cp "$IPA" "$IPA_OUT"

echo ""
echo "OK: $IPA_OUT"
echo "将 IPA 传到 iPhone，用 TrollStore 打开安装即可（无需 App Store）。"
echo "若 export 失败，可在 Xcode 中 Product -> Archive 后手动导出 Development IPA。"
