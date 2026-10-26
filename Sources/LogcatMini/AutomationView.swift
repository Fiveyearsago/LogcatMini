import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LogcatCore

struct MainWorkspaceView: View {
    @ObservedObject var model: LogViewModel
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject var replay: RequestReplayStore
    @ObservedObject var sDecrypt: LogSDecryptionStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("工作区", selection: $model.automationVisible) {
                    Text("日志").tag(false); Text("自动测试").tag(true)
                }.pickerStyle(.segmented).frame(width: 210)
                Spacer()
                AutomationRunningBadge(automation: model.automation) { model.automationVisible = true; model.automation.tab = "results" }
            }.padding(.horizontal, 18).padding(.vertical, 9)
            Divider()
            if model.automationVisible {
                AutomationView(automation: model.automation, logs: model)
            } else { ContentView(model: model, appearance: appearance, replay: replay, sDecrypt: sDecrypt) }
        }
    }
}

private struct AutomationRunningBadge: View {
    @ObservedObject var automation: AutomationModel
    let show: () -> Void
    var body: some View {
        if automation.busy {
            Button(action: show) {
                Label("测试进行中 · \(automation.current?.deviceName ?? automation.serial)", systemImage: "play.circle.fill")
            }.buttonStyle(.borderless)
        }
    }
}

