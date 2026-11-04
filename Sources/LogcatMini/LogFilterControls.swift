import SwiftUI
import LogcatCore

/// Both device platforms use the same filter editing, history and favorite controls.
struct LogFilterControls: View {
    @ObservedObject var model: LogViewModel
    @ObservedObject var appearance: AppearanceSettings
    let palette: ThemePalette
    private enum FilterField: Hashable { case query, tag }
    @FocusState private var filterFocus: FilterField?
    var body: some View {
        filterInputs
            .onChange(of: filterFocus) { if $0 == nil { model.rememberFilter() } }
            .onDisappear { model.rememberFilter() }
    }
    private var filterInputs: some View {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundColor(palette.muted).accessibilityLabel("过滤")
                    TextField(model.regex ? "输入过滤正则表达式…" : "过滤日志、Tag、PID；多个关键词用 | 分隔", text: $model.query).textFieldStyle(.plain)
                        .focused($filterFocus, equals: .query).onSubmit { model.rememberFilter() }
                        .help(model.regex ? "按完整正则表达式匹配，忽略大小写" : "用 | 分隔多个关键词，匹配任意一个即可；例如：登录|支付|请求失败")
                    if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundColor(palette.muted) }
                    Button { model.regex.toggle() } label: { Text(".*").font(.system(size: appearance.uiSize(13), weight: .bold, design: .monospaced)).foregroundColor(model.regex ? palette.accent : palette.muted).padding(.horizontal, 5) }.buttonStyle(.plain).help("正则表达式搜索（忽略大小写）")
                    Button(action: model.toggleFilterFavorite) {
                        Image(systemName: model.filterHistory.isFavorite(model.currentFilter) ? "star.fill" : "star")
                            .foregroundColor(model.filterHistory.isFavorite(model.currentFilter) ? palette.accent : palette.muted)
                    }.buttonStyle(.plain).disabled(!model.currentFilter.canSave)
                        .help(model.filterHistory.isFavorite(model.currentFilter) ? "取消收藏当前过滤条件" : "收藏当前过滤条件")
                        .accessibilityLabel("收藏过滤条件")
                    filterHistoryMenu
                }.padding(10).background(palette.field).cornerRadius(6)
                tagFilter.frame(width: 160)
                levelFilter
            }.font(.system(size: appearance.uiSize(12)))
    }
    private var levelFilter: some View {
        HStack(spacing: 6) {
            Text("等级").foregroundColor(palette.muted)
            Picker("日志等级", selection: $model.minimum) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level == .verbose ? "全部" : level.title + "+").tag(level)
                }
            }.labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel("日志等级")
                .help("显示所选等级及以上的日志；全部包含 Verbose")
        }.padding(.horizontal, 10).padding(.vertical, 8).background(palette.field).cornerRadius(6).fixedSize()
    }
    private var tagFilter: some View {
        HStack(spacing: 8) {
            Text("TAG").font(.system(size: appearance.uiSize(9), weight: .bold, design: .monospaced)).foregroundColor(palette.muted)
            TextField("Tag1|Tag2", text: $model.tag).textFieldStyle(.plain)
                .focused($filterFocus, equals: .tag).onSubmit { model.rememberFilter() }
                .help("多个 Tag 用 | 分隔，匹配任意一个；同时满足关键词和等级条件")
                .accessibilityLabel("Tag 过滤")
            if !model.tag.isEmpty { Button { model.tag = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundColor(palette.muted) }
        }.padding(10).background(palette.field).cornerRadius(6)
    }
    private var filterHistoryMenu: some View {
        Menu {
            if model.filterHistory.entries.isEmpty { Text("暂无过滤历史，输入后按回车保存") }
            if !model.filterHistory.favorites.isEmpty {
                Section("收藏") {
                    ForEach(model.filterHistory.favorites) { entry in
                        Button("★ " + entry.filter.title) { model.restoreFilter(entry.filter) }
                    }
                }
            }
            if !model.filterHistory.recent.isEmpty {
                Section("最近使用") {
                    ForEach(model.filterHistory.recent) { entry in
                        Button(entry.filter.title) { model.restoreFilter(entry.filter) }
                    }
                }
                Divider()
                Button("清空历史（保留收藏）", action: model.clearFilterHistory)
            }
        } label: { Text("历史 / 收藏") }
            .fixedSize().help("恢复关键词、Tag、等级和正则开关；最近 30 条，收藏长期保留")
    }
}
