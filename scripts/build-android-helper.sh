#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK_DIR="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
JAVA_DIR="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
ANDROID_JAR="$SDK_DIR/platforms/android-35/android.jar"
D8="$SDK_DIR/build-tools/35.0.0/d8"
BUILD_DIR="$PROJECT_DIR/.build/android-helper"
mkdir -p "$BUILD_DIR/classes" "$BUILD_DIR/dex" "$PROJECT_DIR/Sources/LogcatMini/Resources"
"$JAVA_DIR/bin/javac" -source 8 -target 8 -Xlint:-options -classpath "$ANDROID_JAR" -d "$BUILD_DIR/classes" "$PROJECT_DIR/android-helper/src/com/songran/logcatmini/AppMetadata.java"
"$D8" --min-api 26 --lib "$ANDROID_JAR" --output "$BUILD_DIR/dex" "$BUILD_DIR/classes/com/songran/logcatmini/AppMetadata.class"
"$JAVA_DIR/bin/jar" cf "$PROJECT_DIR/Sources/LogcatMini/Resources/AppMetadata.jar" -C "$BUILD_DIR/dex" classes.dex
printf 'Built metadata helper: %s\n' "$PROJECT_DIR/Sources/LogcatMini/Resources/AppMetadata.jar"
