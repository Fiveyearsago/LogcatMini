import XCTest
@testable import LogcatCore

final class FilterHistoryTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let name = "FilterHistoryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
    }
    func testPersistenceAndExactCombinationDeduplication() {
        withDefaults { defaults in
            var history = FilterHistory(defaults: defaults)
            let a = SavedLogFilter(query: "failed | 请求", tag: "Network|HTTP", regex: false, minimum: 2)
            let b = SavedLogFilter(query: "failed | 请求", tag: "Other", regex: false, minimum: 2)
            history.remember(a); history.toggleFavorite(a); history.remember(b); history.remember(a)
            let restored = FilterHistory(defaults: defaults)
            XCTAssertEqual(restored.entries.count, 2)
            XCTAssertEqual(restored.favorites.first?.filter, a)
            XCTAssertEqual(restored.recent.first?.filter, b)
        }
    }
    func testRecentsExpireButFavoritesSurviveClearAndRestart() {
        withDefaults { defaults in
            var history = FilterHistory(defaults: defaults)
            let favorite = SavedLogFilter(query: "saved")
            history.toggleFavorite(favorite)
            for i in 0..<45 { history.remember(SavedLogFilter(query: "term\(i)")) }
            XCTAssertEqual(history.recent.count, 30)
            XCTAssertEqual(history.recent.first?.filter.query, "term44")
            XCTAssertTrue(history.isFavorite(favorite))
            history.clearRecent()
            XCTAssertEqual(FilterHistory(defaults: defaults).entries.count, 1)
            history.toggleFavorite(favorite)
            XCTAssertFalse(FilterHistory(defaults: defaults).isFavorite(favorite))
        }
    }
    func testEmptyAndInvalidIgnoredButTagOnlyAndLevelOnlyAllowed() {
        withDefaults { defaults in
            var history = FilterHistory(defaults: defaults)
            history.remember(SavedLogFilter(query: "  "))
            history.remember(SavedLogFilter(query: "[", regex: true))
            XCTAssertTrue(history.entries.isEmpty)
            history.remember(SavedLogFilter(query: "", tag: "Network"))
            history.remember(SavedLogFilter(query: "", minimum: 4))
            history.remember(SavedLogFilter(query: "  x", regex: true))
            XCTAssertEqual(history.entries.count, 3)
            XCTAssertEqual(history.entries.first?.filter.query, "  x")
        }
    }
    func testCorruptPersistedHistoryIsSafe() {
        withDefaults { defaults in
            defaults.set(Data("broken".utf8), forKey: "logFilterHistory.v1")
            XCTAssertTrue(FilterHistory(defaults: defaults).entries.isEmpty)
            defaults.set(Data(#"[{"filter":{"query":"x","tag":"","regex":false,"minimum":999},"favorite":true}]"#.utf8), forKey: "logFilterHistory.v1")
            XCTAssertTrue(FilterHistory(defaults: defaults).entries.isEmpty)
        }
    }
}
