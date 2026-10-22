import SwiftUI
import AppKit
import LogcatCore

@MainActor final class LogFindState: ObservableObject {
    @Published var shown = false
    @Published var query = ""
    @Published private(set) var matches: [String] = []
    @Published private(set) var position = 0
    @Published private(set) var navigation = 0
    @Published private(set) var focusRequest = 0
    private var matchedQuery = ""
    var current: String? { matches.indices.contains(position) ? matches[position] : nil }
    var countLabel: String { query.isEmpty ? "" : (matches.isEmpty ? "无匹配" : "\(position + 1) / \(matches.count)") }
    func open() { shown = true; focusRequest += 1 }
    func close() { shown = false; query = ""; replaceMatches([]) }
    func replaceMatches(_ values: [String]) {
        guard values != matches || query != matchedQuery else { return }
        let old = current, newQuery = query != matchedQuery
        matches = values; matchedQuery = query
        position = !newQuery ? (old.flatMap { values.firstIndex(of: $0) } ?? 0) : 0
        if newQuery || old != current { navigation += 1 }
    }
    func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        position = (position + delta + matches.count) % matches.count; navigation += 1
    }
    /// Capture changes only the tail; keep the current search hit without rescanning old logs.
    func replaceLogSuffix(from firstID: UInt64, entries: [LogEntry]) {
        guard !query.isEmpty else { return }
        // A query edit is rebuilt by the model's debounce before incremental updates resume.
        guard matchedQuery == query else { return }
        let old = current
        var keep = matches.count
        while keep > 0 && (UInt64(matches[keep - 1]) ?? 0) >= firstID { keep -= 1 }
        let suffix = entries.filter { $0.fullText.range(of: query, options: .caseInsensitive) != nil }.map { String($0.id) }
        guard keep != matches.count || !suffix.isEmpty else { return }
        matches.removeLast(matches.count - keep); matches.append(contentsOf: suffix)
        if position >= keep { position = old.flatMap { matches.firstIndex(of: $0) } ?? 0 }
        if old != current { navigation += 1 }
    }
}

struct LogFindBar: View {
    @ObservedObject var find: LogFindState
    let title: String
    let palette: ThemePalette
    var activate: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            FindInput(find: find, title: title, palette: palette, activate: activate)
            Text(find.countLabel).foregroundColor(palette.muted).fixedSize()
            Button { find.move(-1) } label: { ShortcutLabel("", systemImage: "chevron.up", shortcut: .previous) }.help("上一处 · ⇧⌘G")
            Button { find.move(1) } label: { ShortcutLabel("", systemImage: "chevron.down", shortcut: .next) }.help("下一处 · ⌘G / Enter")
            Button { find.close() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭" + title)
        }.buttonStyle(.borderless).font(.system(size: 12))
            .padding(9).background(palette.field)
    }
}

/// Native focus routing ensures Cmd-F accepts typing immediately, including in a newly inserted bar.
private struct FindInput: NSViewRepresentable {
    @ObservedObject var find: LogFindState
    let title: String
    let palette: ThemePalette
    let activate: () -> Void
    func makeNSView(context: Context) -> FindTextField {
        let field = FindTextField(string: "")
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func updateNSView(_ field: FindTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = title; field.setAccessibilityLabel(title)
        field.textColor = palette.nsText
        field.activate = activate
        if field.stringValue != find.query { field.stringValue = find.query }
        if context.coordinator.focusRequest != find.focusRequest {
            context.coordinator.focusRequest = find.focusRequest
            field.pendingFocus = true
            DispatchQueue.main.async { field.focusIfNeeded() }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindInput
        var focusRequest = -1
        init(_ parent: FindInput) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { parent.find.query = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { parent.find.move(1); return true }
            return false
        }
    }
}
private final class FindTextField: NSTextField {
    var pendingFocus = false
    var activate: (() -> Void)?
    override func mouseDown(with event: NSEvent) { activate?(); super.mouseDown(with: event) }
    func focusIfNeeded() { if pendingFocus, let window { pendingFocus = false; activate?(); window.makeFirstResponder(self) } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusIfNeeded() }
}

enum FindHighlight {
    static func apply(_ text: NSAttributedString, query: String, active: NSRange? = nil) -> NSAttributedString {
        guard !query.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        for range in LogSearch.ranges(in: text.string, query: query) {
            result.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(range == active ? 1 : 0.7),
                                  .foregroundColor: NSColor.black], range: range)
        }
        return result
    }
}