struct AutomationView: View {
    @ObservedObject var automation: AutomationModel
    @ObservedObject var logs: LogViewModel
    @State private var editing: AutomationCase?
    @State private var historyQuery = ""
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label("自动测试", systemImage: "checkmark.seal").font(.title2.bold()).padding(.bottom, 16)
                nav("测试任务", id: "task", icon: "play.rectangle")
                nav("用例库", id: "cases", icon: "list.bullet.rectangle")
                nav("运行结果", id: "results", icon: "checklist")
                nav("运行记录", id: "history", icon: "clock")
                Spacer()
                nav("测试设置", id: "settings", icon: "gearshape")
                Text("本机执行 · AI 未启用").font(.caption).foregroundColor(.secondary)
            }.padding(18).frame(width: 190).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let error = automation.error { banner(error, error: true) { automation.error = nil } }
                if let notice = automation.notice { banner(notice, error: false) { automation.notice = nil } }
                switch automation.tab {
                case "cases": casesPage
                case "results":
                    if let value = automation.current { AutomationResultsView(automation: automation, result: value) }
                    else { empty("还没有测试结果", detail: "创建任务后，这里会显示安装、步骤与结果证据。") }
                case "history": historyPage
                case "settings": settingsPage
                default: taskPage
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if automation.serial.isEmpty { automation.serial = logs.selectedSerial }
        }
        .sheet(item: $editing) { item in
            AutomationCaseEditor(item: item, readControls: {
                guard !automation.serial.isEmpty, !automation.busy else { throw AutomationError.configuration("请先选择设备，并停止正在执行的测试") }
                return try await AutomationDevice(tools: automation.tools, serial: automation.serial, cancellation: AutomationCancellation()).hierarchy()
            }) { saved in
                guard var suite = automation.suite else { throw AutomationError.configuration("请先创建用例集") }
                if let index = suite.cases.firstIndex(where: { $0.id == saved.id }) { suite.cases[index] = saved } else { suite.cases.append(saved) }
                _ = try suite.validated()
                automation.suite = suite; automation.selectedCases.insert(saved.id); automation.saveSuite(suite)
            }
        }
    }
    private func nav(_ title: String, id: String, icon: String) -> some View {
        Button { automation.tab = id } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(RoundedRectangle(cornerRadius: 7).fill(automation.tab == id ? Color.accentColor.opacity(0.15) : .clear))
        }.buttonStyle(.plain)
    }
    private func banner(_ text: String, error: Bool, dismiss: @escaping () -> Void) -> some View {
        HStack { Image(systemName: error ? "exclamationmark.triangle" : "checkmark.circle"); Text(text).textSelection(.enabled); Spacer(); Button("关闭", action: dismiss) }
            .padding(12).foregroundColor(error ? .orange : .accentColor).background(Color.secondary.opacity(0.07))
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) { Text(title).font(.title2); Text(detail).foregroundColor(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var taskPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("新建测试任务").font(.title.bold())
                Text("选择 APK 与设备，重复执行固定用例，保存结果和证据。").foregroundColor(.secondary)
                // Keep the heading outside GroupBox: titled groups crash some macOS accessibility clients.
                Text("安装包").font(.headline)
                GroupBox {
                    HStack(alignment: .top) {
                        Image(systemName: "shippingbox").font(.system(size: 32)).padding(8)
                        VStack(alignment: .leading, spacing: 6) {
                            if automation.inspecting { ProgressView("正在读取 APK…") }
                            Text(automation.apkURL?.lastPathComponent ?? "拖入 APK 或选择文件").font(.headline)
                            if let apk = automation.apk {
                                Text("\(apk.name) · \(apk.packageName)").textSelection(.enabled)
                                Text("\(apk.versionName) (\(apk.versionCode)) · 最低 API \(apk.minimumSDK) · \(apk.debuggable ? "可调试" : "不可调试 / Release 可用")").font(.caption)
                                Text("SHA-256: \(apk.sha256)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
                            }
                        }
                        Spacer(); Button("选择 APK…", action: automation.selectAPK)
                    }.padding(10)
                }.onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                    guard !automation.busy, let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in automation.inspect(url) } } }
                    return true
                }
                Text("执行配置").font(.headline)
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("设备").frame(width: 80, alignment: .leading)
                            Picker("设备", selection: $automation.serial) {
                                Text("请选择设备").tag("")
                                ForEach(logs.devices) { device in Text("\(device.name) · \(device.id)\(device.ready ? "" : "（未就绪）")").tag(device.id) }
                            }.labelsHidden()
                            Button("刷新") { Task { await logs.refreshDevices() } }
                        }
                        HStack { Text("任务名称").frame(width: 80, alignment: .leading); TextField("测试任务名称", text: $automation.name) }
                        HStack { Text("环境说明").frame(width: 80, alignment: .leading); TextField("由操作者指定，不自动切换服务端", text: $automation.environment) }
                        HStack {
                            Text("用例集").frame(width: 80, alignment: .leading)
                            Text(automation.suite?.name ?? "未选择"); Spacer()
                            Button("配置用例") { automation.tab = "cases" }
                            Button("导入…", action: automation.importSuite)
                        }
                        if let suite = automation.suite {
                            ForEach(suite.cases) { item in
                                Toggle("\(item.id) · \(item.name)", isOn: Binding(get: { automation.selectedCases.contains(item.id) }, set: {
                                    if $0 { automation.selectedCases.insert(item.id) } else { automation.selectedCases.remove(item.id) }
                                })).toggleStyle(.checkbox)
                            }
                        }
                        Divider()
                        Toggle("清除目标应用数据（将清除登录状态和本地数据）", isOn: $automation.clearData).toggleStyle(.checkbox)
                        Text("默认保留数据覆盖安装；签名冲突或版本降级会停止，不自动卸载旧 App。").font(.caption).foregroundColor(.secondary)
                        HStack {
                            Text("结果目录"); Text(automation.outputRoot.path).font(.caption).textSelection(.enabled); Spacer()
                            Button("更换…", action: automation.chooseOutput)
                        }
                    }.padding(12)
                }
                HStack {
                    if automation.configProblems.isEmpty {
                        Label("配置已就绪 · 开始后会安装并操作所选设备", systemImage: "checkmark.circle").foregroundColor(.green)
                    } else {
                        Text(automation.configProblems.joined(separator: "；")).font(.callout).foregroundColor(.orange)
                    }
                    Spacer()
                    Button("开始测试") {
                        if logs.media.recording || logs.media.saving { automation.error = "请先结束手动录屏，再开始测试"; return }
                        automation.start(deviceName: logs.devices.first(where: { $0.id == automation.serial })?.name ?? automation.serial)
                    }.buttonStyle(.borderedProminent).disabled(!automation.configProblems.isEmpty || automation.inspecting || !logs.devices.contains(where: { $0.id == automation.serial && $0.ready }))
                }
            }.padding(24).disabled(automation.busy)
        }
    }
    private var casesPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("用例库").font(.title.bold()); Spacer()
                Button("导入…", action: automation.importSuite)
                Button("导出…", action: automation.exportSuite).disabled(automation.suite == nil)
                Button("演示用例", action: automation.loadFixtureSuite)
            }
            HStack {
                Menu("选择已保存用例集") { ForEach(automation.suites, id: \.suiteId) { suite in Button("\(suite.name) · \(suite.app.packageName)") { automation.useSuite(suite) } } }
                Button("基础启动模板") { if let apk = automation.apk { automation.useSuite(TestSuite(packageName: apk.packageName)) } }.disabled(automation.apk == nil)
                Spacer()
                Button("新增用例") { editing = AutomationCase() }.disabled(automation.suite == nil)
            }
            if let suite = automation.suite {
                TextField("用例集名称", text: Binding(get: { automation.suite?.name ?? "" }, set: { automation.suite?.name = $0 })).font(.headline)
                Text("\(suite.app.packageName) · 修订 \(suite.revision)").font(.caption).foregroundColor(.secondary)
                List {
                    ForEach(suite.cases) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.name).font(.headline)
                                Text("\(item.id) · \(item.priority) · \(item.steps.count) 步").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("编辑") { editing = item }
                            Button("复制") { var copy = item; copy.id = "COPY-" + String(UUID().uuidString.prefix(8)); copy.name += " 副本"; editing = copy }
                            Button("↑") { moveCase(item.id, offset: -1) }.disabled(suite.cases.first?.id == item.id)
                            Button("↓") { moveCase(item.id, offset: 1) }.disabled(suite.cases.last?.id == item.id)
                            Button("移除") { automation.suite?.cases.removeAll { $0.id == item.id }; automation.selectedCases.remove(item.id) }
                        }.padding(.vertical, 6)
                    }
                }
                HStack {
                    Text("支持 ID、文字与描述定位；当前输入动作限英文、数字和 ASCII 符号。").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("保存用例集") { if let suite = automation.suite { automation.saveSuite(suite) } }
                }
            } else { empty("先选择 APK 或导入用例集", detail: "用例按应用包名绑定。") }
        }.padding(24).disabled(automation.busy)
    }
    private func moveCase(_ id: String, offset: Int) {
        guard var suite = automation.suite, let i = suite.cases.firstIndex(where: { $0.id == id }), suite.cases.indices.contains(i + offset) else { return }
        suite.cases.swapAt(i, i + offset); automation.suite = suite
    }
    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("运行记录").font(.title.bold()); Spacer(); Button("刷新", action: automation.refreshHistory) }
            TextField("搜索应用、版本、设备或结论", text: $historyQuery)
            List {
                ForEach(automation.history.filter { historyQuery.isEmpty || "\($0.apk.name) \($0.apk.versionName) \($0.deviceName) \($0.verdict)".localizedCaseInsensitiveContains(historyQuery) }) { value in
                    Button { automation.show(value) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(value.name).font(.headline)
                                Text("\(value.deviceName) · \(value.startedAt.formatted(date: .numeric, time: .standard))").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer(); StatusPill(status: value.count(.failed) > 0 ? .failed : value.isComplete ? .passed : .blocked)
                            Text(value.verdict)
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.padding(24).disabled(automation.busy)
    }
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("自动测试设置").font(.title.bold())
                Text("固定用例在本机运行。基础启动检查只需 ADB 与 aapt2；点击、输入和滑动还需 Maestro 与 Java。").foregroundColor(.secondary)
                toolRow("ADB", key: \.adb)
                toolRow("aapt2", key: \.aapt2)
                toolRow("Maestro", key: \.maestro)
                toolRow("Java Home", key: \.javaHome, directory: true)
                HStack { Button("重新检测") { automation.tools = AutomationTools.discover(adb: logs.adbPath) }; Link("Maestro 安装说明", destination: URL(string: "https://docs.maestro.dev/maestro-cli/how-to-install-maestro-cli")!) }
                Divider()
                Text("测试结果保存位置").font(.headline)
                Text(automation.outputRoot.path).textSelection(.enabled)
                Button("更换结果目录…", action: automation.chooseOutput)
                Text("目录和执行组件配置会跨启动保存。结果包含日志及关键截图；此版本暂不录屏，也不连接 AI。").font(.caption).foregroundColor(.secondary)
            }.padding(24)
        }.disabled(automation.busy)
    }
    private func toolRow(_ title: String, key: WritableKeyPath<AutomationTools, String>, directory: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack {
                TextField(title, text: Binding(get: { automation.tools[keyPath: key] }, set: { automation.tools[keyPath: key] = $0 }))
                Button("选择…") { automation.chooseTool(key, directory: directory) }
            }
        }
    }
}

struct StatusPill: View {
    let status: TestStatus
    private var color: Color {
        switch status { case .passed: return .green; case .failed: return .red; case .blocked, .cancelled: return .orange; case .running: return .blue; default: return .secondary }
    }
    var body: some View { Text(status.title).font(.caption.bold()).foregroundColor(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.1)).cornerRadius(5) }
}
