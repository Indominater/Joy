#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/Joy.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
PRODUCTS="$ROOT/.build/release"
MODULE_CACHE="$ROOT/.build/module-cache"

cd "$ROOT"
SWIFTC="$(xcrun --find swiftc)"
SDKROOT="${JOY_SDKROOT:-$(xcrun --show-sdk-path)}"
# This machine currently has a newer default SDK than its command-line Swift
# compiler. Prefer the compatible installed SDK when available.
if [[ -z "${JOY_SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
ARCH="$(uname -m)"

mkdir -p "$PRODUCTS" "$MODULE_CACHE"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" "$SWIFTC" \
    -O -sdk "$SDKROOT" -target "$ARCH-apple-macosx13.0" -parse-as-library \
    "$ROOT"/Sources/Joy/*.swift -o "$PRODUCTS/Joy"

rm -rf "$APP" "$ROOT/build/Joy Extension"
rm -f "$PRODUCTS/JoyBridge"
mkdir -p "$MACOS" "$RESOURCES"
cp "$PRODUCTS/Joy" "$MACOS/Joy"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/Joy.icns" "$RESOURCES/Joy.icns"
cp "$ROOT/Resources/132970571_p0.png" "$RESOURCES/132970571_p0.png"

chmod +x "$MACOS/Joy"
codesign --force --deep --sign - "$APP"

echo "Built $APP"
