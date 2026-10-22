import XCTest
import CoreVideo
import LogcatCore
@testable import LogcatMini

final class DeviceMirrorTests: XCTestCase {
    func testVersionFiveSessionHeadersAndBoundedMediaPackets() throws {
        // scrcpy 5 uses bit 63 for session packets, bit 62 for config, bit 61 for keyframe.
        var header = Data([0x80, 0, 0, 0]); header.mirrorAppend(UInt32(576)); header.mirrorAppend(UInt32(1280))
        XCTAssertEqual(try MirrorProtocol.packetHeader(header), .session(width: 576, height: 1280))
        header = Data(); header.mirrorAppend(UInt64(0x4000_0000_0000_0000)); header.mirrorAppend(UInt32(42))
        XCTAssertEqual(try MirrorProtocol.packetHeader(header), .media(size: 42, configuration: true, presentationTime: 0))
        header = Data(); header.mirrorAppend(UInt64(0x2000_0000_0000_007b)); header.mirrorAppend(UInt32(1024))
        XCTAssertEqual(try MirrorProtocol.packetHeader(header), .media(size: 1024, configuration: false, presentationTime: 123))
        for size: UInt32 in [0, .max] {
            header = Data(repeating: 0, count: 8); header.mirrorAppend(size)
            XCTAssertThrowsError(try MirrorProtocol.packetHeader(header))
        }
        XCTAssertThrowsError(try MirrorProtocol.packetHeader(Data([0])))
        header = Data([0x80, 0, 0, 0]); header.mirrorAppend(UInt32(0)); header.mirrorAppend(UInt32(1280))
        XCTAssertThrowsError(try MirrorProtocol.packetHeader(header))
    }

