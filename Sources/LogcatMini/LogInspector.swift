import SwiftUI
import AppKit
import LogcatCore

/// Native cursor and dragging keep the divider usable even when the pointer leaves its narrow hit area.
struct InspectorDivider: NSViewRepresentable {
    var palette: ThemePalette
    var onResize: (CGFloat) -> Void
    func makeNSView(context: Context) -> DividerView { DividerView() }
    func updateNSView(_ view: DividerView, context: Context) {
        view.palette = palette; view.onResize = onResize; view.needsDisplay = true
    }
    final class DividerView: NSView {
        var palette: ThemePalette?
        var onResize: ((CGFloat) -> Void)?
        private var previousY: CGFloat = 0
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true); setAccessibilityRole(.splitter)
            setAccessibilityLabel("调整日志详情高度")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func mouseDown(with event: NSEvent) { previousY = event.locationInWindow.y }
        override func mouseDragged(with event: NSEvent) {
            let y = event.locationInWindow.y
            onResize?(y - previousY); previousY = y
        }
        override func accessibilityPerformIncrement() -> Bool { onResize?(40); return true }
        override func accessibilityPerformDecrement() -> Bool { onResize?(-40); return true }
        override func draw(_ dirtyRect: NSRect) {
            guard let palette else { return }
            palette.nsPanel.setFill(); bounds.fill()
            palette.nsLine.setFill(); NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
            palette.nsMuted.withAlphaComponent(0.65).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 20, y: bounds.midY - 1.5, width: 40, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

struct LogInspector: View {
    let entry: LogEntry
    let palette: ThemePalette
    @ObservedObject var appearance: AppearanceSettings
    @Binding var fullscreen: Bool
    @ObservedObject var find: LogFindState
    let activate: () -> Void
    let copy: (String) -> Void
    let close: () -> Void
    let simulate: () -> Void
    let decryptS: () -> Void
    @State private var containsS = false
    @State private var formattedDocument: LogFormattedDocument?
    @Binding var showFormatted: Bool
    @Binding var canFormat: Bool
    @State private var expanded = Set<Int>()
    @State private var jsonLayout: LogJSONTextLayout?
    @State private var parsedEntryID: String?
    private var contentID: String { "\(entry.id):\(entry.mergedParts)" }
    private var currentFormatted: LogFormattedDocument? { parsedEntryID == contentID ? formattedDocument : nil }
    private var currentDocument: LogJSONDocument? { currentFormatted?.json }
    private var visibleText: String { showFormatted ? currentFormatted?.text ?? entry.fullText : entry.fullText }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 10) {
                Button(action: simulate) { Label("模拟请求", systemImage: "network") }.help("从这条日志导入接口请求，编辑参数并保存请求记录")
                Button(action: decryptS) { Label("解密 s", systemImage: "lock.open") }
                    .disabled(!containsS).help(containsS ? "提取此日志中的 s 串单独解密，无需完整网络请求" : "未找到完整的 s 字段；也可从 File 菜单打开 s 串解密并手动粘贴")
                Text(showFormatted && currentFormatted != nil ? "格式化日志详情" : (entry.mergedParts > 1 ? "合并日志详情" : "原始日志详情"))
                    .font(.system(size: appearance.uiSize(10), weight: .semibold)).foregroundColor(palette.muted)
                Text(entry.tag).font(.system(size: appearance.uiSize(11), weight: .medium, design: .monospaced))
                    .foregroundColor(Color(nsColor: palette.tagColor(entry.tag))).lineLimit(1)
                Text("PID \(entry.pid)  ·  TID \(entry.tid)")
                    .font(.system(size: appearance.uiSize(10), design: .monospaced)).foregroundColor(palette.muted).lineLimit(1)
                if entry.mergedParts > 1 {
                    Text("已合并 \(entry.mergedParts) 段").font(.system(size: appearance.uiSize(10))).foregroundColor(palette.accent)
                }
                Spacer(minLength: 8)
              }
              HStack(spacing: 10) {
                Button { activate(); find.open() } label: { ShortcutLabel("查找", systemImage: "magnifyingglass", shortcut: .find) }.help("在详情中查找 · ⌘F")
                Button { fullscreen.toggle() } label: {
                    ShortcutLabel(fullscreen ? "返回列表" : "详情全屏", systemImage: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", shortcut: .detailFullscreen)
                }.help(fullscreen ? "返回日志列表（Esc）" : "全窗口查看日志详情（⌘⌥F）")
                if showFormatted, let document = currentDocument {
                    Button("全部展开") { expanded = document.containerIDs }
                    Button("全部折叠") { expanded = [] }
                }
                Button {
                    activate(); showFormatted.toggle()
                } label: {
                    ShortcutLabel(showFormatted ? "还原格式" : "格式化日志", systemImage: "curlybraces", shortcut: .format)
                }
                .disabled(currentFormatted == nil)
                .help(currentFormatted == nil ? "正在解析，或日志超出 2 MiB 预览范围；仍可查看原始日志" : "JSON 按节点展开；键值日志按字段分行、嵌套缩进；普通文本保留换行。可拖选并按 ⌘C 复制；右侧复制跟随当前模式")
                Button { copy(visibleText) } label: { ShortcutLabel("复制", systemImage: "doc.on.doc", keys: "⌥⌘C") }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .help(showFormatted ? "复制完整格式化日志，包含已折叠节点；选中部分文字可按 ⌘C 复制" : "复制完整原始日志")
                Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("关闭日志详情")
              }
            }.buttonStyle(.borderless).font(.system(size: appearance.uiSize(11)))
            if find.shown { LogFindBar(find: find, title: "在日志详情中查找", palette: palette, activate: activate) }
            if showFormatted, let document = currentDocument {
                jsonContent(document)
            } else {
                DetailTextView(text: visibleText, palette: palette, fontSize: appearance.fontSize,
                               find: find, activate: activate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
        .background(palette.panel)
        .simultaneousGesture(TapGesture().onEnded { activate() })
        .onChange(of: find.query) { _ in refreshSearch() }
        .onChange(of: showFormatted) { _ in refreshSearch() }
        .onChange(of: appearance.formatDetailByDefault) { enabled in
            showFormatted = enabled && currentFormatted != nil
        }
        .onChange(of: expanded) { _ in jsonLayout = currentDocument?.textLayout(expanded: expanded) }
        .task(id: contentID) {
            formattedDocument = nil; parsedEntryID = nil; jsonLayout = nil; canFormat = false; showFormatted = false; expanded = []; containsS = false
            refreshSearch()
            let message = entry.displayMessage, id = contentID
            let (result, hasS) = await Task.detached(priority: .userInitiated) {
                (LogFormattedDocument.parse(message), !LogSExtractor.values(in: message).isEmpty)
            }.value
            guard !Task.isCancelled else { return }
            formattedDocument = result; parsedEntryID = id; canFormat = result != nil; containsS = hasS
            expanded = Set(result?.json?.fragments.map { $0.root.id } ?? [])
            jsonLayout = result?.json?.textLayout(expanded: expanded)
            showFormatted = appearance.formatDetailByDefault && result != nil
            refreshSearch()
        }
    }
    private func refreshSearch() {
        if showFormatted, let document = currentDocument {
            var matches: [String] = []
            let hits = LogSearch.jsonHits(in: document, query: find.query)
            for fragment in document.fragments {
                if !LogSearch.ranges(in: fragment.prefix, query: find.query).isEmpty { matches.append("prefix:\(fragment.id)") }
                let ids = Set(LogJSONTreeRow.visible(root: fragment.root, expanded: document.containerIDs).map { $0.node.id })
                matches += hits.filter { ids.contains($0.nodeID) }.map { "node:\($0.nodeID)" }
            }
            if !LogSearch.ranges(in: document.suffix, query: find.query).isEmpty { matches.append("suffix") }
            find.replaceMatches(matches)
        } else {
            find.replaceMatches(LogSearch.ranges(in: visibleText, query: find.query).map { String($0.location) })
        }
    }
    private func jsonContent(_ document: LogJSONDocument) -> some View {
        return DetailTextView(text: jsonLayout?.text ?? "", palette: palette, fontSize: appearance.fontSize,
                              find: find, activate: activate, jsonLayout: jsonLayout, toggleNode: { id in
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: find.navigation) { _ in revealJSONMatch(document) }
        .onAppear { revealJSONMatch(document) }
    }
    private func revealJSONMatch(_ document: LogJSONDocument) {
        guard let target = find.current,
              let hit = LogSearch.jsonHits(in: document, query: find.query).first(where: { "node:\($0.nodeID)" == target }) else { return }
        expanded.formUnion(hit.ancestors)
    }
}
