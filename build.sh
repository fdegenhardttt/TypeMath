#!/bin/zsh
# Builds TypeMath.app and installs it to ~/Applications.
# The bundle is assembled and signed in a temp folder, because iCloud-synced folders
# (like the Desktop) add file attributes that codesign rejects.
set -e
cd "$(dirname "$0")"

STAGE=$(mktemp -d)
APP="$STAGE/TypeMath.app"
INSTALL="$HOME/Applications/TypeMath.app"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 Sources/*.swift -o "$APP/Contents/MacOS/TypeMath"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TypeMath</string>
    <key>CFBundleIdentifier</key><string>local.typemath</string>
    <key>CFBundleExecutable</key><string>TypeMath</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Sign with an Apple Development certificate if there is one, so the Accessibility
# permission survives rebuilds; otherwise fall back to ad-hoc signing.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$INSTALL"
ditto "$APP" "$INSTALL"
rm -rf "$STAGE"
echo "Installed $INSTALL"
