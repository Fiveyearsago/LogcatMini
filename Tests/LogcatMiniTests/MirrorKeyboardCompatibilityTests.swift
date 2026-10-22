import XCTest
@testable import LogcatMini

final class MirrorKeyboardCompatibilityTests: XCTestCase {
    private let original = "com.baidu.input_oppo/.ImeService"
    private let gboard = "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME"

    func testRestoresOriginalInputMethodAndDoesNotOverrideManualSelection() async throws {
        let fixture = try Fixture(ime: original)
        let lease = try MirrorKeyboardCompatibility(path: fixture.adb.path, serial: "oneplus", notice: { _ in })
        try await fixture.wait(for: gboard)
        lease.stopAndWait()
        XCTAssertEqual(try fixture.current(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))

        let next = try MirrorKeyboardCompatibility(path: fixture.adb.path, serial: "oneplus", notice: { _ in })
        try await fixture.wait(for: gboard)
        try fixture.select("user.chosen/.IME")
        next.stopAndWait()
        XCTAssertEqual(try fixture.current(), "user.chosen/.IME")
    }

    func testOtherIMEsAndMissingGboardAreNotChanged() async throws {
        for ime in [gboard, original] {
            let fixture = try Fixture(ime: ime)
            if ime == original { try Data().write(to: fixture.root.appendingPathComponent("missing")) }
            let lease = try MirrorKeyboardCompatibility(path: fixture.adb.path, serial: "pixel", notice: { _ in })
            try await Task.sleep(nanoseconds: 250_000_000)
            lease.stopAndWait()
            XCTAssertEqual(try fixture.current(), ime)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
        }
    }

    func testConcurrentSessionCannotOwnOrRestoreAnotherSessionsIME() async throws {
        let fixture = try Fixture(ime: original)
        let first = try MirrorKeyboardCompatibility(path: fixture.adb.path, serial: "oneplus", notice: { _ in })
        defer { first.stopAndWait() }
        try await fixture.wait(for: gboard)
        let second = try MirrorKeyboardCompatibility(path: fixture.adb.path, serial: "oneplus", notice: { _ in })
        try await Task.sleep(nanoseconds: 250_000_000)
        second.stopAndWait()
        XCTAssertEqual(try fixture.current(), gboard)
        first.stopAndWait()
        XCTAssertEqual(try fixture.current(), original)
    }

    func testPhoneSideTimeoutRestoresWithoutHostCleanupAndRecoversJournal() async throws {
        let fixture = try Fixture(ime: original)
        let process = Process(), input = Pipe()
        let exited = expectation(description: "Phone lease exits after heartbeat timeout")
        process.terminationHandler = { _ in exited.fulfill() }
        process.executableURL = fixture.adb
        let script = "'" + MirrorKeyboardCompatibility.script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        process.arguments = ["-s", "oneplus", "shell", "-T", "sh", "-c", script]
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        try input.fileHandleForWriting.write(contentsOf: Data("keep\n".utf8))
        try await fixture.wait(for: gboard)
        // Keep stdin open but stop heartbeats, simulating a frozen or lost Mac.
        try await fixture.wait(for: original, attempts: 150)
        await fulfillment(of: [exited], timeout: 3)
        guard !process.isRunning else { XCTFail("Phone lease did not exit"); return }
        XCTAssertEqual(process.terminationStatus, 0)

        try fixture.select(gboard)
        try original.write(to: fixture.journal, atomically: true, encoding: .utf8)
        let recovered = try MirrorKeyboardCompatibility(path: fixture.adb.path, serial: "oneplus", notice: { _ in })
        try await Task.sleep(nanoseconds: 250_000_000)
        recovered.stopAndWait()
        XCTAssertEqual(try fixture.current(), original)
    }

    private final class Fixture {
        let root: URL
        var adb: URL { root.appendingPathComponent("adb") }
        var journal: URL { root.appendingPathComponent("logcat-mini-keyboard-0.previous") }
        init(ime: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("keyboard-lease-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try select(ime)
            let helper = root.appendingPathComponent("commands.py")
            try #"""
            #!/usr/bin/env python3
            import os, sys, pathlib, shlex, fcntl
            root = pathlib.Path(sys.argv[0]).parent
            cmd, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
            state = root/'ime.txt'
            if cmd == 'adb':
                script = shlex.split(args[-1])[0].replace('/data/local/tmp', str(root))
                os.environ['PATH'] = str(root)+':'+os.environ['PATH']
                os.execv('/bin/bash', ['bash', '-c', script])
            elif cmd == 'am': print('0')
            elif cmd == 'settings': print(state.read_text())
            elif cmd == 'ime':
                if args[0] == 'list':
                    if not (root/'missing').exists(): print('com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME')
                elif args[0] == 'set':
                    (root/'next').write_text(args[-1]); (root/'next').replace(state)
            elif cmd == 'flock':
                try: fcntl.flock(int(args[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: sys.exit(1)
            """#.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            for name in ["adb", "am", "settings", "ime", "flock"] {
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: helper)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func select(_ ime: String) throws { try ime.write(to: root.appendingPathComponent("ime.txt"), atomically: true, encoding: .utf8) }
        func current() throws -> String { try String(contentsOf: root.appendingPathComponent("ime.txt")).trimmingCharacters(in: .whitespacesAndNewlines) }
        func wait(for expected: String, attempts: Int = 60) async throws {
            for _ in 0..<attempts {
                if try current() == expected { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTFail("Expected \(expected), got \(try current())")
        }
    }
}
