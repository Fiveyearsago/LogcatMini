import XCTest
@testable import LogcatMini
@testable import LogcatCore

final class AutomationIntegrationTests: XCTestCase {
    /// Deliberately opt-in: ordinary swift test never installs an APK or operates a device.
    @MainActor func testExplicitDeviceReleaseFixtureEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let serial = env["LOGCATMINI_AUTOMATION_DEVICE"], !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let rootPath = env["LOGCATMINI_AUTOMATION_ROOT"] else {
            throw XCTSkip("Set an explicit device serial and workspace root to run the device acceptance test")
        }
        let root = URL(fileURLWithPath: rootPath)
        let support = root.appendingPathComponent("dist/automation-acceptance/library")
        let defaults = UserDefaults(suiteName: "LogcatMini.AutomationIntegrationTests")!
        defer { defaults.removePersistentDomain(forName: "LogcatMini.AutomationIntegrationTests") }
        let model = AutomationModel(defaults: defaults, support: support); model.loadFixtureSuite()
        let tools = AutomationTools.discover()
        let apkURL = root.appendingPathComponent("dist/automation-fixture/LogcatMini-AutomationFixture-release.apk")
        let apk = try await APKInspector.inspect(apkURL, aapt2: tools.aapt2)
        XCTAssertFalse(apk.debuggable)
        guard apk.packageName == "com.songran.logcatmini.automationfixture" else { XCTFail("Unexpected APK"); return }
        let runs = root.appendingPathComponent("dist/automation-acceptance/runs")
        let request = AutomationRequest(apkURL: apkURL, apk: apk, suite: try XCTUnwrap(model.suite), tools: tools,
            serial: serial, deviceName: "Explicit test device", environment: "独立离线演示", name: "Release 完整链路验证", outputRoot: runs)
        let value = try await AutomationRunner().run(request) { update in
            for test in update.cases where test.status == .passed {
                XCTAssertFalse(test.steps.contains { $0.status == .pending || $0.status == .running }, "A case cannot pass while cleanup is incomplete")
            }
            print("AUTOMATION \(update.phase) passed=\(update.count(.passed)) failed=\(update.count(.failed))")
        }
        print("AUTOMATION_REPORT \(runs.appendingPathComponent(value.id).appendingPathComponent("report.md").path)")
        XCTAssertEqual(value.count(.passed), 3, value.reason + "\n" + value.cases.map { $0.reason }.joined(separator: "\n"))
        XCTAssertEqual(value.count(.failed), 1)
        XCTAssertTrue(value.isComplete)
        let directory = runs.appendingPathComponent(value.id)
        let failed = try XCTUnwrap(value.cases.last?.steps.first)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(AutomationReport.artifactExists(try XCTUnwrap(failed.screenshot), in: directory))
        let exported = root.appendingPathComponent("dist/automation-acceptance/exports/" + value.id)
        try AutomationStorage.export(value, from: directory, to: exported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("report.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("input/app.apk").path))
        XCTAssertEqual(try AutomationStorage.load(directory).cases.map(\.status), [.passed, .passed, .passed, .failed])
    }
    @MainActor func testExplicitDeviceStopAndFreshRerun() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let serial = env["LOGCATMINI_AUTOMATION_DEVICE"], !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let path = env["LOGCATMINI_AUTOMATION_ROOT"] else { throw XCTSkip("Explicit device opt-in required") }
        let root = URL(fileURLWithPath: path), tools = AutomationTools.discover()
        let apkURL = root.appendingPathComponent("dist/automation-fixture/LogcatMini-AutomationFixture-release.apk")
        let apk = try await APKInspector.inspect(apkURL, aapt2: tools.aapt2)
        guard apk.packageName == "com.songran.logcatmini.automationfixture" else { XCTFail("Unexpected APK"); return }
        let suite = TestSuite(packageName: apk.packageName, cases: [
            AutomationCase(id: "WAIT", steps: [
                TestStep(id: "wait", action: .waitVisible, target: TestTarget(id: apk.packageName + ":id/never"), timeoutMs: 60000),
                TestStep(id: "foreground", action: .assertForeground)
            ]), AutomationCase(id: "NEXT")
        ])
        let runs = root.appendingPathComponent("dist/automation-acceptance/runs")
        var request = AutomationRequest(apkURL: apkURL, apk: apk, suite: suite, tools: tools, serial: serial,
            deviceName: "Explicit test device", environment: "独立离线演示", name: "停止测试验证", outputRoot: runs)
        let cancellation = AutomationCancellation()
        let cancelled = try await AutomationRunner(cancellation: cancellation).run(request) { value in
            if value.cases.first?.steps.first?.status == .running { cancellation.cancel() }
        }
        XCTAssertEqual(cancelled.cases.map(\.status), [.cancelled, .notRun])
        XCTAssertFalse(cancelled.isComplete)
        XCTAssertNotNil(cancelled.endedAt)
        XCTAssertEqual(try AutomationStorage.load(runs.appendingPathComponent(cancelled.id)).cases.map(\.status), [.cancelled, .notRun])
        request.suite = TestSuite(packageName: apk.packageName)
        request.name = "停止后的独立复测"; request.parentRunID = cancelled.id
        let fresh = try await AutomationRunner().run(request) { _ in }
        XCTAssertEqual(fresh.count(.passed), 1, fresh.reason)
        XCTAssertEqual(fresh.parentRunID, cancelled.id)
        XCTAssertNotEqual(fresh.id, cancelled.id)
        print("CANCEL_REPORT \(runs.appendingPathComponent(cancelled.id).path)")
        print("RERUN_REPORT \(runs.appendingPathComponent(fresh.id).path)")
    }
}
