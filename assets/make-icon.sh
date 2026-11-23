#!/bin/zsh
# Rebuild the app icon from its SVG sources: app/AppIcon.icns and assets/icon-512.png (for the README).
# icon-small.svg is a simplified drawing for the 16 and 32 px slots, where icon.svg's detail turns to mush.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -O assets/render.swift -o "$TMP/render"
mkdir -p "$TMP/large" "$TMP/small" "$TMP/AppIcon.iconset"
"$TMP/render" assets/icon.svg "$TMP/large" 64 128 256 512 1024
"$TMP/render" assets/icon-small.svg "$TMP/small" 16 32
set_=$TMP/AppIcon.iconset
cp "$TMP/small/icon_16.png"   "$set_/icon_16x16.png"
cp "$TMP/small/icon_32.png"   "$set_/icon_16x16@2x.png"
cp "$TMP/small/icon_32.png"   "$set_/icon_32x32.png"
cp "$TMP/large/icon_64.png"   "$set_/icon_32x32@2x.png"
cp "$TMP/large/icon_128.png"  "$set_/icon_128x128.png"
cp "$TMP/large/icon_256.png"  "$set_/icon_128x128@2x.png"
cp "$TMP/large/icon_256.png"  "$set_/icon_256x256.png"
cp "$TMP/large/icon_512.png"  "$set_/icon_256x256@2x.png"
cp "$TMP/large/icon_512.png"  "$set_/icon_512x512.png"
cp "$TMP/large/icon_1024.png" "$set_/icon_512x512@2x.png"
iconutil -c icns "$set_" -o app/AppIcon.icns
cp "$TMP/large/icon_512.png" assets/icon-512.png
echo "wrote app/AppIcon.icns and assets/icon-512.png"
