#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
# Gradle 8.13+ is required by AGP 8.13.2. Supply GRADLE_BIN if it is not on PATH.
GRADLE_CMD="${GRADLE_BIN:-gradle}"
"$GRADLE_CMD" -p "$PROJECT_DIR/android-helper/device-info" --console plain assembleDebug
cp "$PROJECT_DIR/android-helper/device-info/build/outputs/apk/debug/LogcatMiniDeviceInfo-debug.apk" \
    "$PROJECT_DIR/Sources/LogcatMini/Resources/DeviceInfo.apk"
printf 'Built device info helper: %s\n' "$PROJECT_DIR/Sources/LogcatMini/Resources/DeviceInfo.apk"
