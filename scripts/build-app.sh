#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release
APP_DIR="$PROJECT_DIR/dist/Logcat Mini.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/LogcatMini "$APP_DIR/Contents/MacOS/LogcatMini"
ditto .build/release/LogcatMini_LogcatMini.bundle "$APP_DIR/Contents/Resources/LogcatMini_LogcatMini.bundle"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.songran.LogcatMini</string>
<key>CFBundleName</key><string>Logcat Mini</string>
<key>CFBundleDisplayName</key><string>Logcat Mini</string>
<key>CFBundleExecutable</key><string>LogcatMini</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.17.2</string>
<key>CFBundleVersion</key><string>33</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
<!-- The request replay tool explicitly supports user-entered HTTP as well as HTTPS endpoints.
     HTTPS certificate validation remains the URLSession system default. -->
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Logcat Mini · Personal build</string>
</dict></plist>
PLIST
# Persist the version's creation time in the app, so launching or copying it
# never changes the date shown in About. Share packages inherit this metadata.
RELEASE_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
/usr/libexec/PlistBuddy -c "Add :LogcatMiniReleaseDate string $RELEASE_DATE" "$APP_DIR/Contents/Info.plist"
if [ ! -f "$PROJECT_DIR/dist/AppIcon.icns" ]; then
    swift scripts/make-icon.swift "$PROJECT_DIR/dist/AppIcon.iconset"
    iconutil -c icns "$PROJECT_DIR/dist/AppIcon.iconset" -o "$PROJECT_DIR/dist/AppIcon.icns"
fi
cp "$PROJECT_DIR/dist/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
if [ "${1:-}" = "--install" ]; then
    INSTALL_DIR="$HOME/Applications/Logcat Mini.app"
    mkdir -p "$HOME/Applications"
    ditto "$APP_DIR" "$INSTALL_DIR"
    printf 'Installed: %s\n' "$INSTALL_DIR"
fi
