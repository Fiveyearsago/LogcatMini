#!/usr/bin/env python3
"""Fetch the pinned official scrcpy Windows runtime; never copies local ADB or settings."""
from pathlib import Path
import hashlib
import shutil
import sys
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = "5.0.1"
SHA256 = "b12a2c4ee8be317422451fc7dcf8ee20a71b5ea7ef9ad73ddd825a25316227a5"
URL = f"https://github.com/Genymobile/scrcpy/releases/download/v{VERSION}/scrcpy-win64-v{VERSION}.zip"
DEST = ROOT / "windows/LogcatMini.Desktop/Recording"
FILES = {"scrcpy.exe", "scrcpy-server", "avutil-61.dll", "avcodec-63.dll", "avformat-63.dll", "swresample-7.dll", "libusb-1.0.dll", "SDL3.dll", "LICENSE.txt"}

with tempfile.TemporaryDirectory(prefix="LogcatMini-recorder-") as work:
    archive = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(work) / "scrcpy.zip"
    if len(sys.argv) == 1:
        urllib.request.urlretrieve(URL, archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit("scrcpy SHA-256 mismatch; runtime was not replaced")
    stage = Path(work) / "Recording"
    stage.mkdir()
    with zipfile.ZipFile(archive) as package:
        for name in sorted(FILES):
            (stage / name).write_bytes(package.read(f"scrcpy-win64-v{VERSION}/{name}"))
    (stage / "SOURCE.txt").write_text(f"Official scrcpy v{VERSION} Windows x64 runtime\n{URL}\nSHA-256 {SHA256}\nADB is excluded; Logcat Mini sets ADB to the user's selected executable.\n", encoding="utf-8")
    # Release FFmpeg/SDL/libusb are dynamically linked; include licenses and source/build references.
    for source in (ROOT / "windows/licenses/recording").glob("*"):
        shutil.copy2(source, stage / source.name)
    DEST.mkdir(parents=True, exist_ok=True)
    for source in stage.iterdir():
        shutil.copy2(source, DEST / source.name)
print(DEST)
