import XCTest
import LogcatCore
@testable import LogcatMini

final class IOSLogCaptureTests: XCTestCase {
    func testInboxIsolatesGenerationsAndDoesNotAttachSimulatorDiagnosticsToPreviousLog() {
        let inbox = LogInbox(), old = UUID(), current = UUID()
        inbox.reset(old)
        inbox.receive(["Nov  3 12:34:56 Runner[12] <Notice>: first", "  continuation", "[disconnected:abc]", "discard"], session: old, format: .iosDevice)
        XCTAssertEqual(inbox.drain().0.map(\.message), ["first", "  continuation"])
        inbox.reset(current)
        inbox.receive(["Nov  3 12:34:57 Runner[12] <Error>: late"], session: old, format: .iosDevice)
        let json = #"{"timestamp":"2026-11-03 12:34:58.000+0800","processID":12,"eventMessage":"new","messageType":"Info"}"#
        inbox.receive([json, "stream diagnostic", "{broken json"], session: current, format: .iosSimulator)
        XCTAssertEqual(inbox.drain().0.map(\.message), ["new"])
    }
    @MainActor func testProcessSwitchPreservesSeparateBuffersAndFilters() {
        let suite = "IOSLogCaptureTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ios = IOSLogViewModel(defaults: defaults)
        ios.logs.activateDevice("simulator:test")
        ios.selectProcess("Runner")
        ios.logs.ingest([LogEntry(id: 1, date: "", time: "", pid: "1", tid: "1", level: .error, tag: "Runner", message: "alpha", raw: "alpha")])
        ios.logs.minimum = .error
        ios.selectProcess("Other")
        XCTAssertEqual(ios.logs.totalCount, 0); XCTAssertEqual(ios.logs.minimum, .verbose)
        ios.selectProcess("Runner")
        XCTAssertEqual(ios.logs.visible.map(\.message), ["alpha"]); XCTAssertEqual(ios.logs.minimum, .error)
        ios.clear(); XCTAssertEqual(ios.logs.totalCount, 0)
        ios.shutdown()
    }
    @MainActor func testOptInLiveSimulatorCapture() async throws {
        guard let udid = ProcessInfo.processInfo.environment["LOGCAT_MINI_IOS_SIMULATOR_QA"] else {
            throw XCTSkip("Set LOGCAT_MINI_IOS_SIMULATOR_QA to a booted iOS simulator UDID for live capture QA")
        }
        let suite = "IOSLiveCapture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let ios = IOSLogViewModel(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { ios.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("probe.m"), binary = directory.appendingPathComponent("LogcatMiniIOSProbe")
        try """
        #import <Foundation/Foundation.h>
        #import <os/log.h>
        #import <syslog.h>
        int main(void) {
            @autoreleasepool {
                os_log_t log = os_log_create("com.logcatmini.qa", "capture");
                os_log_error(log, "LOGCAT_MINI_IOS_QA %{public}s", "中文 {\\\"ok\\\":true}");
                NSLog(@"LOGCAT_MINI_IOS_NSLOG_QA");
                // Flutter 3.47.9 SyslogOutputWriter uses this native transport for print/debugPrint.
                syslog(LOG_ALERT, "%s", "flutter: LOGCAT_MINI_FLUTTER_SYSLOG_QA");
            }
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let sdk = try await ADB.run(path: "/usr/bin/xcrun", arguments: ["--sdk", "iphonesimulator", "--show-sdk-path"])
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        _ = try await ADB.run(path: "/usr/bin/xcrun", arguments: ["clang", "-target", arch + "-apple-ios17.0-simulator", "-isysroot", sdk, source.path, "-framework", "Foundation", "-o", binary.path], timeout: 30)
        await ios.refreshDevices()
        XCTAssertTrue(ios.devices.contains { $0.udid == udid })
        await ios.selectDevice("simulator:" + udid)
        XCTAssertFalse(ios.processes.isEmpty)
        ios.selectProcess("LogcatMiniIOSProbe"); ios.begin(); ios.start()
        XCTAssertTrue(ios.logs.running)
        // Allow the stream to attach before emitting. The test never launches or changes a user app.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        for _ in 0..<3 {
            _ = try await ADB.run(path: "/usr/bin/xcrun", arguments: ["simctl", "spawn", udid, binary.path])
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        for _ in 0..<20 {
            if ios.logs.visible.contains(where: { $0.message.contains("LOGCAT_MINI_IOS_QA") }) { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        ios.stop()
        let logs = ios.logs.visible
        XCTAssertTrue(logs.contains { $0.message.contains("LOGCAT_MINI_IOS_QA") && $0.level == .error && $0.message.contains("中文") }, "\(ios.logs.errorMessage ?? "")\n\(logs.map(\.fullText).joined(separator: "\n"))")
        XCTAssertTrue(logs.contains { $0.message.contains("LOGCAT_MINI_IOS_NSLOG_QA") })
        XCTAssertTrue(logs.contains { $0.message.contains("flutter: LOGCAT_MINI_FLUTTER_SYSLOG_QA") })
        XCTAssertTrue(logs.allSatisfy { $0.tag.hasPrefix("LogcatMiniIOSProbe") })
        XCTAssertFalse(ios.logs.running)
        ios.logs.tag = "capture"; ios.logs.minimum = .error
        XCTAssertTrue(ios.logs.visible.allSatisfy { $0.level == .error })
    }
}
