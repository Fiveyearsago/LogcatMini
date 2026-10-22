import XCTest
import SwiftUI
import AppKit
import LogcatCore
@testable import LogcatMini

final class LogTableLayoutTests: XCTestCase {
    @MainActor private func makeTable(width: CGFloat) -> (LogScrollView, CopyTableView) {
        let scroll = LogScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        let table = CopyTableView(frame: scroll.bounds)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 12, height: 0)
        for (id, width) in [("level", 50.0), ("time", 150), ("tag", 230), ("pid", 80), ("message", 700)] {
            let column = NSTableColumn(identifier: .init(id))
            column.width = width; column.minWidth = id == "message" ? 200 : 30
            column.maxWidth = .greatestFiniteMagnitude
            table.addTableColumn(column)
        }
        scroll.documentView = table; scroll.tile()
        return (scroll, table)
    }
    @MainActor func testMessageFillsWideWindowAndShrinksWhenWindowNarrows() throws {
        let (scroll, table) = makeTable(width: 2400)
        let message = try XCTUnwrap(table.tableColumn(withIdentifier: .init("message")))
        XCTAssertGreaterThan(message.width, 1700)
        XCTAssertEqual(table.rect(ofColumn: 4).maxX, scroll.contentSize.width, accuracy: 1)
        scroll.setFrameSize(NSSize(width: 1000, height: 500)); scroll.tile()
        XCTAssertLessThan(message.width, 500)
        XCTAssertEqual(table.rect(ofColumn: 4).maxX, scroll.contentSize.width, accuracy: 1)
    }
    @MainActor func testHidingPIDGivesItsSpaceToMessageAndRestoringShrinksIt() throws {
        let (scroll, table) = makeTable(width: 1600)
        let message = try XCTUnwrap(table.tableColumn(withIdentifier: .init("message")))
        let pid = try XCTUnwrap(table.tableColumn(withIdentifier: .init("pid")))
        let original = message.width
        pid.isHidden = true; scroll.tile()
        XCTAssertGreaterThan(message.width, original + 79)
        XCTAssertEqual(table.rect(ofColumn: 4).maxX, scroll.contentSize.width, accuracy: 1)
        pid.isHidden = false; scroll.tile()
        XCTAssertEqual(message.width, original, accuracy: 1)
    }
    @MainActor func testReusedMessageCellDoesNotOfferHoverTooltips() throws {
        let entry = LogEntry(id: 1, date: "", time: "", pid: "1", tid: "2", level: .info, tag: "Test", message: String(repeating: "message ", count: 100), raw: "original")
        let view = LogTable(entries: [entry], revision: 1, palette: AppTheme.nightfall.palette(for: .dark), fontSize: 15,
                            visibleColumns: LogColumn.allCases, filterKey: "", follow: .constant(false), selected: .constant(nil))
        let coordinator = view.makeCoordinator(); coordinator.rows = [entry]
        let column = NSTableColumn(identifier: .init("message"))
        let cell = try XCTUnwrap(coordinator.tableView(CopyTableView(), viewFor: column, row: 0) as? NSTableCellView)
        XCTAssertNil(cell.toolTip); XCTAssertNil(cell.textField?.toolTip)
        XCTAssertEqual(cell.textField?.allowsExpansionToolTips, false)
        XCTAssertFalse(coordinator.tableView(CopyTableView(), shouldShowCellExpansionFor: column, row: 0))
    }
    @MainActor private func entries() -> [LogEntry] {
        (1...2).map { LogEntry(id: UInt64($0), date: "", time: "", pid: "1", tid: "2", level: .info,
                              tag: "QA", message: String(repeating: "long message 中文 ", count: 80) + "THE_END", raw: "original") }
    }
    @MainActor func testWholeTableScrollsAllRowsAndHeaderTogether() throws {
        let (scroll, table) = makeTable(width: 1200)
        let entries = entries()
        let view = LogTable(entries: entries, revision: 1, palette: AppTheme.nightfall.palette(for: .dark), fontSize: 15,
                            visibleColumns: LogColumn.allCases, filterKey: "", follow: .constant(false), selected: .constant(nil))
        let coordinator = view.makeCoordinator(); coordinator.rows = entries
        table.delegate = coordinator; table.dataSource = coordinator
        table.measureMessages(entries[...], fontSize: 15, reset: true)
        table.reloadData(); scroll.tile()
        let first = try XCTUnwrap(table.view(atColumn: 4, row: 0, makeIfNecessary: true) as? LogMessageCellView)
        let second = try XCTUnwrap(table.view(atColumn: 4, row: 1, makeIfNecessary: true) as? LogMessageCellView)
        first.layoutSubtreeIfNeeded(); second.layoutSubtreeIfNeeded()
        let firstX = first.convert(.zero, to: scroll).x
        let secondX = second.convert(.zero, to: scroll).x
        scroll.scrollHorizontally(by: 240)
        XCTAssertEqual(scroll.contentView.bounds.minX, 240, accuracy: 1)
        XCTAssertEqual(first.convert(.zero, to: scroll).x, firstX - 240, accuracy: 1)
        XCTAssertEqual(second.convert(.zero, to: scroll).x, secondX - 240, accuracy: 1)
        XCTAssertEqual(table.headerView?.superview?.bounds.minX ?? -1, 240, accuracy: 1)
        XCTAssertEqual(first.textField?.frame.minX, 0)
        XCTAssertEqual(second.textField?.frame.minX, 0)
        scroll.scrollHorizontally(by: 1_000_000)
        XCTAssertEqual(scroll.contentView.bounds.maxX, table.frame.width, accuracy: 1)
        let label = try XCTUnwrap(first.textField)
        XCTAssertGreaterThanOrEqual(label.frame.width, label.attributedStringValue.size().width)
        XCTAssertEqual(first.bounds.width - label.frame.maxX, LogMessageCellView.trailingInset, accuracy: 1)
        scroll.scrollHorizontally(by: -1_000_000)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)
        XCTAssertTrue(scroll.hasHorizontalScroller)
    }
    @MainActor func testAppendedMessagesExpandSharedWidthAndFilteringClampsPosition() throws {
        let (scroll, table) = makeTable(width: 1000)
        let entries = entries()
        table.measureMessages(entries[...], fontSize: 15, reset: true); scroll.tile()
        let width = table.messageContentWidth
        let longer = LogEntry(id: 3, date: "", time: "", pid: "1", tid: "2", level: .info,
                              tag: "QA", message: String(repeating: "more ", count: 500), raw: "original")
        table.measureMessages([longer][...], fontSize: 15, reset: false); scroll.tile()
        XCTAssertGreaterThan(table.messageContentWidth, width)
        scroll.scrollHorizontally(by: 1_000_000)
        let oldOffset = scroll.contentView.bounds.minX
        scroll.setFrameSize(NSSize(width: 1800, height: 500)); scroll.tile()
        XCTAssertLessThan(scroll.contentView.bounds.minX, oldOffset)
        table.measureMessages([], fontSize: 15, reset: true); scroll.tile()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)
        XCTAssertEqual(table.frame.width, scroll.contentSize.width, accuracy: 1)
    }
    @MainActor func testFollowingVeryWideRowsPreservesHorizontalReadingPosition() {
        let (scroll, table) = makeTable(width: 1000)
        let entries = entries()
        let view = LogTable(entries: entries, revision: 1, palette: AppTheme.nightfall.palette(for: .dark), fontSize: 15,
                            visibleColumns: LogColumn.allCases, filterKey: "", follow: .constant(true), selected: .constant(nil))
        let coordinator = view.makeCoordinator(); coordinator.rows = entries
        table.delegate = coordinator; table.dataSource = coordinator
        table.measureMessages(entries[...], fontSize: 15, reset: true); table.reloadData(); scroll.tile()
        table.revealRowVertically(1)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1)
        scroll.scrollHorizontally(by: 240); table.revealRowVertically(0)
        XCTAssertEqual(scroll.contentView.bounds.minX, 240, accuracy: 1)
    }
    @MainActor func testHorizontalWheelAndShiftWheelMoveTheSharedViewport() throws {
        let (scroll, table) = makeTable(width: 1000)
        table.measureMessages(entries()[...], fontSize: 15, reset: true); scroll.tile()
        let horizontal = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                                wheelCount: 2, wheel1: 0, wheel2: -120, wheel3: 0))
        table.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: horizontal)))
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
        let previous = scroll.contentView.bounds.minX
        let shifted = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                           wheelCount: 1, wheel1: -2, wheel2: 0, wheel3: 0))
        shifted.flags = .maskShift
        table.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: shifted)))
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, previous)
        XCTAssertEqual(table.headerView?.superview?.bounds.minX ?? -1, scroll.contentView.bounds.minX, accuracy: 1)
    }
    @MainActor func testFindingLongMessageMovesSharedViewportWithoutMovingTextInsideCells() throws {
        let (scroll, table) = makeTable(width: 1000)
        let entries = entries()
        let view = LogTable(entries: entries, revision: 1, palette: AppTheme.nightfall.palette(for: .dark), fontSize: 15,
                            visibleColumns: LogColumn.allCases, filterKey: "", follow: .constant(false), selected: .constant(nil))
        let coordinator = view.makeCoordinator(); coordinator.rows = entries
        table.delegate = coordinator; table.dataSource = coordinator
        table.measureMessages(entries[...], fontSize: 15, reset: true); table.reloadData(); scroll.tile()
        table.revealMessageMatch("THE_END", row: 0)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 500)
        let first = try XCTUnwrap(table.view(atColumn: 4, row: 0, makeIfNecessary: true) as? LogMessageCellView)
        let text = try XCTUnwrap(first.textField?.attributedStringValue)
        let textEnd = table.frameOfCell(atColumn: 4, row: 0).minX + text.size().width
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxX, textEnd + 15)
        let second = try XCTUnwrap(table.view(atColumn: 4, row: 1, makeIfNecessary: true) as? LogMessageCellView)
        second.layoutSubtreeIfNeeded()
        XCTAssertEqual(second.textField?.frame.minX, 0)
    }
}
