# Third-party notices

The root MIT license applies to original Logcat Mini code, not to third-party components.

## macOS recording and mirroring

The source repository does not distribute third-party recording executables. `scripts/prepare-recording-runtime.sh` downloads official scrcpy 5.0.1 archives, verifies their SHA-256 digests and prepares a local Universal executable plus the matching Android server.

- scrcpy: Apache-2.0, Genymobile and contributors.
- SDL: zlib license.
- FFmpeg and libusb dependencies in the official static runtime: LGPL-2.1-or-later, subject to their upstream terms.

See [the runtime notice](Sources/LogcatMini/Resources/Recording/NOTICE.txt) and the adjacent license texts for source and build-recipe references. Anyone distributing a compiled bundle must comply with each bundled component's license, including applicable source / relinking requirements; the project MIT license does not replace those obligations. The runtime remains a separate executable and can be replaced with a compatible version.

## Windows

Avalonia, .NET, SkiaSharp, HarfBuzzSharp, MicroCom, Tmds.DBus and related dependencies retain their original licenses. License copies and component attribution are in [windows/licenses](windows/licenses). Windows recording components are fetched separately by `scripts/prepare-windows-recording.py`.

## Android metadata helper

`android-helper/` is original project code under the root MIT license. Its bundled JAR can be rebuilt using `scripts/build-android-helper.sh`. ADB and Android SDK tools are not redistributed by this repository.
