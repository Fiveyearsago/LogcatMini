# Public source validation

Validated on 2026-10-22 for the initial public source snapshot based on Mac 0.16.4.

- Swift tests: 190 total, zero failures, five opt-in tests skipped.
- Windows core checks: 61 passed on the development Mac; this is not Windows UI or device acceptance.
- Fresh download and SHA-256 verification of both official scrcpy 5.0.1 Mac archives succeeded. The prepared runtime contains arm64 and x86_64.
- Native Mac release build and local ad-hoc signature verification passed.
- Public source uses synthetic log fixtures and user-configured decryption endpoints / RSA keys. No business endpoint, default business key, personal device identifier or private repository history is included.
- Third-party executables, build output, local QA evidence and user preferences are excluded from Git. Original third-party license files are preserved.

This snapshot does not include a notarized release, an Intel Mac hardware acceptance result, or a Windows desktop hardware acceptance result.

## Mac 0.17.2 source update — 2026-10-26

- Added mirror wake, phone clipboard synchronization, device information and local GAID cache, native cat interactions, and fixed build timestamps in About.
- Public source tests: 205 total, zero failures, seven opt-in device tests skipped. The synthetic log-tag fixture was also checked separately after replacing its example name.
- Native Release build and strict ad-hoc signature verification passed. Both official scrcpy archives were downloaded and checksum-verified again.
- Kept user-configured decryption endpoints and keys, synthetic fixtures, and the existing public Git history. Internal service defaults, private history and raw device/business acceptance records were not imported.
- No connected device acceptance was run for this public export. Windows source and behavior are unchanged. Build output, local signing keys, logs, screenshots and preferences remain excluded.
