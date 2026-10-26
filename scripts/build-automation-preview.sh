#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
bash scripts/build-app.sh
PREVIEW="$PROJECT_DIR/dist/Logcat Mini Automation Preview.app"
ditto "$PROJECT_DIR/dist/Logcat Mini.app" "$PREVIEW"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.songran.LogcatMini.AutomationPreview" "$PREVIEW/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Logcat Mini Automation Preview" "$PREVIEW/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Logcat Mini Automation Preview" "$PREVIEW/Contents/Info.plist"
codesign --force --deep --sign - "$PREVIEW"
printf 'Preview (separate preferences, not installed): %s\n' "$PREVIEW"
