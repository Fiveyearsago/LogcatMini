import SwiftUI
import LogcatCore

struct LogMergeRulesView: View {
    @ObservedObject var settings: LogMergeSettings
    @ObservedObject var appearance: AppearanceSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var editing: LogMergeRule?
    private var palette: ThemePalette { appearance.theme.palette(for: colorScheme) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("日志合并规则").font(.title2.bold())
                Text("Android 和 iOS 共用。保存后自动重新处理缓存，新的日志也会按规则合并。规则仅保存在这台 Mac 上。")
                    .foregroundColor(palette.muted)
                VStack(alignment: .leading, spacing: 8) {
                    Text("内置识别 · 自动生效").font(.headline)
                    Text("seq=123 part=1/3 正文\nresult_part=1/3 result=正文\npart=1/3 data=正文（也支持 body、content 等字段）\n(1/3) 正文 · part_0: 正文\nokhttp.OkHttpClient 的连续 JSON")
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Text("分段需连续、顺序完整，日期 / PID / TID / Tag / 等级及分组一致。内置跨度不超过 2 秒，最多 256 段、2 MiB；无总段数时还需组成完整 JSON。缺段和穿插的日志保留原样。")
                        .font(.caption).foregroundColor(palette.muted)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(palette.panel).cornerRadius(10)
                HStack {
                    Text("自定义规则（\(settings.rules.count)/32）").font(.headline)
                    Spacer()
                    Button("添加规则…") { editing = LogMergeRule() }.disabled(settings.rules.count >= 32)
                }
                if settings.rules.isEmpty {
                    Text("遇到新的分段格式时，添加一个模板并粘贴样例预览，无需修改代码。")
                        .foregroundColor(palette.muted).padding(.vertical, 12)
                }
                ForEach(settings.rules) { rule in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("启用 \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { settings.setEnabled(rule.id, $0) })).labelsHidden()
                        VStack(alignment: .leading, spacing: 5) {
                            Text(rule.name).font(.headline)
                            Text(rule.pattern).font(.system(size: 12, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                            Text("\(rule.mode == .template ? "模板" : "正则") · \(rule.tagContains.isEmpty ? "所有 Tag" : "Tag 包含 \(rule.tagContains)") · \(rule.maximumSeconds, specifier: "%.1f") 秒")
                                .font(.caption).foregroundColor(palette.muted)
                        }
                        Spacer(minLength: 4)
                        Button("编辑…") { editing = rule }.accessibilityLabel("编辑 \(rule.name)")
                        Button { settings.remove(rule.id) } label: { Image(systemName: "trash") }.accessibilityLabel("删除 \(rule.name)")
                    }.padding(14).background(palette.panel).cornerRadius(8)
                }
                Text("按列表顺序匹配，先匹配的自定义规则优先于内置规则。关闭或删除自定义规则后，缓存会按剩余规则重新合并。原始分段保留，不会丢失。")
                    .font(.caption).foregroundColor(palette.muted)
            }.padding(24)
        }.background(palette.canvas).foregroundColor(palette.text).tint(palette.accent)
            .sheet(item: $editing) { rule in LogMergeRuleEditor(settings: settings, initial: rule, palette: palette) }
    }
}

private struct LogMergeRuleEditor: View {
    @ObservedObject var settings: LogMergeSettings
    @Environment(\.dismiss) private var dismiss
    @State private var rule: LogMergeRule
    @State private var sample = "seq=42 part=1/2 {\"message\":\"你好，\nseq=42 part=2/2 世界\"}"
    @State private var preview: LogMergePreview?
    @State private var error: String?
    let palette: ThemePalette
    init(settings: LogMergeSettings, initial: LogMergeRule, palette: ThemePalette) {
        self.settings = settings; self.palette = palette; _rule = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑合并规则").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("规则名称", text: $rule.name).textFieldStyle(.roundedBorder)
                    TextField("Tag 包含（可选，留空匹配所有 Tag）", text: $rule.tagContains).textFieldStyle(.roundedBorder)
                    Picker("填写方式", selection: $rule.mode) {
                        Text("分段模板").tag(LogMergeRule.Mode.template)
                        Text("高级正则").tag(LogMergeRule.Mode.regex)
                    }.pickerStyle(.segmented)
                    Text(rule.mode == .template ? "匹配模板" : "完整消息正则").font(.headline)
                    TextEditor(text: $rule.pattern).font(.system(size: 12, design: .monospaced)).frame(height: 58).border(palette.line)
                        .accessibilityLabel("合并匹配规则")
                    Text(rule.mode == .template
                         ? "把变化的位置写成 {key}（同一条日志的编号）、{index}（当前段，从 1 开始）、{total}（总段数）、{body}（正文），每种各写一次；其余字符按原样匹配。"
                         : "使用命名组 (?<key>…)、(?<index>…)、(?<total>…)、(?<body>…)；可选 (?<prefix>…) 保留重复前缀。必须匹配整个消息。")
                        .font(.caption).foregroundColor(palette.muted)
                    HStack {
                        Button("填入 seq 示例") {
                            rule.pattern = rule.mode == .template ? "seq={key} part={index}/{total} {body}" : #"^seq=(?<key>\S+) part=(?<index>\d+)/(?<total>\d+) (?<body>.*)$"#
                        }
                        Text("最大时间跨度")
                        TextField("秒", value: $rule.maximumSeconds, format: .number).frame(width: 54).textFieldStyle(.roundedBorder)
                        Text("秒（0.1～30）").foregroundColor(palette.muted)
                    }
                    Toggle("合并后必须是完整 JSON", isOn: $rule.requireJSON)
                    Text("合并结果只拼接正文，不额外插入空格或换行。来源和顺序检查始终生效。")
                        .font(.caption).foregroundColor(palette.muted)
                    Divider()
                    Text("粘贴样例，每行一个分段").font(.headline)
                    Text("可粘贴消息正文，或带时间、PID、Tag 的完整日志；预览不会写入日志列表。")
                        .font(.caption).foregroundColor(palette.muted)
                    TextEditor(text: $sample).font(.system(size: 12, design: .monospaced)).frame(height: 100).border(palette.line)
                        .accessibilityLabel("合并样例")
                    Button("预览合并") {
                        do { preview = try LogMergePreview.evaluate(rule: rule, sample: sample); error = nil }
                        catch { self.error = error.localizedDescription; preview = nil }
                    }
                    if let preview {
                        Text(preview.mergedCount > 0 ? "\(preview.inputCount) 条输入，生成 \(preview.mergedCount) 条合并日志" : "未合并：请检查模板、分组编号、段数、顺序和来源。")
                            .foregroundColor(preview.mergedCount > 0 ? palette.accent : palette.warning)
                        ScrollView { Text(String(preview.output.prefix(50_000))).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(height: 120).padding(8).background(palette.field).cornerRadius(6)
                    }
                    if let error { Text(error).foregroundColor(palette.error).textSelection(.enabled) }
                }
            }
            Divider()
            HStack {
                Text("保存后立即应用于 Android / iOS 缓存及新日志。 ").font(.caption).foregroundColor(palette.muted)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存规则") {
                    do { try settings.save(rule); dismiss() } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 690, height: 720).background(palette.canvas).foregroundColor(palette.text).tint(palette.accent)
            .onChange(of: rule) { _ in preview = nil; error = nil }
            .onChange(of: sample) { _ in preview = nil }
    }
}
