import SwiftUI
import LogcatCore

struct AutomationCaseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: AutomationCase
    let readControls: () async throws -> [AutomationElement]
    let save: (AutomationCase) throws -> Void
    @State private var error: String?
    @State private var selectedStep: String?
    @State private var controls: [AutomationElement] = []
    @State private var reading = false
    @State private var showControls = false
    @State private var query = ""
    @State private var advanced = false
    @State private var json = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("编辑用例").font(.title2.bold()); Spacer()
                Toggle("JSON 编辑", isOn: $advanced).toggleStyle(.checkbox)
                    .onChange(of: advanced) { value in
                        if value { json = (try? AutomationJSON.encode(item)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
                        else { do { item = try AutomationJSON.decode(AutomationCase.self, from: Data(json.utf8)); error = nil } catch { self.error = error.localizedDescription; advanced = true } }
                    }
            }
            if let error { Text(error).foregroundColor(.orange).textSelection(.enabled) }
            if advanced {
                Text("可编辑前置检查和收尾步骤；保存时会校验完整用例。").foregroundColor(.secondary)
                TextEditor(text: $json).font(.system(.body, design: .monospaced))
            } else {
                HStack { TextField("用例编号", text: $item.id).disabled(true); TextField("用例名称", text: $item.name) }
                TextField("关联需求 / 验收目标", text: $item.requirement)
                TextField("前置说明", text: $item.preconditionNotes)
                HStack {
                    Picker("优先级", selection: $item.priority) { ForEach(["P0", "P1", "P2"], id: \.self) { Text($0) } }
                    Picker("起始状态", selection: $item.startPolicy) {
                        Text("保留数据并重启").tag("restart"); Text("清除数据并重启").tag("clearAndRestart")
                    }
                    Text("用例超时 ms"); TextField("180000", value: $item.timeoutMs, format: .number).frame(width: 100)
                }
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach($item.steps) { $step in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        TextField("步骤名称", text: $step.name)
                                        Picker("动作", selection: $step.action) { ForEach(TestAction.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 210)
                                        Button("↑") { move(step.id, -1) }
                                        Button("↓") { move(step.id, 1) }
                                        Button("删除") { item.steps.removeAll { $0.id == step.id } }
                                    }
                                    if step.action.needsTarget {
                                        HStack {
                                            TextField("控件 ID", text: targetBinding(step.id, \.id))
                                            TextField("精确文字", text: targetBinding(step.id, \.text))
                                            TextField("内容描述", text: targetBinding(step.id, \.contentDescription))
                                        }
                                        TextField("位于指定文字下方（可选，用于区分重复按钮）", text: targetBinding(step.id, \.belowText))
                                        Button(reading && selectedStep == step.id ? "读取中…" : "从设备当前页面选择控件") { loadControls(for: step.id) }.disabled(reading)
                                    }
                                    if step.action == .assertText {
                                        TextField("预期文字", text: optional($step.expected, default: ""))
                                        matchPicker($step.match)
                                    }
                                    if step.action == .inputText {
                                        TextField("输入内容（ASCII）", text: optional($step.text, default: ""))
                                        Toggle("先清除输入框文字", isOn: Binding(get: { step.clear ?? true }, set: { step.clear = $0 }))
                                        Text("设备输入法需切换为英文 / ASCII；输入后会核对实际文字，密码框暂不支持。").font(.caption).foregroundColor(.secondary)
                                    }
                                    if step.action == .swipe {
                                        HStack {
                                            Picker("方向", selection: optional($step.direction, default: "UP")) { ForEach(["UP", "DOWN", "LEFT", "RIGHT"], id: \.self) { Text($0) } }
                                            Stepper("次数：\(step.count ?? 1)", value: Binding(get: { step.count ?? 1 }, set: { step.count = $0 }), in: 1...5)
                                        }
                                    }
                                    if step.action == .pressKey {
                                        Picker("按键", selection: optional($step.key, default: "Back")) { ForEach(["Back", "Home", "Enter"], id: \.self) { Text($0) } }
                                    }
                                    if [.assertLog, .assertNoLog].contains(step.action) {
                                        HStack {
                                            TextField("Tag（留空为任意）", text: optional($step.tag, default: "", emptyNil: true))
                                            TextField("日志内容", text: optional($step.content, default: ""))
                                        }
                                        Picker("观察起点", selection: optional($step.sinceStep, default: "")) {
                                            Text("选择之前的步骤").tag("")
                                            ForEach(item.steps.prefix(while: { $0.id != step.id })) { prior in Text(prior.name).tag(prior.id) }
                                        }
                                        matchPicker($step.match)
                                    }
                                    HStack {
                                        Text("步骤超时 / 观察时长 ms").font(.caption)
                                        TextField("10000", value: Binding(get: { step.timeoutMs ?? Int(step.timeout * 1000) }, set: { step.timeoutMs = $0 }), format: .number).frame(width: 100)
                                        Spacer(); Text(step.id).font(.caption2).foregroundColor(.secondary)
                                    }
                                }.padding(8)
                            }
                        }
                        Button("添加步骤") { item.steps.append(TestStep()) }
                    }
                }
            }
            HStack {
                Text("每条用例至少包含一个结果断言。").font(.caption).foregroundColor(.secondary)
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        let value = advanced ? try AutomationJSON.decode(AutomationCase.self, from: Data(json.utf8)) : item
                        guard value.id == item.id else { throw AutomationError.configuration("不能修改已有用例编号；请使用复制功能") }
                        try save(value); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 920, height: 700)
        .sheet(isPresented: $showControls) {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择当前页面控件").font(.title2)
                TextField("搜索 ID、文字、描述", text: $query)
                List(controls.filter { !$0.target.isEmpty && (query.isEmpty || $0.summary.localizedCaseInsensitiveContains(query)) }) { element in
                    Button {
                        if let i = item.steps.firstIndex(where: { $0.id == selectedStep }) { item.steps[i].target = element.target }
                        showControls = false
                    } label: { Text(element.summary).frame(maxWidth: .infinity, alignment: .leading).padding(5) }.buttonStyle(.plain)
                }
                HStack { Text("优先使用控件 ID；动态文字可在选中后移除。").font(.caption); Spacer(); Button("关闭") { showControls = false } }
            }.padding(20).frame(width: 780, height: 480)
        }
    }
    private func optional(_ value: Binding<String?>, default fallback: String, emptyNil: Bool = false) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = emptyNil && $0.isEmpty ? nil : $0 })
    }
    private func targetBinding(_ id: String, _ key: WritableKeyPath<TestTarget, String?>) -> Binding<String> {
        Binding(get: { item.steps.first(where: { $0.id == id })?.target?[keyPath: key] ?? "" }, set: { value in
            guard let i = item.steps.firstIndex(where: { $0.id == id }) else { return }
            var target = item.steps[i].target ?? TestTarget(); target[keyPath: key] = value.isEmpty ? nil : value; item.steps[i].target = target
        })
    }
    private func matchPicker(_ value: Binding<String?>) -> some View {
        Picker("匹配方式", selection: optional(value, default: "exact")) {
            Text("完全相等").tag("exact"); Text("包含").tag("contains"); Text("正则表达式").tag("regex")
        }
    }
    private func move(_ id: String, _ offset: Int) {
        guard let i = item.steps.firstIndex(where: { $0.id == id }), item.steps.indices.contains(i + offset) else { return }
        item.steps.swapAt(i, i + offset)
    }
    private func loadControls(for id: String) {
        selectedStep = id; reading = true; error = nil
        Task {
            do { controls = try await readControls(); showControls = true }
            catch { self.error = error.localizedDescription }
            reading = false
        }
    }
}
