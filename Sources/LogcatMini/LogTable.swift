import SwiftUI
import AppKit
import LogcatCore

private final class LogCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        label.allowsExpansionToolTips = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label); textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class LogRowView: NSTableRowView {
    var palette: ThemePalette?
    var level: LogLevel = .verbose
    var alternate = false
    // Keep semantic text colors when selected; use a theme-specific selection fill.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawBackground(in dirtyRect: NSRect) {
        guard let palette = palette else { return }
        palette.rowColor(level: level, alternate: alternate).setFill()
        bounds.fill()
        if level.rank >= LogLevel.warning.rank {
            palette.levelColor(level).withAlphaComponent(0.65).setFill()
            NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard let palette = palette, selectionHighlightStyle != .none else { return }
        palette.nsSelection.setFill(); bounds.fill()
        palette.nsAccent.withAlphaComponent(0.5).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

private final class LogHeaderCell: NSTableHeaderCell {
    var palette: ThemePalette?
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let palette = palette else { super.draw(withFrame: cellFrame, in: controlView); return }
        palette.nsPanel.setFill(); cellFrame.fill()
        palette.nsLine.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        let title = NSAttributedString(string: stringValue, attributes: [.font: font ?? NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: palette.nsMuted])
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: cellFrame).addClip()
        title.draw(at: NSPoint(x: cellFrame.minX + 6, y: cellFrame.midY - title.size().height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class CopyTableView: NSTableView {
    var copyLogs: (() -> Void)?
    var activate: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        let scroll = enclosingScrollView as? LogScrollView
        let x = scroll?.contentView.bounds.minX ?? 0
        activate?(); super.mouseDown(with: event)
        // Selecting a very wide cell must not auto-scroll its far edge into view.
        if let scroll { scroll.scrollHorizontally(by: x - scroll.contentView.bounds.minX) }
    }
    private var fittingColumns = false
    private(set) var messageContentWidth: CGFloat = 0
    func revealRowVertically(_ row: Int) {
        let scroll = enclosingScrollView as? LogScrollView
        let x = scroll?.contentView.bounds.minX ?? 0
        scrollRowToVisible(row)
        if let scroll { scroll.scrollHorizontally(by: x - scroll.contentView.bounds.minX) }
    }
    /// Measure only new messages while appending; filters, merged records and font changes rebuild the width.
    func measureMessages(_ entries: ArraySlice<LogEntry>, fontSize: Double, reset: Bool) {
        if reset { messageContentWidth = 0 }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        for entry in entries {
            let width = NSAttributedString(string: entry.displayMessage, attributes: [.font: font]).size().width
            messageContentWidth = max(messageContentWidth, ceil(width) + 4 + LogMessageCellView.trailingInset)
        }
    }
    /// Fill the viewport for short logs, or expand the entire document to fit the longest message.
    func fitVisibleColumns(to viewportWidth: CGFloat) {
        guard !fittingColumns, viewportWidth > 0, viewportWidth.isFinite else { return }
        let visible = tableColumns.enumerated().filter { !$0.element.isHidden }
        guard let flexible = visible.first(where: { $0.element.identifier.rawValue == "message" }) ?? visible.last else { return }
        fittingColumns = true; defer { fittingColumns = false }
        // Use AppKit's actual column geometry, which includes spacing and style-dependent insets.
        let occupied = rect(ofColumn: visible.last!.offset).maxX - flexible.element.width
        let contentWidth = flexible.element.identifier.rawValue == "message" ? messageContentWidth : 0
        let width = max(flexible.element.minWidth, viewportWidth - occupied, contentWidth)
        if abs(flexible.element.width - width) > 0.5 { flexible.element.width = width }
        let documentWidth = max(viewportWidth, occupied + flexible.element.width)
        if abs(frame.width - documentWidth) > 0.5 { setFrameSize(NSSize(width: documentWidth, height: frame.height)) }
    }
    func revealMessageMatch(_ query: String, row: Int) {
        let column = column(withIdentifier: .init("message"))
        guard !query.isEmpty, column >= 0, !tableColumns[column].isHidden,
              let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? LogMessageCellView,
              let text = cell.textField?.attributedStringValue,
              let scroll = enclosingScrollView as? LogScrollView else { return }
        let range = (text.string as NSString).range(of: query, options: .caseInsensitive)
        guard range.location != NSNotFound else { return }
        let x = frameOfCell(atColumn: column, row: row).minX
            + text.attributedSubstring(from: NSRange(location: 0, length: range.location)).size().width
        let width = text.attributedSubstring(from: range).size().width
        let visible = scroll.contentView.bounds
        if x < visible.minX + 16 { scroll.scrollHorizontally(by: x - 16 - visible.minX) }
        else if x + width > visible.maxX - 16 {
            scroll.scrollHorizontally(by: min(x - 16, x + width + 16 - visible.width) - visible.minX)
        }
    }
    @objc func copy(_ sender: Any?) { copyLogs?() }
    override func scrollWheel(with event: NSEvent) {
        if let scroll = enclosingScrollView as? LogScrollView { scroll.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyLogs?() }
        else if [123, 124].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                let scroll = enclosingScrollView as? LogScrollView {
            scroll.scrollHorizontally(by: event.keyCode == 124 ? 240 : -240)
        } else { super.keyDown(with: event) }
    }
}

final class LogScrollView: NSScrollView {
    private var wheelMonitor: Any?
    override init(frame: NSRect) {
        super.init(frame: frame)
        hasHorizontalScroller = true; horizontalScrollElasticity = .none
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
        guard window != nil else { return }
        // AppKit may consume horizontal gestures before scrollWheel reaches the table.
        // Route the gesture to the shared viewport regardless of the row under the pointer.
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) else { return event }
            self.scrollWheel(with: event)
            return nil
        }
    }
    deinit { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard clipView === contentView, let table = documentView as? NSTableView,
              let header = table.headerView, let headerClip = header.superview as? NSClipView else { return }
        if header.frame.width != table.frame.width {
            header.setFrameSize(NSSize(width: table.frame.width, height: header.frame.height))
        }
        headerClip.scroll(to: NSPoint(x: contentView.bounds.minX, y: headerClip.bounds.minY))
    }
    func scrollHorizontally(by delta: CGFloat) {
        let viewport = contentView.bounds
        let maximum = max(0, (documentView?.frame.width ?? 0) - viewport.width)
        contentView.scroll(to: NSPoint(x: min(maximum, max(0, viewport.minX + delta)), y: viewport.minY))
        reflectScrolledClipView(contentView)
    }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) {
            let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            scrollHorizontally(by: -delta * (event.hasPreciseScrollingDeltas ? 1 : 12))
        } else { super.scrollWheel(with: event) }
    }
    override func tile() {
        super.tile()
        (documentView as? CopyTableView)?.fitVisibleColumns(to: contentSize.width)
        scrollHorizontally(by: 0)
    }
}

