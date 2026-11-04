# iOS support validation · macOS 0.20.1 (37)

The Mac client supports iOS log sources alongside Android. Windows behavior is unchanged. Tests and examples committed to this repository are synthetic; local device identifiers, business logs, project configuration, screenshots and recordings are not included.

## Implementation

- Shared log table, filtering/history/favorites, details, find, copy, export, fullscreen and keyboard shortcuts. Request replay and s decryption require complete source data and keep the public build's explicitly configured endpoint/key behavior.
- Device and application discovery, per-device/per-app sessions, app metadata/favorites, screenshots, recording, media history and clipboard transfer.
- Flutter and Xcode project builds with bundle/platform validation, artifact snapshots, fixed install targets, cancellation and output export. Simulator Flutter builds use debug; physical devices use project signing settings.
- Device Hub discovery for Xcode 27, plus the older Simulator entry point. The isolated `IOSSimulatorBridge` dynamically loads Xcode interfaces; no private Xcode framework is linked into the main app.
- Embedded simulator touch, drag, scroll, keyboard input, Unicode/multiline paste, select-all, delete and return. Input is bound to the chosen simulator. Text transfer replaces that simulator's clipboard; focus loss and session termination release held input.
- Native-resolution lossless PNG replaces the previous 960-pixel JPEG stream. Rendering uses high-quality interpolation and the same aspect-fit geometry as touch mapping. Frame scheduling targets at most 12 fps; actual rate depends on scene complexity and host load. The stream reader scans new bytes only and terminates oversized frames at a 64 MB boundary.
- Universal distribution includes both arm64 and x86_64 slices for the app and simulator helper, with per-binary architecture checks and strict ad-hoc signature verification.

## Validation and reproduction

The development validation passed the complete Swift suite: 227 tests, 12 opt-in tests skipped, zero failures. The separately enabled simulator control suite passed all three tests. Build, install, native-frame dimensions and the installed Mac mirror were also checked. After synchronizing to the public source tree, its complete Swift suite passed 228 tests with 12 opt-in tests skipped and zero failures; the public tree has an additional configurable-endpoint test.

```sh
bash scripts/prepare-recording-runtime.sh
swift test
bash scripts/build-app.sh
bash scripts/package-share.sh
```

For explicit simulator validation, set `LOGCAT_MINI_IOS_SIMULATOR_QA` or `LOGCAT_MINI_IOS_CONTROL_QA` to a simulator you own and have booted. Set `LOGCAT_MINI_FLUTTER_QA` to a Flutter executable to enable the separate temporary-project build test. These opt-in tests install/remove their own isolated fixture app and exercise the selected simulator. Do not enable them against a simulator being used for unrelated interactive work.

The UIKit fixture verifies actual button counters, drag/scroll results, exact Unicode and multiline text, replacement, return/delete behavior, held-touch release and no input after stop. Native frame dimensions are compared with the simulator screenshot rather than a hard-coded device size. Tests wait for launch animation and editor focus before sending input.

USB iPhone/iPad workflows, older Xcode runtimes and Intel Mac execution still need hardware acceptance. Physical-device mirroring remains a periodic preview operated on the device. Simulator interaction currently targets Xcode 27's DTUHID interface and was exercised in portrait orientation; unsupported interfaces retain preview and an official simulator-window fallback. Debugger-only / Dart VM Service-only output and redacted or omitted payloads cannot be recovered from system logs.

Input and framebuffer protocol references are credited to [Meta idb](https://github.com/meta/idb); its MIT license is included in [docs/licenses/idb.txt](licenses/idb.txt) and in the app bundle.
