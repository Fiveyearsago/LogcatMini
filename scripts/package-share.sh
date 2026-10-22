#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Build the normal app shell, then replace its executable with both Mac architectures.
bash scripts/build-app.sh
swift build -c release --arch arm64 --arch x86_64 --scratch-path .build/distribution
PRODUCTS=$(swift build -c release --arch arm64 --arch x86_64 --scratch-path .build/distribution --show-bin-path)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' 'dist/Logcat Mini.app/Contents/Info.plist')
PACKAGE_NAME="LogcatMini-${VERSION}-macOS-Universal"
STAGE_PARENT=$(mktemp -d "$PROJECT_DIR/dist/share-stage.XXXXXX")
trap 'rm -rf "$STAGE_PARENT"' EXIT
STAGE="$STAGE_PARENT/$PACKAGE_NAME"
APP="$STAGE/Logcat Mini.app"
mkdir -p "$STAGE"
ditto 'dist/Logcat Mini.app' "$APP"
cp "$PRODUCTS/LogcatMini" "$APP/Contents/MacOS/LogcatMini"
rm -rf "$APP/Contents/Resources/LogcatMini_LogcatMini.bundle"
ditto "$PRODUCTS/LogcatMini_LogcatMini.bundle" "$APP/Contents/Resources/LogcatMini_LogcatMini.bundle"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
BINARY_ARCHITECTURES=$(lipo -archs "$APP/Contents/MacOS/LogcatMini")
for REQUIRED_ARCH in arm64 x86_64; do
    if [[ " $BINARY_ARCHITECTURES " != *" $REQUIRED_ARCH "* ]]; then
        printf 'Missing required architecture: %s\n' "$REQUIRED_ARCH" >&2
        exit 1
    fi
done
cp README.md "$STAGE/README.md"
cp LICENSE THIRD_PARTY_NOTICES.md "$STAGE/"
ZIP_PATH="$PROJECT_DIR/dist/$PACKAGE_NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP_PATH"
(cd "$PROJECT_DIR/dist" && shasum -a 256 "$PACKAGE_NAME.zip") > "$ZIP_PATH.sha256"
printf 'Share package: %s\n' "$ZIP_PATH"
