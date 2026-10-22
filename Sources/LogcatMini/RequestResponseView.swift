import SwiftUI
import AppKit
import LogcatCore

/// Uses the log inspector's parser, selectable native text and per-node disclosure controls.
struct RequestResponseView: View {
    let response: ReplayResponse
    @ObservedObject var appearance: AppearanceSettings
    var fullscreen = false
    var toggleFullscreen: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var find = LogFindState()
    @State private var document: LogJSONDocument?
    @State private var parsedBody: String?
    @State private var expanded = Set<Int>()
    @State private var layout: LogJSONTextLayout?
    @State private var formatted = true
    private var palette: ThemePalette { appearance.theme.palette(for: colorScheme) }
    private var currentDocument: LogJSONDocument? { parsedBody == response.body ? document : nil }
    private var currentLayout: LogJSONTextLayout? { formatted && currentDocument != nil ? layout : nil }
    private var copyText: String { formatted ? currentDocument?.formattedText ?? response.body : response.body }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(response.status.map { "HTTP \($0)" } ?? "未收到 HTTP 响应").font(.headline)
                Text(String(format: "%.0f ms", response.elapsed * 1000)).foregroundColor(palette.muted)
                if response.truncated { Text("响应仅保留前 2 MiB").foregroundColor(palette.warning) }
                Spacer()
                if let toggleFullscreen {
                    Button(action: toggleFullscreen) {
                        Label(fullscreen ? "返回请求" : "响应全屏", systemImage: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.help(fullscreen ? "返回请求编辑区（Esc）" : "在当前窗口铺满查看响应")
                }
            }
            if let error = response.error { Text(error).font(.system(size: 12)).foregroundColor(palette.error).textSelection(.enabled) }
            if !response.headers.isEmpty {
                DisclosureGroup("响应头") {
                    ScrollView { Text(response.headers).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 105)
                }.font(.system(size: 12))
            }
            HStack(spacing: 12) {
                Button { find.open() } label: { Label("查找", systemImage: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                Button(formatted && currentDocument != nil ? "原始响应" : "格式化 JSON") { formatted.toggle() }
                    .disabled(currentDocument == nil)
                if formatted, let document = currentDocument {
                    Button("全部展开") { expanded = document.containerIDs }
                    Button("全部折叠") { expanded = [] }
                }
                Spacer()
                Button("复制响应") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copyText, forType: .string)
                }.help("复制当前模式的完整响应，包含折叠节点；选中文字可按 ⌘C 复制")
            }.buttonStyle(.borderless).font(.system(size: 12))
            if find.shown { LogFindBar(find: find, title: "在响应中查找", palette: palette) }
            DetailTextView(text: currentLayout?.text ?? response.body, palette: palette, fontSize: appearance.fontSize,
                           find: find, activate: {}, jsonLayout: currentLayout, toggleNode: { id in
                if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            }, accessibilityLabel: currentLayout == nil ? "原始响应文本" : "可展开节点的 JSON 响应")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8).background(palette.field)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.line))
        }
        .onChange(of: expanded) { _ in layout = currentDocument?.textLayout(expanded: expanded) }
        .onChange(of: formatted) { _ in refreshSearch() }
        .onChange(of: find.query) { _ in refreshSearch() }
        .onChange(of: find.navigation) { _ in revealMatch() }
        .task(id: response.body) {
            document = nil; parsedBody = nil; layout = nil; expanded = []; formatted = true
            refreshSearch()
            let body = response.body
            let parsed = await Task.detached(priority: .userInitiated) { LogJSONDocument.parse(body) }.value
            guard !Task.isCancelled else { return }
            document = parsed; parsedBody = body
            expanded = Set(parsed?.fragments.map { $0.root.id } ?? [])
            layout = parsed?.textLayout(expanded: expanded)
            refreshSearch()
        }
    }
    private func refreshSearch() {
        if formatted, let document = currentDocument {
            var matches: [String] = []
            let hits = LogSearch.jsonHits(in: document, query: find.query)
            for fragment in document.fragments {
                if !LogSearch.ranges(in: fragment.prefix, query: find.query).isEmpty { matches.append("prefix:\(fragment.id)") }
                let ids = Set(LogJSONTreeRow.visible(root: fragment.root, expanded: document.containerIDs).map { $0.node.id })
                matches += hits.filter { ids.contains($0.nodeID) }.map { "node:\($0.nodeID)" }
            }
            if !LogSearch.ranges(in: document.suffix, query: find.query).isEmpty { matches.append("suffix") }
            find.replaceMatches(matches)
            revealMatch()
        } else {
            find.replaceMatches(LogSearch.ranges(in: response.body, query: find.query).map { String($0.location) })
        }
    }
    private func revealMatch() {
        guard formatted, let document = currentDocument, let target = find.current,
              let hit = LogSearch.jsonHits(in: document, query: find.query).first(where: { "node:\($0.nodeID)" == target }) else { return }
        expanded.formUnion(hit.ancestors)
    }
}
