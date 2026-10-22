import XCTest
import AppKit
@testable import LogcatMini
@testable import LogcatCore

final class DetailSelectionTests: XCTestCase {
    @MainActor func testNativeSelectionCopiesAcrossJSONLinesAndHighlightUpdatesKeepSelection() throws {
        let doc = try XCTUnwrap(LogFormattedDocument.parse(#"{"one":1,"two":{"中文":"value"},"three":3}"#))
        let view = DetailNativeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.replaceContent(LogTextRenderer.details(doc.text, palette: AppTheme.nightfall.palette(for: .dark), fontSize: 14))
        let range = (doc.text as NSString).range(of: "  \"one\": 1,\n  \"two\": {\n    \"中文\": \"value\"")
        XCTAssertNotEqual(range.location, NSNotFound)
        view.setSelectedRange(range)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: clipboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(clipboard.string(forType: .string), (doc.text as NSString).substring(with: range))
        view.replaceContent(LogTextRenderer.details(doc.text, palette: AppTheme.paper.palette(for: .light), fontSize: 16))
        XCTAssertEqual(view.selectedRange(), range)
        view.replaceContent(NSAttributedString(string: "different record"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
    }
    @MainActor func testNativeSelectAllCopiesFormattedKeyValueText() throws {
        let formatted = try XCTUnwrap(LogFormattedDocument.parse("event=done info={code=200, result=success}"))
        let view = DetailNativeTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.replaceContent(NSAttributedString(string: formatted.text))
        view.selectAll(nil)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: clipboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(clipboard.string(forType: .string), "event=done\ninfo={\n  code=200,\n  result=success\n}")
    }
}
