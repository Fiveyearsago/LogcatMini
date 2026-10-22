import XCTest
import LogcatCore
@testable import LogcatMini

final class MultiDeviceTests: XCTestCase {
    @MainActor func testSwitchPreservesIndependentLogsAndPackageSelection() {
        let name = "MultiDeviceTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LogViewModel(defaults: defaults); model.adbPath = nil
        model.activateDevice("device-a"); model.selectedPackage = "com.test.alpha"
        model.ingest([LogEntry(id: 1, date: "", time: "", pid: "1", tid: "1", level: .error, tag: "A", message: "alpha", raw: "alpha")])
        model.selectedLog = model.visible.first
        model.activateDevice("device-b")
        XCTAssertEqual(model.totalCount, 0); XCTAssertEqual(model.selectedPackage, ""); XCTAssertNil(model.selectedLog)
        model.selectedPackage = "com.test.beta"
        model.ingest([LogEntry(id: 2, date: "", time: "", pid: "2", tid: "2", level: .debug, tag: "B", message: "beta", raw: "beta")])
        model.activateDevice("device-a")
        XCTAssertEqual(model.visible.map(\.tag), ["A"]); XCTAssertEqual(model.errorCount, 1)
        XCTAssertEqual(model.selectedPackage, "com.test.alpha")
        model.clear(); model.activateDevice("device-b")
        XCTAssertEqual(model.visible.map(\.tag), ["B"]); XCTAssertEqual(model.errorCount, 0)
        XCTAssertEqual(model.selectedPackage, "com.test.beta")
        model.activateDevice("device-a"); XCTAssertTrue(model.visible.isEmpty)
        model.shutdown()
        XCTAssertEqual(LogViewModel(defaults: defaults).totalCount, 0)
    }
}
