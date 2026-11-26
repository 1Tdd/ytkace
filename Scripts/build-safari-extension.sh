#!/usr/bin/env bash
set -euo pipefail

# Builds the Open in YTKACE Safari extension.
# usage: build-safari-extension.sh out_dir [iphoneos|iphonesimulator]
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: build-safari-extension.sh out_dir [iphoneos|iphonesimulator]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/SafariExtension"
SDK="${2:-iphoneos}"
mkdir -p "$1"
OUT="$(cd "$1" && pwd)/OpenInYTKACE.appex"

case "$SDK" in
  iphoneos) TARGET="arm64-apple-ios15.0"; PLATFORM="iPhoneOS" ;;
  iphonesimulator) TARGET="arm64-apple-ios15.0-simulator"; PLATFORM="iPhoneSimulator" ;;
  *) echo "unknown sdk $SDK" >&2; exit 2 ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$SRC/Resources/." "$OUT/"
cp "$SRC/Info.plist" "$OUT/Info.plist"
python3 - "$OUT/Info.plist" "$PLATFORM" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
info["CFBundleSupportedPlatforms"] = [sys.argv[2]]
with open(sys.argv[1], "wb") as handle:
    plistlib.dump(info, handle)
PY

# Xcode's clang on macOS; otherwise the Theos toolchain and SDK (Linux CI).
if command -v xcrun >/dev/null 2>&1; then
  CLANG=(xcrun -sdk "$SDK" clang)
  SYSROOT="$(xcrun -sdk "$SDK" --show-sdk-path)"
else
  THEOS_DIR="${THEOS:-$ROOT/.theos}"
  CLANG=("$THEOS_DIR/toolchain/linux/iphone/bin/clang")
  SYSROOT="$(find "$THEOS_DIR/sdks" -maxdepth 1 -type d -name "$PLATFORM*.sdk" -print | sort -V | tail -n 1)"
  test -x "${CLANG[0]}"
  test -n "$SYSROOT"
fi

"${CLANG[@]}" -target "$TARGET" -isysroot "$SYSROOT" \
  -fobjc-arc -fapplication-extension -Os \
  -e _NSExtensionMain -framework Foundation \
  -o "$OUT/OpenInYTKACE" "$SRC/SafariWebExtensionHandler.m"

echo "$OUT"
