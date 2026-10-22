import XCTest
import AppKit
import SwiftUI
import LogcatCore
@testable import LogcatMini

final class ShortcutClipboardTests: XCTestCase {
    @MainActor func testFormattingToggleAndSelectionReset() {
        let name = "ShortcutTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LogViewModel(defaults: defaults)
        model.toggleDetailFormatting(); XCTAssertFalse(model.detailFormatted)
        model.selectedLog = LogEntry(id: 1, date: "", time: "", pid: "1", tid: "2", level: .debug, tag: "QA", message: "a=1", raw: "a=1")
        model.toggleDetailFormatting(); XCTAssertFalse(model.detailFormatted, "Do not format while parsing")
        model.canFormatDetail = true; model.toggleDetailFormatting()
        XCTAssertTrue(model.detailFormatted); XCTAssertEqual(model.activeFindPane, .detail)
        model.inspectorFullscreen = true; model.toggleDetailFormatting(); XCTAssertFalse(model.detailFormatted)
        model.toggleDetailFormatting(); model.selectedLog = nil
        XCTAssertFalse(model.detailFormatted); XCTAssertFalse(model.canFormatDetail)
    }
    @MainActor func testClipboardContainsFullResolutionImageAndNoFileOrTextPayload() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 9, pixelsHigh: 17, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try ScreenshotClipboard.copy(png, to: board)
        XCTAssertEqual(board.data(forType: .png), png)
        let pasted = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(board.data(forType: .tiff))))
        XCTAssertEqual(pasted.pixelsWide, 9); XCTAssertEqual(pasted.pixelsHigh, 17)
        XCTAssertNil(board.string(forType: .string)); XCTAssertNil(board.string(forType: .fileURL))
        XCTAssertThrowsError(try ScreenshotClipboard.copy(Data("invalid".utf8), to: board))
        XCTAssertEqual(board.data(forType: .png), png, "A failed decode must preserve existing clipboard data")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        try png.write(to: file); try ScreenshotClipboard.copyFile(file, to: board)
        XCTAssertEqual(board.data(forType: .png), png)
    }
    func testShortcutDefinitionsAreUniqueAndFormattingUsesCommandJ() {
        let signatures = AppShortcut.allCases.map { String($0.key.character) + ":" + String($0.modifiers.rawValue) }
        XCTAssertEqual(Set(signatures).count, signatures.count)
        XCTAssertEqual(AppShortcut.format.label, "⌘J")
        XCTAssertEqual(AppShortcut.format.modifiers, .command)
        XCTAssertEqual(AppShortcut.screenshotCopy.label, "⇧⌘C")
    }
}
