#!/bin/bash
# Build the SwiftUI front end (app/) into build/Portamento.app, icon included.
# Needs: Xcode CLT with the macOS 26+ SDK (Swift 6.2+). No Xcode required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Portamento.app"
ICONSET="$ROOT/build/AppIcon.iconset"

swift build -c release --package-path "$ROOT/app"
BIN="$(swift build -c release --package-path "$ROOT/app" --show-bin-path)/Portamento"

rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Portamento"
# porta rides along, so the app works without a checkout; with the build scripts,
# patches and test sources for `porta setup --build` (the test programs themselves
# come with the runtimes)
BUNDLED="$APP/Contents/Resources/porta"
mkdir -p "$BUNDLED/tests"
cp "$ROOT/porta" "$ROOT/LICENSE" "$BUNDLED/"
cp -R "$ROOT/scripts" "$ROOT/patches" "$BUNDLED/"
cp "$ROOT/tests/"*.c "$ROOT/tests/"*.h "$ROOT/tests/build.sh" "$BUNDLED/tests/"
swift "$ROOT/app/icon/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Portamento</string>
    <key>CFBundleIdentifier</key><string>local.portamento</string>
    <key>CFBundleName</key><string>Portamento</string>
    <key>CFBundleDisplayName</key><string>Portamento</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Windows installer</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key><array><string>exe</string><string>msi</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "$APP"
