import XCTest
@testable import LogcatCore

final class LogColumnVisibilityTests: XCTestCase {
    private func withDefaults(_ run: (UserDefaults) throws -> Void) throws {
        let name = "LogcatMini.ColumnsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try run(defaults)
    }
    func testHiddenColumnsPersistAndRestoreInOriginalOrder() throws {
        try withDefaults { defaults in
            var columns = LogColumnVisibility(defaults: defaults)
            XCTAssertEqual(columns.visibleColumns, LogColumn.allCases)
            columns.setVisible(.pid, false); columns.setVisible(.time, false)
            var reopened = LogColumnVisibility(defaults: defaults)
            XCTAssertEqual(reopened.visibleColumns, [.level, .tag, .message])
            reopened.setVisible(.time, true)
            XCTAssertEqual(reopened.visibleColumns, [.level, .time, .tag, .message])
            reopened.reset()
            XCTAssertEqual(LogColumnVisibility(defaults: defaults).visibleColumns, LogColumn.allCases)
        }
    }
    func testLastVisibleColumnCannotBeHiddenButOtherColumnsCanBeEnabled() throws {
        try withDefaults { defaults in
            var columns = LogColumnVisibility(defaults: defaults)
            for column in LogColumn.allCases { columns.setVisible(column, false) }
            XCTAssertEqual(columns.visibleColumns, [.message])
            XCTAssertFalse(columns.canToggle(.message))
            XCTAssertTrue(columns.canToggle(.pid))
            columns.setVisible(.pid, true); columns.setVisible(.message, false)
            XCTAssertEqual(columns.visibleColumns, [.pid])
        }
    }
    func testInvalidSavedColumnsRecoverToUsableDefaults() throws {
        try withDefaults { defaults in
            for saved in [[], ["unknown"], ["pid", "unknown", "pid", "level"]] as [[String]] {
                defaults.set(saved, forKey: "logs.visibleColumns")
                XCTAssertEqual(LogColumnVisibility(defaults: defaults).visibleColumns,
                               saved.contains("pid") ? [.level, .pid] : LogColumn.allCases)
            }
        }
    }
}
