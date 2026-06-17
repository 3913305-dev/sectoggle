#!/bin/bash
# Build without Theos (Xcode command line tools only).
set -euo pipefail

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
OUT="TPlayerFakeVIP.dylib"
SRC="TPlayerFakeVIP.m"

if [[ ! -f "$SRC" ]]; then
  echo "Run logos.pl first or use Tweak.x with Theos."
  echo "  perl /path/to/logos.pl Tweak.x > TPlayerFakeVIP.m"
  exit 1
fi

"$CC" -dynamiclib \
  -isysroot "$SDK" \
  -arch arm64 \
  -miphoneos-version-min=14.0 \
  -fobjc-arc \
  -install_name "@rpath/$OUT" \
  -framework Foundation \
  -framework UIKit \
  -o "$OUT" \
  "$SRC"

echo "Built $OUT"
echo "Inject with TrollFools into tplayer.app"
