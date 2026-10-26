#!/usr/bin/env python3
"""Build a signed, non-debuggable, offline APK for the automation acceptance flow."""
from pathlib import Path
import os
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
sdk = Path(os.environ.get("ANDROID_SDK_ROOT", str(Path.home() / "Library/Android/sdk")))
java = Path(subprocess.check_output(["/usr/libexec/java_home", "-v", "17"], text=True).strip())
build_tools = sdk / "build-tools/35.0.0"
android = sdk / "platforms/android-35/android.jar"
source = root / "android-helper/automation-fixture"
build = root / ".build/automation-fixture"
output = root / "dist/automation-fixture"
for directory in [build, build / "generated", build / "classes", build / "dex", output]:
    directory.mkdir(parents=True, exist_ok=True)

def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=root, check=True)

run(build_tools / "aapt2", "compile", "--dir", source / "res", "-o", build / "res.zip")
run(build_tools / "aapt2", "link", "-o", build / "unsigned.apk", "--manifest",
    source / "AndroidManifest.xml", "-I", android, "--java", build / "generated", build / "res.zip")
run(java / "bin/javac", "-source", "8", "-target", "8", "-Xlint:-options",
    "-classpath", android, "-d", build / "classes", source / "MainActivity.java",
    *sorted((build / "generated").rglob("*.java")))
run(build_tools / "d8", "--min-api", "26", "--lib", android, "--output", build / "dex",
    *sorted((build / "classes").rglob("*.class")))
with zipfile.ZipFile(build / "unsigned.apk", "a") as archive:
    archive.write(build / "dex/classes.dex", "classes.dex")
key = build / "fixture-only.jks"
if not key.exists():
    run(java / "bin/keytool", "-genkeypair", "-keystore", key, "-storepass", "fixture-only",
        "-keypass", "fixture-only", "-alias", "fixture", "-keyalg", "RSA", "-keysize", "2048",
        "-validity", "3650", "-dname", "CN=Logcat Mini Offline Test Fixture")
run(build_tools / "zipalign", "-f", "4", build / "unsigned.apk", build / "aligned.apk")
apk = output / "LogcatMini-AutomationFixture-release.apk"
run(build_tools / "apksigner", "sign", "--ks", key, "--ks-pass", "pass:fixture-only",
    "--out", apk, build / "aligned.apk")
run(build_tools / "apksigner", "verify", apk)
print(apk)
