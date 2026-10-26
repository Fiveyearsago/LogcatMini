import Foundation

public struct AutomationRequest {
    public var apkURL: URL
    public var apk: APKInfo
    public var suite: TestSuite
    public var tools: AutomationTools
    public var serial: String
    public var deviceName: String
    public var environment: String
    public var name: String
    public var outputRoot: URL
    public var clearData: Bool
    public var parentRunID: String?
    public init(apkURL: URL, apk: APKInfo, suite: TestSuite, tools: AutomationTools, serial: String,
                deviceName: String, environment: String, name: String, outputRoot: URL, clearData: Bool = false) {
        self.apkURL = apkURL; self.apk = apk; self.suite = suite; self.tools = tools; self.serial = serial
        self.deviceName = deviceName; self.environment = environment; self.name = name; self.outputRoot = outputRoot; self.clearData = clearData
    }
}

public actor AutomationRunner {
    public nonisolated let cancellation: AutomationCancellation
    private var result: AutomationResult!
    private var directory: URL!
    private var device: AutomationDevice!
    private var capture: AutomationLogCapture?
    private var progress: (@Sendable (AutomationResult) -> Void)?
    private var runStart = 0.0
    private var running = false
    public init(cancellation: AutomationCancellation = AutomationCancellation()) { self.cancellation = cancellation }

    public func run(_ request: AutomationRequest, onProgress: @escaping @Sendable (AutomationResult) -> Void) async throws -> AutomationResult {
        guard !running else { throw AutomationError.configuration("执行器已有任务") }
        running = true
        defer { running = false; capture?.stop(); capture = nil; progress = nil }
        let suite = try request.suite.validated()
        guard suite.app.packageName == request.apk.packageName else { throw AutomationError.configuration("用例包名与 APK 不匹配") }
        guard !suite.cases.contains(where: { $0.startPolicy == "clearAndRestart" }) || request.clearData else { throw AutomationError.configuration("用例需要清除数据，请显式勾选清除数据选项") }
        result = AutomationResult(name: request.name, apk: request.apk, apkFileName: request.apkURL.lastPathComponent,
            serial: request.serial, deviceName: request.deviceName, environment: request.environment, suite: suite)
        result.clearData = request.clearData; result.parentRunID = request.parentRunID
        directory = request.outputRoot.appendingPathComponent(result.id)
        device = AutomationDevice(tools: request.tools, serial: request.serial, cancellation: cancellation)
        progress = onProgress; runStart = ProcessInfo.processInfo.systemUptime
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("input"), withIntermediateDirectories: true)
        try checkpoint()
        var anyCaseStarted = false
        do {
            try cancellation.check()
            let uiActions: Set<TestAction> = [.tap, .inputText, .swipe, .pressKey]
            let needsEngine = suite.cases.flatMap { ($0.preconditions ?? []) + $0.steps + ($0.cleanup ?? []) }.contains { uiActions.contains($0.action) }
            try request.tools.validate(needsMaestro: needsEngine)
            _ = try request.outputRoot.checkResourceIsReachable()
            let disk = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
            guard (disk[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0 > 256 * 1024 * 1024 else { throw AutomationError.infrastructure("可用磁盘空间不足 256 MiB") }
            try await device.ensureOnline()
            let user = try await device.adb(["shell", "am", "get-current-user"])
            guard user == "0" else { throw AutomationError.infrastructure("首版只支持 Android 主用户，请切换后重试") }
            let sdk = try await device.adb(["shell", "getprop", "ro.build.version.sdk"])
            guard Int(sdk) ?? 0 >= request.apk.minimumSDK else { throw AutomationError.configuration("设备 Android API \(sdk) 低于 APK 要求 \(request.apk.minimumSDK)") }
            let release = try await device.adb(["shell", "getprop", "ro.build.version.release"])
            let model = try await device.adb(["shell", "getprop", "ro.product.model"])
            result.deviceDetails = "\(model) · Android \(release) / API \(sdk)"
            result.engineVersion = "ADB / Android UI Automator"
            if needsEngine {
                let version = try await AutomationProcess.checked(request.tools.maestro, ["--version"], timeout: 30,
                    cancellation: cancellation, environment: request.tools.engineEnvironment)
                result.engineVersion += " + Maestro \(version)"
            }
            let snapshot = directory.appendingPathComponent("input/app.apk")
            try FileManager.default.copyItem(at: request.apkURL, to: snapshot)
            let actual = try await APKInspector.inspect(snapshot, aapt2: request.tools.aapt2)
            guard actual == request.apk else { throw AutomationError.configuration("APK 在选择后发生变化，请重新选择并核对版本") }
            try AutomationJSON.encode(request.suite).write(to: directory.appendingPathComponent("input/suite.snapshot.json"), options: .atomic)
            try AutomationJSON.encode(suite).write(to: directory.appendingPathComponent("input/suite.resolved.json"), options: .atomic)
            result.phase = "安装 APK"; try checkpoint()
            let installPath = directory.appendingPathComponent("evidence/install.log")
            result.artifacts.append("evidence/install.log")
            let installation = try await device.adb(["install", "--no-incremental", "-r", snapshot.path], timeout: 120, output: installPath)
            guard installation.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Success" }) else {
                throw AutomationError.infrastructure("安装未确认成功：\(installation)")
            }
            let installed = try await device.adb(["shell", "dumpsys", "package", request.apk.packageName])
            guard installed.range(of: "versionCode=" + NSRegularExpression.escapedPattern(for: request.apk.versionCode) + "\\s", options: .regularExpression) != nil else {
                throw AutomationError.infrastructure("安装后 versionCode 与目标 APK 不一致")
            }
            result.installedVersion = "versionCode \(request.apk.versionCode) · 已核对"
            let packages = AndroidPackage.parse(try await device.adb(["shell", "cmd", "package", "list", "packages", "-U"]))
            guard let target = packages.first(where: { $0.id == request.apk.packageName }), packages.filter({ $0.uid == target.uid }).count == 1 else {
                throw AutomationError.infrastructure("无法解析独立应用 UID，不能可靠关联测试日志")
            }
            if request.clearData {
                let output = try await device.adb(["shell", "pm", "clear", request.apk.packageName], timeout: 30)
                guard output == "Success" else { throw AutomationError.infrastructure("清除应用数据失败：\(output)") }
            }
            capture = try AutomationLogCapture(directory: directory.appendingPathComponent("evidence"))
            try capture?.start(path: request.tools.adb, serial: request.serial, uid: target.uid, package: request.apk.packageName)
            result.artifacts += ["evidence/app.log", "evidence/system-events.log"]
            result.warnings.append("当前版本未录屏；系统异常仅按目标包或独立 UID 归因，不包含所有厂商私有诊断。")
            try await Task.sleep(nanoseconds: 300_000_000)
            for i in suite.cases.indices {
                try cancellation.check()
                guard ProcessInfo.processInfo.systemUptime - runStart < 1800 else { throw AutomationError.infrastructure("任务达到 30 分钟上限") }
                try await device.ensureOnline(); try capture?.check()
                anyCaseStarted = true
                try await executeCase(suite.cases[i], index: i, package: request.apk.packageName)
            }
            result.reason = "所选用例执行完毕"
        } catch {
            result.reason = error.localizedDescription
            if !anyCaseStarted {
                for i in result.cases.indices {
                    result.cases[i].status = (error as? AutomationError)?.status == .cancelled ? .notRun : .blocked
                    result.cases[i].reason = error.localizedDescription
                }
            }
        }
        capture?.stop()
        for i in result.cases.indices {
            if result.cases[i].status == .pending { result.cases[i].status = .notRun; result.cases[i].reason = result.reason }
            if result.cases[i].status == .running {
                result.cases[i].status = cancellation.isCancelled ? .cancelled : .blocked; result.cases[i].reason = result.reason
            }
            for j in result.cases[i].steps.indices {
                if result.cases[i].steps[j].status == .pending { result.cases[i].steps[j].status = .notRun }
                if result.cases[i].steps[j].status == .running {
                    result.cases[i].steps[j].status = cancellation.isCancelled ? .cancelled : .blocked
                    result.cases[i].steps[j].actual = result.reason
                }
            }
        }
        result.endedAt = Date(); result.duration = ProcessInfo.processInfo.systemUptime - runStart; result.phase = "已结束"
        try checkpoint()
        return result
    }

    private func checkpoint() throws {
        result.duration = ProcessInfo.processInfo.systemUptime - runStart
        try AutomationStorage.save(result, directory: directory)
        progress?(result)
    }

    private func executeCase(_ test: AutomationCase, index: Int, package: String) async throws {
        let began = ProcessInfo.processInfo.systemUptime
        device.deadline = min(runStart + 1800, began + Double(test.timeoutMs) / 1000)
        result.phase = "执行 \(index + 1) / \(result.cases.count)：\(test.name)"
        result.cases[index].status = .running; result.cases[index].startedAt = Date()
        try checkpoint()
        var cursors: [String: UInt64] = [:]
        let faultStart = capture?.faultCount ?? 0
        var primaryError: Error?
        do {
            if test.startPolicy == "clearAndRestart" {
                guard try await device.adb(["shell", "pm", "clear", package], timeout: 30) == "Success" else { throw AutomationError.infrastructure("清除应用数据未确认成功") }
            }
            _ = try await device.launch(package: package, restart: true)
            for (phase, steps) in [("preconditions", test.preconditions ?? []), ("steps", test.steps)] {
                for step in steps { try await executeStep(step, phase: phase, caseIndex: index, package: package, cursors: &cursors) }
            }
            try capture?.check()
            if let fault = capture?.faults(since: faultStart).first { throw AutomationError.assertion("目标应用致命事件：\(fault)") }
        } catch { primaryError = error }
        let status = (primaryError as? AutomationError)?.status ?? (primaryError == nil ? .passed : .blocked)
        var finalStatus: TestStatus = result.cases[index].steps.contains(where: { $0.status == .failed }) ? .failed : status
        result.cases[index].reason = primaryError?.localizedDescription ?? ""
        // Only recover from an ordinary assertion failure. No more device writes after cancellation or infrastructure failure.
        if status == .passed || status == .failed {
            do {
                for step in test.cleanup ?? [] { try await executeStep(step, phase: "cleanup", caseIndex: index, package: package, cursors: &cursors) }
                try cancellation.check(); try capture?.check()
                if status == .passed, let fault = capture?.faults(since: faultStart).first {
                    finalStatus = .failed
                    result.cases[index].reason = "目标应用致命事件：\(fault)"
                }
            } catch {
                if status == .passed { finalStatus = cancellation.isCancelled ? .cancelled : .blocked }
                result.cases[index].reason += "\n收尾未完成：\(error.localizedDescription)"
                primaryError = AutomationError.infrastructure("用例收尾未完成，停止后续用例：\(error.localizedDescription)")
            }
        }
        result.cases[index].status = finalStatus
        result.cases[index].duration = ProcessInfo.processInfo.systemUptime - began
        for j in result.cases[index].steps.indices where result.cases[index].steps[j].status == .pending { result.cases[index].steps[j].status = .notRun }
        try checkpoint()
        if let primaryError, (primaryError as? AutomationError)?.status != .failed { throw primaryError }
    }

    private func executeStep(_ step: TestStep, phase: String, caseIndex: Int, package: String, cursors: inout [String: UInt64]) async throws {
        guard let j = result.cases[caseIndex].steps.firstIndex(where: { $0.id == step.id }) else { throw AutomationError.configuration("步骤索引丢失") }
        try cancellation.check(); try device.checkDeadline(); try capture?.check()
        let began = ProcessInfo.processInfo.systemUptime
        let cursor = try capture?.cursor() ?? 0; cursors[step.id] = cursor
        result.cases[caseIndex].steps[j].status = .running; result.cases[caseIndex].steps[j].startedAt = Date()
        try checkpoint()
        let relative = "evidence/cases/\(result.cases[caseIndex].id)/\(step.id)"
        let stepDirectory = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: stepDirectory, withIntermediateDirectories: true)
        do {
            var actual = ""
            switch step.action {
            case .launchApp, .restartApp: actual = try await device.launch(package: package, restart: step.action == .restartApp)
            case .tap, .inputText:
                _ = try await device.checkUI(step)
                actual = try await device.executeUI(step, package: package, directory: stepDirectory)
            case .swipe, .pressKey: actual = try await device.executeUI(step, package: package, directory: stepDirectory)
            case .assertForeground:
                var configured = step; configured.expected = package; actual = try await device.checkUI(configured)
            case .assertVisible, .assertNotVisible, .assertText, .waitVisible: actual = try await device.checkUI(step)
            case .assertLog, .assertNoLog:
                guard let start = step.sinceStep, let offset = cursors[start], let capture else { throw AutomationError.infrastructure("日志观察窗口不可用") }
                let deadline = ProcessInfo.processInfo.systemUptime + step.timeout
                repeat {
                    try cancellation.check(); try device.checkDeadline()
                    let matches = try capture.lines(since: offset).filter { line in
                        guard let record = LogParser.parse(line, id: 0), step.tag == nil || record.tag == step.tag else { return false }
                        return AutomationDevice.textMatches(record.message, expected: step.content ?? "", mode: step.match ?? "contains")
                    }
                    if !matches.isEmpty {
                        if step.action == .assertNoLog { throw AutomationError.assertion("发现不应出现的日志：\(matches[0])") }
                        actual = String(matches[0].prefix(4000)); break
                    }
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        if step.action == .assertLog { throw AutomationError.assertion("观察窗口内未出现预期日志") }
                        actual = "完整观察 \(Int(step.timeout)) 秒，未发现匹配日志"; break
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                } while true
            case .screenshot:
                try await device.screenshot(to: stepDirectory.appendingPathComponent("screenshot.png"))
                result.cases[caseIndex].steps[j].screenshot = relative + "/screenshot.png"; actual = "截图已保存"
            }
            try device.checkDeadline(); try capture?.check()
            result.cases[caseIndex].steps[j].actual = actual; result.cases[caseIndex].steps[j].status = .passed
        } catch {
            var status = (error as? AutomationError)?.status ?? .blocked
            if phase == "preconditions" && status == .failed { status = .blocked }
            result.cases[caseIndex].steps[j].status = status; result.cases[caseIndex].steps[j].actual = error.localizedDescription
            if status == .failed && !cancellation.isCancelled {
                do {
                    try await device.screenshot(to: stepDirectory.appendingPathComponent("failure.png"))
                    result.cases[caseIndex].steps[j].screenshot = relative + "/failure.png"
                } catch { result.warnings.append("\(step.name) 失败截图未保存：\(error.localizedDescription)") }
            }
            result.cases[caseIndex].steps[j].duration = ProcessInfo.processInfo.systemUptime - began
            do { try saveStepLogs(caseIndex: caseIndex, stepIndex: j, cursor: cursor, relative: relative) }
            catch { result.warnings.append("\(step.name) 日志片段保存失败：\(error.localizedDescription)") }
            try checkpoint()
            if status == .blocked { throw AutomationError.infrastructure(error.localizedDescription) }
            throw error
        }
        result.cases[caseIndex].steps[j].duration = ProcessInfo.processInfo.systemUptime - began
        try saveStepLogs(caseIndex: caseIndex, stepIndex: j, cursor: cursor, relative: relative)
        try checkpoint()
    }
    private func saveStepLogs(caseIndex: Int, stepIndex: Int, cursor: UInt64, relative: String) throws {
        let lines = try capture?.lines(since: cursor) ?? []
        let path = relative + "/app.log"
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        result.cases[caseIndex].steps[stepIndex].log = path
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative + "/engine.log").path) { result.artifacts.append(relative + "/engine.log") }
    }
}