struct LogTable: NSViewRepresentable {
    var entries: [LogEntry]
    var revision: Int
    var palette: ThemePalette
    var fontSize: Double
    var visibleColumns: [LogColumn]
    var filterKey: String
    @Binding var follow: Bool
    @Binding var selected: LogEntry?
    @ObservedObject var find = LogFindState()
    var activate: () -> Void = {}
    var didCopy: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = LogScrollView(), table = CopyTableView()
        table.backgroundColor = palette.nsCanvas
        table.rowHeight = ceil(fontSize * 1.45 + 10); table.intercellSpacing = NSSize(width: 12, height: 0)
        table.style = .plain; table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .noColumnAutoresizing
        let definitions: [(String, String, CGFloat)] = [("level", "等级", 38), ("time", "时间", 107), ("tag", "Tag", 175), ("pid", "PID", 62), ("message", "消息", 700)]
        for (key, title, width) in definitions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width * fontSize / 11; column.minWidth = key == "message" ? 200 : 30
            column.maxWidth = .greatestFiniteMagnitude
            column.isHidden = !visibleColumns.contains { $0.rawValue == key }
            column.headerCell = LogHeaderCell(textCell: title)
            column.resizingMask = .userResizingMask
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.activate = activate
        table.copyLogs = { [weak coordinator = context.coordinator] in coordinator?.copySelection() }
        let menu = NSMenu(); menu.addItem(withTitle: "复制选中日志", action: #selector(Coordinator.copyMenu(_:)), keyEquivalent: "").target = context.coordinator
        menu.addItem(withTitle: "全选", action: #selector(NSTableView.selectAll(_:)), keyEquivalent: "").target = table
        table.menu = menu
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = true; scroll.backgroundColor = table.backgroundColor
        context.coordinator.table = table
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak coordinator = context.coordinator] _ in
            coordinator?.parent.follow = false
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.table?.activate = activate
        guard let table = coordinator.table else { return }
        let styleKey = "\(palette.id):\(fontSize)"
        let fontChanged = coordinator.lastFontSize != fontSize
        let styleChanged = coordinator.lastStyleKey != styleKey
        let columnsChanged = coordinator.lastVisibleColumns != visibleColumns
        let findChanged = coordinator.lastFindQuery != find.query
        let changed = coordinator.lastRevision != revision || styleChanged || columnsChanged || findChanged
        let enabledFollow = follow && !coordinator.lastFollow
        let topRow = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
        if columnsChanged {
            for column in table.tableColumns { column.isHidden = !visibleColumns.contains { $0.rawValue == column.identifier.rawValue } }
            coordinator.lastVisibleColumns = visibleColumns
        }
        if styleChanged {
            coordinator.highlightCache.removeAllObjects()
            let ratio = fontSize / coordinator.lastFontSize
            if coordinator.lastStyleKey != nil && ratio != 1 {
                for column in table.tableColumns { column.width *= ratio }
            }
            table.rowHeight = ceil(fontSize * 1.45 + 10)
            table.backgroundColor = palette.nsCanvas; scroll.backgroundColor = palette.nsCanvas
            scroll.appearance = NSAppearance(named: palette.dark ? .darkAqua : .aqua)
            for column in table.tableColumns {
                column.headerCell.font = .systemFont(ofSize: max(12, fontSize * 0.85), weight: .semibold)
                (column.headerCell as? LogHeaderCell)?.palette = palette
            }
            table.headerView?.needsDisplay = true
            coordinator.lastFontSize = fontSize
        }
        if changed {
            let selectionContextChanged = coordinator.lastFilterKey != filterKey
            let selectedIDs = selectionContextChanged ? Set(selected.map { [$0.id] } ?? [])
                : Set(table.selectedRowIndexes.compactMap { coordinator.rows.indices.contains($0) ? coordinator.rows[$0].id : nil })
            let oldCount = coordinator.rows.count
            let appended = oldCount > 0 && entries.count >= oldCount && entries.first?.id == coordinator.rows.first?.id && entries[oldCount - 1] == coordinator.rows.last
            let sameFilter = coordinator.lastFilterKey == filterKey && !styleChanged && !columnsChanged && !findChanged
            // Chunk merging replaces only a short tail. It must not remeasure the entire history.
            var sharedCount = 0
            if sameFilter && entries.first?.id == coordinator.rows.first?.id {
                sharedCount = min(oldCount, entries.count)
                while sharedCount > 0 && entries[sharedCount - 1] != coordinator.rows[sharedCount - 1] { sharedCount -= 1 }
            }
            let resetWidth = sharedCount == 0 || fontChanged || coordinator.lastFilterKey != filterKey
            table.measureMessages(resetWidth ? entries[...] : entries.dropFirst(sharedCount), fontSize: fontSize, reset: resetWidth)
            coordinator.rows = entries; coordinator.lastRevision = revision
            coordinator.updating = true
            if sameFilter {
                if oldCount != entries.count { table.noteNumberOfRowsChanged() }
                if !appended && !entries.isEmpty {
                    let visibleRange = table.rows(in: table.visibleRect)
                    if visibleRange.location != NSNotFound {
                        let end = min(entries.count, visibleRange.location + visibleRange.length)
                        if visibleRange.location < end {
                            table.reloadData(forRowIndexes: IndexSet(integersIn: visibleRange.location..<end), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                        }
                    }
                }
            } else { table.reloadData() }
            if !selectedIDs.isEmpty && (!appended || selectionContextChanged) {
                let indexes = IndexSet(entries.indices.filter { selectedIDs.contains(entries[$0].id) || !selectedIDs.isDisjoint(with: entries[$0].sourceIDs) })
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            } else if selectionContextChanged, selected == nil {
                table.deselectAll(nil)
            }
            coordinator.updating = false
            coordinator.lastFilterKey = filterKey
            coordinator.lastStyleKey = styleKey
            table.enumerateAvailableRowViews { view, index in
                if let row = view as? LogRowView, entries.indices.contains(index) {
                    coordinator.configure(row, at: index)
                }
            }
        }
        if changed { scroll.tile() }
        if (styleChanged || columnsChanged) && !follow && topRow >= 0 && topRow < entries.count {
            table.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: table.rect(ofRow: topRow).minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if follow && (changed || enabledFollow) && !entries.isEmpty { table.revealRowVertically(entries.count - 1) }
        coordinator.lastFollow = follow
        coordinator.lastFindQuery = find.query
        if coordinator.lastFindNavigation != find.navigation {
            coordinator.lastFindNavigation = find.navigation
            if let id = find.current, let row = entries.firstIndex(where: { String($0.id) == id }) {
                coordinator.updating = true
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.revealRowVertically(row)
                coordinator.updating = false
                DispatchQueue.main.async { if find.current == id { self.follow = false; self.selected = entries[row] } }
                table.revealMessageMatch(find.query, row: row)
            }
        }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: LogTable
        var rows: [LogEntry] = []
        weak var table: CopyTableView?
        var lastFindQuery = ""
        var lastFindNavigation = -1
        var lastRevision = -1
        var lastFollow = true
        var lastFilterKey: String?
        var lastStyleKey: String?
        var lastFontSize: Double = 14
        var lastVisibleColumns: [LogColumn] = []
        var updating = false
        var observer: NSObjectProtocol?
        let highlightCache = NSCache<NSString, NSAttributedString>()
        init(_ parent: LogTable) {
            self.parent = parent
            highlightCache.countLimit = 1_200
            highlightCache.totalCostLimit = 8 * 1_024 * 1_024
        }
        deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        fileprivate func configure(_ row: LogRowView, at index: Int) {
            row.palette = parent.palette; row.level = rows[index].level; row.alternate = index % 2 == 1
            row.needsDisplay = true
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard rows.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("logRow")
            let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? LogRowView) ?? LogRowView()
            view.identifier = identifier; configure(view, at: row)
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column = column else { return nil }
            let entry = rows[row], key = column.identifier.rawValue
            let reused = tableView.makeView(withIdentifier: column.identifier, owner: nil)
            let cell: NSTableCellView = key == "message"
                ? (reused as? LogMessageCellView ?? LogMessageCellView())
                : (reused as? LogCellView ?? LogCellView())
            cell.identifier = column.identifier
            guard let text = cell.textField else { return cell }
            if key == "message" {
                let identity = "\(entry.id):\(entry.mergedParts)"
                let cacheKey = identity as NSString
                let rendered: NSAttributedString
                if let cached = highlightCache.object(forKey: cacheKey) { rendered = cached }
                else {
                    rendered = LogTextRenderer.attributed(entry.displayMessage, palette: parent.palette, fontSize: parent.fontSize, lineBreakMode: .byClipping, level: entry.level)
                    highlightCache.setObject(rendered, forKey: cacheKey, cost: rendered.length * 2 + 256)
                }
                (cell as? LogMessageCellView)?.setMessage(FindHighlight.apply(rendered, query: parent.find.query))
            } else {
                let value: String, color: NSColor
                switch key {
                case "level": value = entry.level.rawValue; color = parent.palette.levelColor(entry.level)
                case "time": value = entry.time; color = parent.palette.levelColor(entry.level)
                case "tag": value = entry.tag; color = parent.palette.levelColor(entry.level)
                default: value = entry.pid; color = parent.palette.levelColor(entry.level)
                }
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                text.attributedStringValue = FindHighlight.apply(NSAttributedString(string: value, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: key == "level" ? .semibold : .regular),
                    .foregroundColor: color, .paragraphStyle: paragraph
                ]), query: parent.find.query)
            }
            text.toolTip = nil
            cell.toolTip = nil
            text.setAccessibilityLabel(column.title + " " + text.stringValue)
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let row = table?.selectedRow, rows.indices.contains(row) else { return }
            parent.selected = rows[row]
        }
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table = table, let scroll = table.enclosingScrollView else { return }
            table.fitVisibleColumns(to: scroll.contentSize.width)
        }
        func tableView(_ tableView: NSTableView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, row: Int) -> Bool { false }
        @objc func copyMenu(_ sender: Any?) { copySelection() }
        func copySelection() {
            guard let table = table else { return }
            let text = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].fullText : nil }.joined(separator: "\n")
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(text, forType: .string) { parent.didCopy() }
        }
    }
}
