import XCTest
import LogcatCore
@testable import LogcatMini

final class FilterHistoryModelTests: XCTestCase {
    @MainActor func testRestoreAndFreshLaunchWithPersistentFavorites() {
        let name = "FilterHistoryModelTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LogViewModel(defaults: defaults)
        model.query = "request|response"; model.tag = "MD.Network"; model.minimum = .warning; model.regex = true
        let saved = model.currentFilter
        model.toggleFilterFavorite()
        model.query = "another"; model.tag = ""; model.minimum = .verbose; model.regex = false
        model.restoreFilter(saved)
        XCTAssertEqual(model.query, "request|response"); XCTAssertEqual(model.tag, "MD.Network")
        XCTAssertTrue(model.regex); XCTAssertEqual(model.minimum, .warning)
        model.shutdown()
        let restored = LogViewModel(defaults: defaults)
        XCTAssertTrue(restored.filterHistory.isFavorite(saved))
        XCTAssertTrue(restored.query.isEmpty); XCTAssertEqual(restored.totalCount, 0)
        restored.query = "temporary"; restored.rememberFilter(); restored.clearFilterHistory()
        restored.shutdown()
        XCTAssertEqual(FilterHistory(defaults: defaults).entries.count, 1)
        XCTAssertTrue(FilterHistory(defaults: defaults).isFavorite(saved))
    }
}
