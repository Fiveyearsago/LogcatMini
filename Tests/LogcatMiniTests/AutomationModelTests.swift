import XCTest
@testable import LogcatMini
@testable import LogcatCore

final class AutomationModelTests: XCTestCase {
    @MainActor func testSuiteAndToolPreferencesSurviveModelRecreation() throws {
        let name = "LogcatMini.AutomationModelTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: support)
        }
        let first = AutomationModel(defaults: defaults, support: support)
        first.loadFixtureSuite()
        let id = try XCTUnwrap(first.suite?.suiteId)
        first.tools.aapt2 = "/test/custom/aapt2"
        first.outputRoot = support.appendingPathComponent("custom-runs")
        var updated = try XCTUnwrap(first.suite); updated.name = "Saved revision"
        first.saveSuite(updated)
        let second = AutomationModel(defaults: defaults, support: support)
        XCTAssertEqual(second.tools.aapt2, "/test/custom/aapt2")
        XCTAssertEqual(second.outputRoot, first.outputRoot)
        XCTAssertEqual(second.suites.first(where: { $0.suiteId == id })?.name, "Saved revision")
        XCTAssertEqual(second.suites.first?.revision, 2)
        XCTAssertEqual(second.suites.first?.cases.count, 4)
    }
}
