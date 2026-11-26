import XCTest
import LogcatCore
@testable import LogcatMini

final class IOSIDFATests: XCTestCase {
    let phone = IOSDevice(udid: "fixture-phone", name: "Fixture", kind: .usb)
    let syntheticIDFA = "12345678-1234-4321-ABCD-123456789012"
    func result(_ status: String = "authorized", simulator: Bool = false) -> IOSIDFAResult {
        .init(schemaVersion: 1, requestID: "request", bundleID: "com.example.helper", idfa: status == "authorized" && !simulator ? syntheticIDFA : IOSIDFAResult.zero,
              authorization: status, isSimulator: simulator, generatedAt: Date().timeIntervalSince1970)
    }
    func testValidIdentifierAndZeroPermissionStates() throws {
        let sample = result()
        XCTAssertEqual(try IOSIDFAResult.decode(JSONEncoder().encode(sample), requestID: "request", bundleID: sample.bundleID, simulator: false, since: Date()).usableIDFA, syntheticIDFA)
        for state in ["denied", "restricted", "notDetermined", "unknown"] { XCTAssertNil(result(state).usableIDFA) }
        XCTAssertNil(result(simulator: true).usableIDFA)
        let zero = IOSIDFAResult(schemaVersion: 1, requestID: "r", bundleID: "b", idfa: IOSIDFAResult.zero, authorization: "authorized", isSimulator: false, generatedAt: 0)
        XCTAssertNil(zero.usableIDFA)
    }
    func testRejectsOldRequestsWrongAppPlatformMalformedAndInconsistentResult() throws {
        let sample = result()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        for (key, value): (String, Any) in [("requestID", "older"), ("bundleID", "com.other.app"), ("isSimulator", true), ("generatedAt", 0), ("generatedAt", Date().timeIntervalSince1970 + 3600), ("idfa", "device-udid"), ("authorization", "denied"), ("schemaVersion", 99)] {
            let old = object[key]; object[key] = value
            XCTAssertThrowsError(try IOSIDFAResult.decode(JSONSerialization.data(withJSONObject: object), requestID: "request", bundleID: sample.bundleID, simulator: false, since: Date()), key)
            object[key] = old
        }
        XCTAssertThrowsError(try IOSIDFAResult.decode(Data(repeating: 32, count: 16385), requestID: "request", bundleID: sample.bundleID, simulator: false, since: Date()))
    }
    func testTeamInputValidationAndSeparateSimulatorIdentity() throws {
        XCTAssertThrowsError(try IOSIDFAService.bundleID(team: "--anything", simulator: false))
        XCTAssertThrowsError(try IOSIDFAService.bundleID(team: "", simulator: false))
        XCTAssertEqual(try IOSIDFAService.bundleID(team: "ABCDEFGHIJ", simulator: false), "com.logcatmini.idfahelper.tabcdefghij")
        XCTAssertEqual(try IOSIDFAService.bundleID(team: "", simulator: true), "com.logcatmini.idfahelper.simulator")
    }
    @MainActor func wait(_ controller: IOSIDFAController) async throws {
        for _ in 0..<100 where controller.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(controller.busy)
    }
    @MainActor func testCacheIsDeviceScopedSurvivesFailureAndRevocationReplacesValue() async throws {
        let suite = "IDFATest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var value = result()
        var failure = false
        let controller = IOSIDFAController(defaults: defaults) { _, _, _ in
            if failure { throw LocalBuildError.message("disconnected") }; return value
        }
        controller.read(phone); try await wait(controller)
        XCTAssertEqual(controller.record?.result.usableIDFA, syntheticIDFA)
        failure = true
        controller.read(phone); try await wait(controller)
        XCTAssertEqual(controller.record?.result.usableIDFA, syntheticIDFA)
        XCTAssertNotNil(controller.error)
        let other = IOSDevice(udid: "other", name: "Other", kind: .usb)
        controller.select(other); XCTAssertNil(controller.record)
        controller.select(phone); XCTAssertEqual(controller.record?.result.usableIDFA, syntheticIDFA)
        failure = false; value = result("denied")
        controller.read(phone); try await wait(controller)
        XCTAssertNil(controller.record?.result.usableIDFA)
        let restored = IOSIDFAController(defaults: defaults)
        restored.select(phone)
        XCTAssertEqual(restored.record?.result.authorization, "denied")
    }
    @MainActor func testCancelledOldCompletionCannotOverwriteNewDevice() async throws {
        let suite = "IDFATest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var finish: CheckedContinuation<IOSIDFAResult, Error>?
        let controller = IOSIDFAController(defaults: defaults) { _, _, progress in
            progress("working")
            return try await withCheckedThrowingContinuation { finish = $0 }
        }
        controller.read(phone)
        for _ in 0..<100 where finish == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(finish)
        controller.select(IOSDevice(udid: "other", name: "Other", kind: .usb))
        finish?.resume(returning: result()); await Task.yield()
        XCTAssertFalse(controller.busy); XCTAssertNil(controller.record)
        controller.select(phone); XCTAssertNil(controller.record)
    }
    func testSimulatorHelperEndToEndWhenExplicitlyEnabled() async throws {
        guard let udid = ProcessInfo.processInfo.environment["LOGCAT_IDFA_SIMULATOR"] else { throw XCTSkip("Set LOGCAT_IDFA_SIMULATOR for explicit helper install/launch validation") }
        let device = IOSDevice(udid: udid, name: "QA", kind: .simulator)
        let value = try await IOSIDFAService().read(device: device, team: "", progress: { _ in })
        XCTAssertTrue(value.isSimulator); XCTAssertNil(value.usableIDFA)
        XCTAssertEqual(value.idfa, IOSIDFAResult.zero)
    }
}