/// NSTextView scrolls precisely to a match even inside a huge wrapped single line.
struct DetailTextView: NSViewRepresentable {
    let text: String
    let palette: ThemePalette
    let fontSize: Double
    @ObservedObject var find: LogFindState
    var activate: () -> Void
    var jsonLayout: LogJSONTextLayout? = nil
    var toggleNode: ((Int) -> Void)? = nil
    var accessibilityLabel: String? = nil
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 150))
        let view = DetailNativeTextView(frame: scroll.bounds)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.isRichText = false; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 0, height: 5)
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.allowsNonContiguousLayout = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak view] _ in view?.updateDisclosureButtons() }
        return scroll
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? DetailNativeTextView else { return }
        view.activate = activate
        view.toggleNode = toggleNode
        let key = "\(palette.id):\(fontSize):\(find.query):\(find.position)"
        let changedText = context.coordinator.text != text
        guard changedText || context.coordinator.key != key || context.coordinator.navigation != find.navigation else { return }
        view.jsonLines = jsonLayout?.lines ?? []
        view.disclosureColor = palette.nsAccent
        view.textContainerInset = NSSize(width: jsonLayout == nil ? 0 : 24, height: 5)
        view.setAccessibilityLabel(accessibilityLabel ?? (jsonLayout == nil ? "日志详情文本" : "可选中复制的 JSON 日志"))
        let ranges = LogSearch.ranges(in: text, query: find.query)
        let active: NSRange?
        if let layout = jsonLayout {
            active = layout.lines.first(where: { $0.id == find.current }).flatMap { line in
                ranges.first { NSIntersectionRange($0, line.range).length > 0 }
            }
        } else { active = ranges.indices.contains(find.position) ? ranges[find.position] : nil }
        if changedText || context.coordinator.key != key {
            let value = LogTextRenderer.details(text, palette: palette, fontSize: fontSize)
            view.replaceContent(FindHighlight.apply(value, query: find.query, active: active))
            view.insertionPointColor = palette.nsText
            context.coordinator.text = text; context.coordinator.key = key
        }
        if context.coordinator.navigation != find.navigation || (jsonLayout != nil && changedText) {
            context.coordinator.navigation = find.navigation
            if let active { view.scrollRangeToVisible(active) }
        }
        view.updateDisclosureButtons()
    }
    final class Coordinator {
        var text = ""; var key = ""; var navigation = -1
        var boundsObserver: NSObjectProtocol?
        deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    }
}

final class DetailNativeTextView: NSTextView {
    var activate: (() -> Void)?
    var toggleNode: ((Int) -> Void)?
    var jsonLines: [LogJSONTextLine] = []
    var disclosureColor: NSColor = .controlAccentColor
    private var disclosureButtons: [Int: NSButton] = [:]
    private var updatingDisclosures = false
    override func mouseDown(with event: NSEvent) { activate?(); super.mouseDown(with: event) }
    override func layout() { super.layout(); updateDisclosureButtons() }
    func replaceContent(_ value: NSAttributedString) {
        let selection = string == value.string ? selectedRanges : [NSValue(range: NSRange(location: 0, length: 0))]
        textStorage?.setAttributedString(value)
        selectedRanges = selection
    }
    func updateDisclosureButtons() {
        guard !updatingDisclosures else { return }
        guard !jsonLines.isEmpty else {
            for button in disclosureButtons.values { button.removeFromSuperview() }
            disclosureButtons.removeAll()
            return
        }
        guard let layoutManager, let textContainer else { return }
        updatingDisclosures = true
        defer { updatingDisclosures = false }
        let rect = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var shown = Set<Int>()
        // Binary search avoids walking thousands of preceding JSON lines on every scroll event.
        let start = Self.firstVisibleLine(in: jsonLines, at: visible.location)
        let length = textStorage?.length ?? 0
        for line in jsonLines.dropFirst(start) {
            if line.range.location > NSMaxRange(visible) { break }
            guard let id = line.containerID, line.range.location >= visible.location,
                  line.range.location < length else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: line.range.location)
            let row = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let button = disclosureButtons[id] ?? NSButton()
            if disclosureButtons[id] == nil {
                button.isBordered = false; button.imagePosition = .imageOnly
                button.target = self; button.action = #selector(toggleDisclosure(_:)); button.tag = id
                addSubview(button); disclosureButtons[id] = button
            }
            button.image = NSImage(systemSymbolName: line.expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
            button.contentTintColor = disclosureColor
            button.setAccessibilityLabel((line.expanded ? "折叠 " : "展开 ") + line.label)
            button.frame = NSRect(x: 1, y: textContainerOrigin.y + row.minY, width: 20, height: max(16, row.height))
            shown.insert(id)
        }
        for id in Array(disclosureButtons.keys) where !shown.contains(id) {
            disclosureButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
    }
    static func firstVisibleLine(in lines: [LogJSONTextLine], at location: Int) -> Int {
        var lower = 0, upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lines[middle].range.location < location { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
    @objc private func toggleDisclosure(_ sender: NSButton) {
        activate?(); toggleNode?(sender.tag)
    }
}
