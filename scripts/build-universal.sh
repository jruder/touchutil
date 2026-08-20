#!/bin/bash
#
# Build a universal (arm64 + x86_64) release binary that runs on both
# Apple Silicon and Intel Macs.
#
# Uses swiftc + lipo so it works with only the Xcode Command Line Tools
# (full Xcode is NOT required).
#
set -euo pipefail

cd "$(dirname "$0")/.."

SRC=(
    Sources/touchutil/main.swift
    Sources/touchutil/TestWindow.swift
    Sources/touchutil/MultiTouch.swift
    Sources/touchutil/TouchHealth.swift
    Sources/touchutil/MacOSHealthAdapters.swift
    Sources/touchutil/PrecisionTouch.swift
    Sources/touchutil/MacOSPrecisionLoupe.swift
)
OUT_DIR="build"
DEPLOY="11.0"
mkdir -p "$OUT_DIR"

echo "Compiling arm64 slice..."
swiftc -O -target "arm64-apple-macosx${DEPLOY}"  "${SRC[@]}" -o "$OUT_DIR/touchutil-arm64"

echo "Compiling x86_64 slice..."
swiftc -O -target "x86_64-apple-macosx${DEPLOY}" "${SRC[@]}" -o "$OUT_DIR/touchutil-x86_64"

echo "Creating universal binary with lipo..."
lipo -create -output "$OUT_DIR/touchutil" \
    "$OUT_DIR/touchutil-arm64" "$OUT_DIR/touchutil-x86_64"

rm -f "$OUT_DIR/touchutil-arm64" "$OUT_DIR/touchutil-x86_64"

# Code-sign with a stable, unique identifier. Release builds fall back to
# ad-hoc signing; local developers can set CODESIGN_IDENTITY to a certificate
# hash so rebuilt binaries retain the same TCC designated requirement.
BUNDLE_ID="${BUNDLE_ID:-com.eriproject.touchutil}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
echo "Code-signing (identity=$CODESIGN_IDENTITY, identifier=$BUNDLE_ID)..."
codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$OUT_DIR/touchutil"

# Assemble a background .app bundle. Bundling gives macOS a stable, registered
# identity (the bundle id) so privacy permissions can be revoked with tccutil
# and are attributed cleanly when launched by launchd.
APP="$OUT_DIR/touchutil.app"
echo "Assembling app bundle ($APP)..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT_DIR/touchutil" "$APP/Contents/MacOS/touchutil"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>touchutil</string>
    <key>CFBundleExecutable</key>
    <string>touchutil</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.5.0</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
echo "Code-signing app bundle (identity=$CODESIGN_IDENTITY, identifier=$BUNDLE_ID)..."
codesign --force --deep --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"

echo
echo "Built:"
echo "  CLI binary:  $OUT_DIR/touchutil"
echo "  App bundle:  $APP"
file "$OUT_DIR/touchutil"
echo
echo "Install with: ./scripts/install.sh"
