import AppKit
import Combine
import UniformTypeIdentifiers
import LogcatCore

@MainActor final class AutomationModel: ObservableObject {
    @Published var tools: AutomationTools { didSet { savePreferences() } }
    @Published var outputRoot: URL { didSet { savePreferences() } }
    @Published var apkURL: URL?
    @Published var apk: APKInfo?
    @Published var inspecting = false
    @Published var suite: TestSuite?
    @Published var suites: [TestSuite] = []
    @Published var selectedCases = Set<String>()
    @Published var name = ""
    @Published var environment = "本地测试"
    @Published var serial = ""
    @Published var clearData = false
    @Published private(set) var busy = false
    @Published var current: AutomationResult?
    @Published var history: [AutomationResult] = []
    @Published var error: String?
    @Published var notice: String?
    @Published var tab = "task"
    private var task: Task<Void, Never>?
    private var token: AutomationCancellation?
    private var apkRequest = UUID()
    private let defaults: UserDefaults
    private let libraryURL: URL
    private var directories: [String: URL] = [:]
    private var roots: [String]
    private var parentRunID: String?
    private var historyRequest = UUID()

    init(defaults: UserDefaults = .standard, support: URL? = nil) {
        self.defaults = defaults
        libraryURL = (support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.songran.LogcatMini"))
            .appendingPathComponent("Automation")
        tools = defaults.data(forKey: "automation.tools").flatMap { try? AutomationJSON.decode(AutomationTools.self, from: $0) } ?? AutomationTools.discover()
        outputRoot = defaults.string(forKey: "automation.outputRoot").map { URL(fileURLWithPath: $0) } ?? libraryURL.appendingPathComponent("Runs")
        roots = defaults.stringArray(forKey: "automation.roots") ?? []
        if !roots.contains(outputRoot.path) { roots.append(outputRoot.path) }
        if let data = try? Data(contentsOf: libraryURL.appendingPathComponent("suites.json")) {
            do { suites = try AutomationJSON.decode([TestSuite].self, from: data) }
            catch { self.error = "用例库读取失败，原文件已保留：\(error.localizedDescription)" }
        }
        refreshHistory()
    }
    private func savePreferences() {
        if let data = try? AutomationJSON.encode(tools) { defaults.set(data, forKey: "automation.tools") }
        defaults.set(outputRoot.path, forKey: "automation.outputRoot")
        if !roots.contains(outputRoot.path) { roots.append(outputRoot.path) }
        defaults.set(roots, forKey: "automation.roots")
    }
    var configProblems: [String] {
        var values: [String] = []
        if apk == nil { values.append("请选择 APK") }
        if serial.isEmpty { values.append("请选择设备") }
        if selectedCases.isEmpty { values.append("请选择至少一条用例") }
        if let suite {
            do { _ = try suite.validated() } catch { values.append(error.localizedDescription) }
            if let apk, suite.app.packageName != apk.packageName { values.append("用例包名与 APK 不一致") }
            if suite.cases.contains(where: { selectedCases.contains($0.id) && $0.startPolicy == "clearAndRestart" }) && !clearData { values.append("所选用例需要清除数据，请勾选确认") }
        } else { values.append("请选择或创建用例集") }
        do {
            let engine = suite?.cases.filter { selectedCases.contains($0.id) }.flatMap { ($0.preconditions ?? []) + $0.steps + ($0.cleanup ?? []) }.contains { [.tap, .inputText, .swipe, .pressKey].contains($0.action) } ?? false
            try tools.validate(needsMaestro: engine)
        } catch { values.append(error.localizedDescription) }
        return values
    }
    func selectAPK() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]; panel.allowsMultipleSelection = false
        panel.title = "选择 Android APK"
        if panel.runModal() == .OK, let url = panel.url { inspect(url) }
    }
    func inspect(_ url: URL) {
        guard !busy else { return }
        let request = UUID(); apkRequest = request; inspecting = true; apk = nil; apkURL = url; error = nil
        Task {
            do {
                let info = try await APKInspector.inspect(url, aapt2: tools.aapt2)
                guard apkRequest == request else { return }
                apk = info; name = "\(info.name) \(info.versionName) 回归"
                if suite?.app.packageName != info.packageName {
                    useSuite(suites.first(where: { $0.app.packageName == info.packageName }) ?? TestSuite(packageName: info.packageName))
                }
            } catch { if apkRequest == request { self.error = error.localizedDescription } }
            if apkRequest == request { inspecting = false }
        }
    }
    func useSuite(_ value: TestSuite) {
        guard !busy else { return }; suite = value; selectedCases = Set(value.cases.map(\.id)); parentRunID = nil
    }
    func saveSuite(_ value: TestSuite) {
        do {
            _ = try value.validated()
            var saved = value
            if let index = suites.firstIndex(where: { $0.suiteId == saved.suiteId }) {
                saved.revision = max(saved.revision, suites[index].revision) + 1; suites[index] = saved
            } else { suites.append(saved) }
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            try AutomationJSON.encode(suites).write(to: libraryURL.appendingPathComponent("suites.json"), options: .atomic)
            suite = saved; selectedCases.formIntersection(Set(saved.cases.map(\.id)))
            notice = "用例集已保存（修订 \(saved.revision)）"
        } catch { self.error = error.localizedDescription }
    }
    func importSuite() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.title = "导入 Logcat Mini 用例集"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url); guard data.count <= 2_000_000 else { throw AutomationError.configuration("用例文件不得超过 2 MB") }
            var value = try AutomationJSON.decode(TestSuite.self, from: data); _ = try value.validated()
            if suites.contains(where: { $0.suiteId == value.suiteId }) {
                value.suiteId = UUID().uuidString; value.name += "（导入副本）"
            }
            useSuite(value); saveSuite(value); tab = "cases"
        } catch { self.error = error.localizedDescription }
    }
    func exportSuite() {
        guard let suite else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "test-suite.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try AutomationJSON.encode(suite).write(to: url, options: .atomic); notice = "用例已导出" }
        catch { self.error = error.localizedDescription }
    }
    func chooseOutput() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.title = "选择自动测试结果目录"
        if panel.runModal() == .OK, let url = panel.url { outputRoot = url; refreshHistory() }
    }
    func chooseTool(_ key: WritableKeyPath<AutomationTools, String>, directory: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
        if panel.runModal() == .OK, let url = panel.url { tools[keyPath: key] = url.path }
    }
    func start(deviceName: String) {
        guard !busy, configProblems.isEmpty, let apk, let apkURL, var selected = suite else { return }
        selected.cases = selected.cases.filter { selectedCases.contains($0.id) }
        var request = AutomationRequest(apkURL: apkURL, apk: apk, suite: selected, tools: tools, serial: serial,
            deviceName: deviceName, environment: environment, name: name, outputRoot: outputRoot, clearData: clearData)
        request.parentRunID = parentRunID
        let root = outputRoot
        let cancellation = AutomationCancellation(); token = cancellation
        let runner = AutomationRunner(cancellation: cancellation)
        busy = true; error = nil; notice = nil; current = nil; tab = "results"
        task = Task {
            do {
                let value = try await runner.run(request) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.busy, self.token === cancellation, self.current?.endedAt == nil else { return }
                        if let current = self.current, current.id == value.id, current.duration > value.duration { return }
                        self.current = value; self.directories[value.id] = root.appendingPathComponent(value.id)
                    }
                }
                current = value; directories[value.id] = root.appendingPathComponent(value.id)
            } catch {
                self.error = "测试未完成：\(error.localizedDescription)"
                if var value = current, value.endedAt == nil {
                    value.recoverInterrupted(); value.reason = error.localizedDescription; current = value
                    try? AutomationStorage.save(value, directory: root.appendingPathComponent(value.id))
                }
            }
            busy = false; token = nil; task = nil; refreshHistory()
        }
    }
    func stop() { token?.cancel() }
    func finishBeforeQuit() async { stop(); await task?.value }
    func directory(for result: AutomationResult) -> URL? { directories[result.id] }
    func refreshHistory() {
        let request = UUID(); historyRequest = request
        let locations = roots, active = busy ? current?.id : nil
        // A moved/network/TCC-protected result folder must never block window creation or the UI thread.
        Task {
            let scanned = await Task.detached(priority: .utility) {
                var loaded: [(AutomationResult, URL)] = []
                var failures: [String] = []
                for root in locations {
                    guard let children = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
                    for child in children where child.lastPathComponent != active {
                        do { loaded.append((try AutomationStorage.load(child, recover: true), child)) }
                        catch {
                            if FileManager.default.fileExists(atPath: child.appendingPathComponent("result.json").path) { failures.append(child.lastPathComponent) }
                        }
                    }
                }
                return (loaded, failures)
            }.value
            guard historyRequest == request else { return }
            for (result, directory) in scanned.0 { directories[result.id] = directory }
            history = scanned.0.map(\.0).sorted { $0.startedAt > $1.startedAt }
            if !scanned.1.isEmpty { error = "部分运行记录无法读取：\(scanned.1.joined(separator: ", "))" }
        }
    }
    func show(_ result: AutomationResult) { guard !busy else { return }; current = result; tab = "results" }
    func rerunFailures(_ value: AutomationResult) {
        guard !busy, let directory = directory(for: value) else { return }
        do {
            let original = try AutomationJSON.decode(TestSuite.self, from: Data(contentsOf: directory.appendingPathComponent("input/suite.snapshot.json")))
            let snapshot = directory.appendingPathComponent("input/app.apk")
            guard FileManager.default.fileExists(atPath: snapshot.path) else { throw AutomationError.configuration("APK 快照不存在，请重新选择并核对 SHA-256") }
            useSuite(original)
            selectedCases = Set(value.cases.filter { $0.status == .failed || $0.status == .blocked }.map(\.id))
            apkURL = snapshot; apk = value.apk; serial = value.serial; environment = value.environment
            name = value.name + " 复测"; clearData = false; parentRunID = value.id; tab = "task"
        } catch { self.error = error.localizedDescription }
    }
    func exportResult(_ value: AutomationResult) {
        guard let source = directory(for: value) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.title = "选择报告导出位置"; panel.message = "导出 Markdown、日志与截图（不包含 APK）。分享前请检查附件中的业务信息。"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let target = parent.appendingPathComponent("LogcatMini-" + value.id + "-" + String(UUID().uuidString.prefix(4)))
        do {
            try AutomationStorage.export(value, from: source, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target.appendingPathComponent("report.md")])
            notice = "MD 报告与附件已导出"
        } catch { self.error = error.localizedDescription }
    }
    func openArtifact(_ path: String, for result: AutomationResult) {
        guard let dir = directory(for: result), AutomationReport.artifactExists(path, in: dir) else { error = "附件不存在或路径无效"; return }
        NSWorkspace.shared.open(dir.appendingPathComponent(path))
    }
    func loadFixtureSuite() {
        let pkg = "com.songran.logcatmini.automationfixture"
        func target(_ id: String) -> TestTarget { TestTarget(id: pkg + ":id/" + id) }
        let launch = AutomationCase(id: "START-001", name: "Release 包启动进入首页", steps: [
            TestStep(id: "home", action: .assertText, target: target("home_title"), expected: "自动化测试首页"),
            TestStep(id: "screen", action: .screenshot)
        ])
        var settings = AutomationCase(id: "SETTINGS-001", name: "语言设置在重启后保留", steps: [
            TestStep(id: "settings", action: .tap, target: target("settings_button")),
            TestStep(id: "english", action: .tap, target: target("english_button")),
            TestStep(id: "restart", action: .restartApp, timeoutMs: 30000),
            TestStep(id: "settings-again", action: .tap, target: target("settings_button")),
            TestStep(id: "persisted", action: .assertText, target: target("language_value"), expected: "English"),
            TestStep(id: "screen", action: .screenshot)
        ])
        settings.cleanup = [TestStep(id: "restore", action: .tap, target: target("chinese_button"))]
        var savedLog = TestStep(id: "saved-log", action: .assertLog)
        savedLog.tag = "QA.Fixture"; savedLog.content = "event=name_saved empty=false"; savedLog.sinceStep = "save"
        var noRestart = TestStep(id: "no-restart", action: .assertNoLog, timeoutMs: 1000)
        noRestart.tag = "QA.Fixture"; noRestart.content = "event=home_shown"; noRestart.sinceStep = "input"
        let input = AutomationCase(id: "FORM-001", name: "输入并保存测试名称", steps: [
            TestStep(id: "input", action: .inputText, target: target("name_input"), text: "LogcatMini"),
            TestStep(id: "save", action: .tap, target: target("save_button")),
            TestStep(id: "check", action: .assertText, target: target("result_text"), expected: "已保存：LogcatMini"),
            savedLog, noRestart,
            TestStep(id: "screen", action: .screenshot)
        ])
        let failure = AutomationCase(id: "EXPECTED-FAIL", name: "故意失败以验证报告", steps: [
            TestStep(id: "wrong-title", action: .assertText, target: target("home_title"), expected: "这是故意设置的错误预期", timeoutMs: 2000)
        ])
        let value = TestSuite(packageName: pkg, name: "独立 Release 演示（含一个故意失败）", cases: [launch, settings, input, failure])
        useSuite(value); saveSuite(value)
    }
}
