#!/bin/zsh
# Build SimView.app: Objective-C core (private simulator APIs) + SwiftUI app.
set -euo pipefail
cd "$(dirname "$0")"
OUT=build/SimView.app
rm -rf build/obj "$OUT"
mkdir -p build/obj "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
for f in dtuhid.m core/*.m; do
  clang -fobjc-arc -O2 -I. -Icore -c "$f" -o "build/obj/$(basename "${f%.m}").o"
done
rm -rf build/strings && mkdir -p build/strings  # strings used in app/*.swift, for the String Catalog
swiftc -O -swift-version 5 -parse-as-library \
  -import-objc-header core/Bridge.h -Xcc -I. -Xcc -Icore \
  -emit-localized-strings -emit-localized-strings-path build/strings \
  app/*.swift build/obj/*.o \
  -framework Cocoa -framework QuartzCore -framework IOSurface -framework QuickLookThumbnailing -lsqlite3 \
  -o "$OUT/Contents/MacOS/SimView"
cp app/Info.plist "$OUT/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then  # release builds: VERSION=1.2.3 ./build.sh
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$OUT/Contents/Info.plist"
fi
cp app/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
# Localisation: add the strings used in app/*.swift to the String Catalog (like Xcode does), then compile
# it into en.lproj / fr.lproj. xcstringstool comes with Xcode; without it the app is English only.
if xcrun --find xcstringstool >/dev/null 2>&1; then
  xcrun xcstringstool sync app/Localizable.xcstrings --stringsdata build/strings/*.stringsdata
  xcrun xcstringstool compile app/Localizable.xcstrings --output-directory "$OUT/Contents/Resources"
  app/check-strings.py
else
  echo "warning: xcstringstool not found (install Xcode): SimView is built without its translations" >&2
fi

# simview-mcp: MCP server (stdio) for AI agents, sharing the HID and simulator core. Also shipped inside the app
# (Contents/Helpers), so an installed SimView.app carries its MCP server along.
swiftc -O -swift-version 5 -parse-as-library \
  -import-objc-header core/Bridge.h -Xcc -I. -Xcc -Icore \
  mcp/main.swift build/obj/dtuhid.o build/obj/SVSimulators.o \
  -framework Foundation -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lsqlite3 \
  -o build/simview-mcp
mkdir -p "$OUT/Contents/Helpers"
cp build/simview-mcp "$OUT/Contents/Helpers/simview-mcp"
codesign -s - --force "$OUT/Contents/Helpers/simview-mcp" >/dev/null
codesign -s - --force "$OUT" >/dev/null
echo "built $OUT"
echo "built build/simview-mcp"
