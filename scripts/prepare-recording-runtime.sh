#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/recording-runtime"
DEST="$PROJECT_DIR/Sources/LogcatMini/Resources/Recording"
mkdir -p "$BUILD_DIR" "$DEST"
for architecture in aarch64 x86_64; do
    archive="scrcpy-macos-$architecture-v5.0.1.tar.gz"
    curl -fL --retry 2 "https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/$archive" -o "$BUILD_DIR/$archive"
    if [ "$architecture" = aarch64 ]; then
        expected=33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b
    else
        expected=31a5467a9e907f162b093267cbbab1276b15c6e709c2ea8159566a8d165beb50
    fi
    actual=$(shasum -a 256 "$BUILD_DIR/$archive" | cut -d ' ' -f 1)
    [ "$actual" = "$expected" ] || { echo "Checksum mismatch: $archive" >&2; exit 1; }
    tar -xzf "$BUILD_DIR/$archive" -C "$BUILD_DIR"
done
lipo -create "$BUILD_DIR/scrcpy-macos-aarch64-v5.0.1/scrcpy" "$BUILD_DIR/scrcpy-macos-x86_64-v5.0.1/scrcpy" -o "$DEST/scrcpy"
cmp "$BUILD_DIR/scrcpy-macos-aarch64-v5.0.1/scrcpy-server" "$BUILD_DIR/scrcpy-macos-x86_64-v5.0.1/scrcpy-server"
cp "$BUILD_DIR/scrcpy-macos-aarch64-v5.0.1/scrcpy-server" "$DEST/scrcpy-server"
cp "$BUILD_DIR/scrcpy-macos-aarch64-v5.0.1/LICENSE" "$DEST/LICENSE-scrcpy.txt"
codesign --force --sign - "$DEST/scrcpy"
RUNTIME_ARCHITECTURES=$(lipo -archs "$DEST/scrcpy")
for REQUIRED_ARCH in arm64 x86_64; do
    [[ " $RUNTIME_ARCHITECTURES " == *" $REQUIRED_ARCH "* ]] || { echo "Missing architecture: $REQUIRED_ARCH" >&2; exit 1; }
done