    func testAspectFitCoordinatesRejectLetterboxingAndClampDrag() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600), portrait = CGSize(width: 600, height: 1200)
        XCTAssertEqual(MirrorProtocol.contentRect(in: bounds, video: portrait), CGRect(x: 50, y: 0, width: 300, height: 600))
        XCTAssertNil(MirrorProtocol.devicePoint(CGPoint(x: 20, y: 200), in: bounds, video: portrait))
        XCTAssertEqual(MirrorProtocol.devicePoint(CGPoint(x: 200, y: 300), in: bounds, video: portrait), CGPoint(x: 300, y: 600))
        XCTAssertEqual(MirrorProtocol.devicePoint(CGPoint(x: 450, y: -20), in: bounds, video: portrait, clamp: true), CGPoint(x: 599, y: 0))
        let landscape = CGSize(width: 1200, height: 600)
        XCTAssertNil(MirrorProtocol.devicePoint(CGPoint(x: 200, y: 100), in: bounds, video: landscape))
        XCTAssertEqual(MirrorProtocol.devicePoint(CGPoint(x: 200, y: 300), in: bounds, video: landscape), CGPoint(x: 600, y: 300))
    }

    func testTouchNavigationScrollAndUnicodeWireEncoding() throws {
        let touch = MirrorProtocol.touch(action: 0, point: CGPoint(x: 120, y: 300), size: CGSize(width: 600, height: 1280))
        XCTAssertEqual(touch.count, 32); XCTAssertEqual(touch.prefix(2), Data([2, 0]))
        XCTAssertEqual(touch.mirrorInteger(at: 2, bytes: 8), UInt64.max - 1)
        XCTAssertEqual(touch.mirrorInteger(at: 10, bytes: 4), 120)
        XCTAssertEqual(touch.mirrorInteger(at: 14, bytes: 4), 300)
        XCTAssertEqual(touch.mirrorInteger(at: 18, bytes: 2), 600)
        XCTAssertEqual(touch.mirrorInteger(at: 20, bytes: 2), 1280)
        XCTAssertEqual(touch.mirrorInteger(at: 22, bytes: 2), 65535)
        let key = MirrorProtocol.key(4)
        XCTAssertEqual(key.count, 28); XCTAssertEqual(key[1], 0); XCTAssertEqual(key[15], 1)
        XCTAssertEqual(key.mirrorInteger(at: 16, bytes: 4), 4)
        let scroll = MirrorProtocol.scroll(point: .zero, size: CGSize(width: 600, height: 1280), horizontal: -100, vertical: 100)
        XCTAssertEqual(scroll.count, 21)
        XCTAssertEqual(scroll.mirrorInteger(at: 13, bytes: 2), 0x8000)
        XCTAssertEqual(scroll.mirrorInteger(at: 15, bytes: 2), 0x7fff)
        let text = "中文 Test 👋"
        let paste = try XCTUnwrap(MirrorProtocol.text(text, paste: true))
        XCTAssertEqual(paste[0], 9); XCTAssertEqual(paste[9], 1)
        XCTAssertEqual(paste.mirrorInteger(at: 10, bytes: 4), UInt64(text.utf8.count))
        XCTAssertEqual(String(decoding: paste.dropFirst(14), as: UTF8.self), text)
        XCTAssertNil(MirrorProtocol.text(String(repeating: "中", count: 30_000), paste: true))
    }

    func testAnnexBMixedStartCodes() {
        XCTAssertEqual(MirrorProtocol.nalUnits(Data([0,0,0,1,0x67,4,5,0,0,1,0x68,6,0,0,0,1,0x65,7])),
                       [Data([0x67,4,5]), Data([0x68,6]), Data([0x65,7])])
        XCTAssertTrue(MirrorProtocol.nalUnits(Data([1,2,3])).isEmpty)
    }

    func testTemporaryKeyboardWireFormat() {
        let name = "Logcat Mini Keyboard test"
        let packet = MirrorProtocol.keyboardCreate(name: name)
        XCTAssertEqual(packet[0], 12)
        XCTAssertEqual(packet.mirrorInteger(at: 1, bytes: 2), 1)
        XCTAssertEqual(packet.mirrorInteger(at: 3, bytes: 4), 0)
        XCTAssertEqual(Int(packet[7]), name.utf8.count)
        XCTAssertEqual(String(decoding: packet[8..<(8 + name.utf8.count)], as: UTF8.self), name)
        let descriptorOffset = 10 + name.utf8.count
        XCTAssertEqual(packet.mirrorInteger(at: descriptorOffset - 2, bytes: 2), UInt64(packet.count - descriptorOffset))
        XCTAssertEqual(packet[descriptorOffset..<(descriptorOffset + 6)], Data([5, 1, 9, 6, 0xa1, 1]))
        XCTAssertEqual(packet.last, 0xc0)
        XCTAssertEqual(MirrorProtocol.keyboardDestroy, Data([14, 0, 1]))
        XCTAssertEqual(MirrorProtocol.openKeyboardSettings, Data([15]))
    }

    @MainActor func testKeyboardPreferencePersistsWithoutConnectingOrChangingLogCapture() {
        let suite = "MirrorKeyboardTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LogViewModel(defaults: defaults)
        model.running = true
        XCTAssertFalse(model.mirror.hideSoftKeyboard)
        model.mirror.hideSoftKeyboard = true
        model.closeMirror()
        XCTAssertTrue(model.running)
        XCTAssertEqual(model.mirror.state, .idle)
        XCTAssertTrue(DeviceMirrorController(defaults: defaults).hideSoftKeyboard)
        model.mirror.hideSoftKeyboard = false
        XCTAssertFalse(DeviceMirrorController(defaults: defaults).hideSoftKeyboard)
        model.shutdown()
    }

    @MainActor func testCloseMirrorDoesNotStopLogsAndTargetChangesClearState() {
        let suite = "MirrorTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LogViewModel(defaults: defaults); model.adbPath = nil
        model.running = true
        model.toggleMirror()
        XCTAssertTrue(model.mirrorShown)
        XCTAssertEqual(model.mirror.state, .failed("请先在设置中选择 ADB。"))
        model.selectedSerial = "other-device"
        XCTAssertEqual(model.mirror.videoSize, .zero)
        model.closeMirror()
        XCTAssertTrue(model.running); XCTAssertFalse(model.mirrorShown); XCTAssertEqual(model.mirror.state, .idle)
        model.shutdown()
    }

    @MainActor func testLateFramesCannotReappearAfterStopOrDeviceSwitch() async throws {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let frame = try XCTUnwrap(pixel), delivery = MirrorFrameDelivery(), first = UUID(), second = UUID()
        var delivered = 0
        delivery.activate(first) { _ in delivered += 1 }
        delivery.submit(frame, generation: first)
        delivery.activate(second) { _ in delivered += 1 }
        delivery.submit(frame, generation: first)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(delivered, 0); XCTAssertNil(delivery.latest)
        delivery.submit(frame, generation: second)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(delivered, 1)
        delivery.clear(); delivery.submit(frame, generation: second)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(delivered, 1); XCTAssertNil(delivery.latest)
    }

    @MainActor func testRealDeviceMirrorWhenRequested() async throws {
        guard let serial = ProcessInfo.processInfo.environment["LOGCAT_MINI_MIRROR_DEVICE"], let path = ADB.locate() else {
            throw XCTSkip("Set LOGCAT_MINI_MIRROR_DEVICE to explicitly enable physical-device mirroring QA")
        }
        let devices = AndroidDevice.parse(try await ADB.run(path: path, arguments: ["devices", "-l"]))
        let device = try XCTUnwrap(devices.first { $0.id == serial && $0.ready })
        let before = try await ADB.run(path: path, arguments: ["forward", "--list"])
        let suite = "RealMirrorTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mirror = DeviceMirrorController(defaults: defaults)
        defer { mirror.stop() }
        func keyboards() async throws -> Set<String> {
            let devices = try await ADB.run(path: path, arguments: ["-s", serial, "shell", "dumpsys", "input"])
            let active = devices.components(separatedBy: "Input Reader State")[0]
            return Set(active.split(separator: "\n").filter { $0.contains(": Logcat Mini Keyboard ") }.map(String.init))
        }
        func waitForKeyboards(_ count: Int) async throws -> Set<String> {
            var current: Set<String> = []
            for _ in 0..<30 {
                current = try await keyboards()
                if current.count == count { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return current
        }
        let keyboardsBefore = try await keyboards()
        let settingArguments = ["-s", serial, "shell", "settings", "get", "secure", "show_ime_with_hard_keyboard"]
        let settingBefore = try await ADB.run(path: path, arguments: settingArguments)
        let imeArguments = ["-s", serial, "shell", "settings", "get", "secure", "default_input_method"]
        let imeBefore = try await ADB.run(path: path, arguments: imeArguments)
        let gboard = "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME"
        let enabledIMEs = try await ADB.run(path: path, arguments: ["-s", serial, "shell", "ime", "list", "-s"])
        let needsCompatibility = imeBefore.hasPrefix("com.baidu.input_oppo/") && enabledIMEs.contains(gboard)
        func waitForIME(_ expected: String) async throws {
            var current = ""
            for _ in 0..<50 {
                current = try await ADB.run(path: path, arguments: imeArguments)
                if current.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines) { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTFail("Expected IME \(expected), got \(current)")
        }
        mirror.connect(path: path, device: device)
        for _ in 0..<150 {
            if mirror.isStreaming { break }
            if case .failed(let message) = mirror.state { XCTFail(message); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(mirror.isStreaming, "Expected a decoded real-device frame: \(mirror.state)")
        XCTAssertGreaterThan(mirror.videoSize.height, 0)
        XCTAssertNotNil(mirror.frames.latest)
        if ProcessInfo.processInfo.environment["LOGCAT_MINI_MIRROR_IDLE_QA"] == "1" {
            try await Task.sleep(nanoseconds: 35_000_000_000)
            XCTAssertTrue(mirror.isStreaming, "A static phone screen must not be mistaken for a disconnected device")
        }
        mirror.hideSoftKeyboard = true
        let withKeyboard = try await waitForKeyboards(keyboardsBefore.count + 1)
        XCTAssertEqual(withKeyboard.count, keyboardsBefore.count + 1)
        XCTAssertTrue(withKeyboard.isSuperset(of: keyboardsBefore))
        if needsCompatibility { try await waitForIME(gboard) }
        mirror.hideSoftKeyboard = false
        let afterDisable = try await waitForKeyboards(keyboardsBefore.count)
        XCTAssertEqual(afterDisable, keyboardsBefore)
        try await waitForIME(imeBefore)
        mirror.hideSoftKeyboard = true
        let beforeQuit = try await waitForKeyboards(keyboardsBefore.count + 1)
        XCTAssertEqual(beforeQuit.count, keyboardsBefore.count + 1)
        if needsCompatibility { try await waitForIME(gboard) }
        await mirror.finishBeforeQuit()
        let afterQuit = try await waitForKeyboards(keyboardsBefore.count)
        XCTAssertEqual(afterQuit, keyboardsBefore, "Disconnect must remove only this session's temporary keyboard")
        let settingAfter = try await ADB.run(path: path, arguments: settingArguments)
        XCTAssertEqual(settingBefore, settingAfter, "Mirroring must not change persistent phone keyboard settings")
        let imeAfter = try await ADB.run(path: path, arguments: imeArguments)
        XCTAssertEqual(imeBefore, imeAfter, "Disconnect must restore this session's temporary input method change")
        let after = try await ADB.run(path: path, arguments: ["forward", "--list"])
        XCTAssertEqual(before, after, "Only this session's forward should be removed")
        XCTAssertNil(mirror.frames.latest)
    }

    func testStopDuringPushDoesNotLaunchLateServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adb = root.appendingPathComponent("fake adb")
        try #"""
        #!/usr/bin/env python3
        import sys, pathlib, json, time
        root = pathlib.Path(__file__).parent
        args = sys.argv[1:]
        with (root/'calls.jsonl').open('a') as f: f.write(json.dumps(args)+'\n')
        if 'push' in args:
            (root/'push-started').touch()
            time.sleep(.3)
        """#.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let session = MirrorSession(path: adb.path, serial: "device-a", server: root.appendingPathComponent("server"))
        session.start()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("push-started").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        session.stop(); await session.waitUntilFinished()
        XCTAssertTrue(session.isFinished)
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"))
        XCTAssertTrue(calls.contains("push")); XCTAssertTrue(calls.contains("rm"))
        XCTAssertFalse(calls.contains("forward")); XCTAssertFalse(calls.contains("app_process"))
        XCTAssertFalse(calls.contains("kill-server"))
    }
}
