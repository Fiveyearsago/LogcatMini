import XCTest
import SwiftUI
import AppKit
import LogcatCore
@testable import LogcatMini

final class LogFindTests: XCTestCase {
    @MainActor func testNavigationWrapsPreservesCurrentWhenAppendingAndResetsWithQuery() {
        let find = LogFindState()
        find.open(); find.query = "one"; find.replaceMatches(["a", "b", "c"])
        XCTAssertTrue(find.shown); XCTAssertEqual(find.current, "a")
        find.move(-1); XCTAssertEqual(find.current, "c")
        find.move(1); XCTAssertEqual(find.current, "a")
        find.move(1); find.replaceMatches(["a", "b", "c", "d"])
        XCTAssertEqual(find.current, "b")
        find.query = "two"; find.replaceMatches(["a", "b", "c"])
        XCTAssertEqual(find.current, "a")
        find.close(); XCTAssertNil(find.current); XCTAssertEqual(find.query, ""); XCTAssertFalse(find.shown)
    }
    @MainActor func testListAndDetailFindAreIndependentAndUseActivePane() {
        let model = LogViewModel()
        model.openFind(); XCTAssertTrue(model.listFind.shown); XCTAssertFalse(model.follow)
        model.selectedLog = LogEntry(id: 1, date: "", time: "", pid: "1", tid: "2", level: .debug, tag: "QA", message: "test", raw: "test")
        model.openFind(.detail); XCTAssertTrue(model.detailFind.shown)
        XCTAssertTrue(model.currentFind === model.detailFind)
        XCTAssertTrue(model.closeFind()); XCTAssertTrue(model.listFind.shown)
        model.inspectorFullscreen = true; model.activeFindPane = .list
        XCTAssertTrue(model.currentFind === model.detailFind)
        model.selectedLog = nil; XCTAssertFalse(model.inspectorFullscreen)
        XCTAssertTrue(model.currentFind === model.listFind)
    }
    @MainActor func testSeverityBaseColorKeepsSyntaxColorsAndDetailsKeepOriginalPalette() throws {
        for scheme: ColorScheme in [.light, .dark] {
            let palette = AppTheme.system.palette(for: scheme)
            let green = try XCTUnwrap(palette.levelColor(.debug).usingColorSpace(.deviceRGB))
            let red = try XCTUnwrap(palette.levelColor(.error).usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(green.greenComponent, green.redComponent)
            XCTAssertGreaterThan(red.redComponent, red.greenComponent)
            let text = #"plain message {"value":42,"ok":true} https://example.com"#
            for level: LogLevel in [.debug, .error] {
                let rendered = LogTextRenderer.attributed(text, palette: palette, fontSize: 15, level: level)
                XCTAssertEqual(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, palette.levelColor(level))
                for (needle, token): (String, LogTokenKind) in [("value", .key), ("42", .number), ("true", .literal), ("https://example.com", .url)] {
                    let index = (text as NSString).range(of: needle).location
                    XCTAssertEqual(rendered.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor, palette.tokenColor(token))
                }
            }
            let details = LogTextRenderer.details(text, palette: palette, fontSize: 15)
            XCTAssertEqual(details.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, palette.nsText)
        }
    }
    @MainActor func testShortcutTogglesOnlyTheCurrentPane() {
        let model = LogViewModel()
        model.toggleFind(); XCTAssertTrue(model.listFind.shown)
        model.toggleFind(); XCTAssertFalse(model.listFind.shown)
        model.selectedLog = LogEntry(id: 1, date: "", time: "", pid: "1", tid: "2", level: .debug, tag: "QA", message: "test", raw: "test")
        model.activeFindPane = .detail
        model.toggleFind(); XCTAssertTrue(model.detailFind.shown); XCTAssertFalse(model.listFind.shown)
        model.toggleFind(); XCTAssertFalse(model.detailFind.shown)
    }
}
