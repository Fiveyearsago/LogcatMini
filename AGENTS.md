# Logcat Mini

This is the standalone Git root for Logcat Mini. Run development, tests and builds here.

- macOS: SwiftUI + AppKit in `Sources/LogcatMini`, shared parsing logic in `Sources/LogcatCore`, tests in `Tests`.
- Prepare runtime: `bash scripts/prepare-recording-runtime.sh`.
- Test: `swift test`. Build: `bash scripts/build-app.sh`.
- Only use `--install` when the user requests replacing the local app; preserve needed live logs before a restart.
- Only package with `bash scripts/package-share.sh` when packaging is requested.
- Windows: follow `windows/README.md`; Mac checks do not count as Windows device acceptance.
- Preserve platform scope. Do not edit Windows behavior for a Mac-only request.
- Do not commit real logs, credentials, private keys, personal preferences, device identifiers or files in `.build/` and `dist/`.
- Do not add internal endpoints or default business keys. Use synthetic examples and explicit user configuration.
