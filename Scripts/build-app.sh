#!/bin/bash
# Builds Inkstone.app — the menu-bar wrapper — around the SwiftPM executable.
#
# SwiftPM emits a bare Mach-O binary, but a menu-bar app needs a real bundle:
# LSUIElement to stay out of the Dock, a bundle identifier so notification and
# TCC permissions stick to it across rebuilds, and an icon slot. Assembling the
# bundle here keeps the whole project buildable with plain `swift build` and no
# Xcode project to drift out of sync.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
DIST="$ROOT/dist"
APP="$DIST/Inkstone.app"
VERSION="$(grep -m1 'let version = ' "$ROOT/Sources/inkstone/main.swift" | sed 's/.*"\(.*\)".*/\1/')"

echo "Building Inkstone $VERSION ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product InkstoneMenuBar
swift build -c "$CONFIGURATION" --product inkstone

BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/InkstoneMenuBar" "$APP/Contents/MacOS/Inkstone"
# The CLI ships inside the bundle so the launch agents can point at a single
# installed location, and so `install.sh` has something to symlink.
#
# It goes in Resources, not MacOS: the Mac's filesystem is case-insensitive by
# default, so `MacOS/inkstone` and `MacOS/Inkstone` are the same file and the
# CLI would silently clobber the app binary.
cp "$BIN/inkstone" "$APP/Contents/Resources/inkstone"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Inkstone</string>
    <key>CFBundleDisplayName</key>       <string>Inkstone</string>
    <key>CFBundleIdentifier</key>        <string>com.inkstone.menubar</string>
    <key>CFBundleExecutable</key>        <string>Inkstone</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- Menu-bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>Inkstone</string>
</dict>
</plist>
PLIST

# Ad-hoc signing is enough for a locally built tool and is required on Apple
# silicon for the binary to run at all.
codesign --force --deep --sign - "$APP" 2>/dev/null \
    || echo "warning: ad-hoc signing failed; the app may refuse to launch"

# Prove the bundle is intact rather than trusting that cp did what we meant.
"$APP/Contents/Resources/inkstone" version > /dev/null
test -x "$APP/Contents/MacOS/Inkstone"

echo "Built $APP"
