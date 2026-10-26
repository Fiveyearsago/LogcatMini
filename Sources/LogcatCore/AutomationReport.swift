import Foundation

public enum AutomationReport {
    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "#", with: "\\#").replacingOccurrences(of: String(UnicodeScalar(96)), with: "\\" + String(UnicodeScalar(96)))
    }
    public static func render(_ result: AutomationResult, directory: URL) -> String {
        let e = escape
        let formatter = ISO8601DateFormatter(); formatter.timeZone = .current
        let n = result.cases.count
        let passed = result.count(.passed), failed = result.count(.failed)
        let completion = n > 0 ? String(format: "%.1f%%", Double(passed + failed) * 100 / Double(n)) : "不适用"
        let ratio = n > 0 ? String(format: "%.1f%%", Double(passed) * 100 / Double(n)) : "不适用"
        var lines = [
            "# \(e(result.apk.name)) 自动化测试报告", "",
            "**\(e(result.verdict))**", "",
            "本结论只覆盖本次 APK、设备、环境和所选用例，不代表整个应用没有缺陷。", "",
            "## 运行信息", "",
            "| 项目 | 值 |", "| --- | --- |",
            "| 运行编号 | \(e(result.id)) |",
            "| 来源运行 | \(e(result.parentRunID ?? "无")) |",
            "| 任务 | \(e(result.name)) |",
            "| APK 文件 | \(e(result.apkFileName)) |",
            "| 包名 | \(e(result.apk.packageName)) |",
            "| 输入版本 | \(e(result.apk.versionName)) (\(e(result.apk.versionCode))) |",
            "| 安装后校验 | \(e(result.installedVersion)) |",
            "| APK SHA-256 | \(result.apk.sha256) |",
            "| 可调试 | \(result.apk.debuggable ? "是" : "否") |",
            "| 设备 | \(e(result.deviceName)) · \(e(result.serial)) |",
            "| 系统信息 | \(e(result.deviceDetails)) |",
            "| 环境 | \(e(result.environment))（由操作者指定，未自动验证） |",
            "| 用例集 | \(e(result.suiteName)) · 修订 \(result.suiteRevision) |",
            "| 执行引擎 | \(e(result.engineVersion)) |",
            "| 主机 | \(e(ProcessInfo.processInfo.operatingSystemVersionString)) |",
            "| 数据策略 | \(result.clearData ? "已明确选择清除应用数据" : "保留应用数据") |",
            "| 开始 | \(formatter.string(from: result.startedAt)) |",
            "| 结束 | \(result.endedAt.map { formatter.string(from: $0) } ?? "尚未结束") |",
            "| 耗时 | \(String(format: "%.2f", result.duration)) 秒 |",
            "| 结束原因 | \(e(result.reason.isEmpty ? "正常完成" : result.reason)) |", "",
            "## 汇总", "",
            "| 选中 | 通过 | 失败 | 阻塞 | 已取消 | 未执行 |",
            "| --- | --- | --- | --- | --- | --- |",
            "| \(n) | \(passed) | \(failed) | \(result.count(.blocked)) | \(result.count(.cancelled)) | \(result.count(.notRun)) |", "",
            "断言完成率：\(passed + failed) / \(n)（\(completion)）。通过比例：\(passed) / \(n)（\(ratio)）。", "",
            "## 用例结果", "", "| 编号 | 用例 | 结果 | 耗时 | 原因 |", "| --- | --- | --- | --- | --- |"
        ]
        for item in result.cases {
            lines.append("| \(e(item.id)) | \(e(item.name)) | \(item.status.title) | \(String(format: "%.2f", item.duration)) 秒 | \(e(item.reason)) |")
        }
        lines += ["", "## 用例详情", ""]
        for item in result.cases {
            lines += ["### \(e(item.id)) \(e(item.name))", "",
                      "结果：\(item.status.title)。需求：\(e(item.requirement))。用例优先级：\(e(item.priority))。", "",
                      "前置说明：\(e(item.preconditions))。", "",
                      "| 步骤 | 阶段 | 动作 | 预期 | 实际 | 结果 |", "| --- | --- | --- | --- | --- | --- |"]
            for step in item.steps {
                lines.append("| \(e(step.name)) | \(e(step.phase)) | \(e(step.action)) | \(e(step.expected)) | \(e(step.actual)) | \(step.status.title) |")
            }
            lines += ["", "原因：\(e(item.reason.isEmpty ? "所有配置步骤已完成" : item.reason))。根因：需要结合证据复核。", ""]
            for step in item.steps {
                if let path = step.screenshot {
                    if artifactExists(path, in: directory) {
                        lines += ["\(e(step.name)) 截图：", "", "![\(e(step.name))](\(linkPath(path)))", ""]
                    } else { lines += ["\(e(step.name))：截图文件缺失。", ""] }
                }
                if let path = step.log, artifactExists(path, in: directory) {
                    lines += ["[\(e(step.name)) 日志片段](\(linkPath(path)))", ""]
                }
            }
        }
        lines += ["## 证据与范围", "",
                  "界面操作、截图及日志均绑定上述设备。日志断言只检查本次采集游标之后的目标应用日志。系统事件仅按可归因目标过滤；未观测到事件不能证明不存在问题。",
                  "", "未覆盖：后台记账与埋点接收、性能基准、像素级视觉比对、多设备兼容性。Release 移除的日志不可恢复。",
                  "", "AI：未启用。"]
        if !result.warnings.isEmpty { lines += ["", "### 证据缺口与提示", ""] + result.warnings.map { "- \(e($0))" } }
        lines += ["", "### 附件", ""]
        for path in result.artifacts where artifactExists(path, in: directory) {
            lines.append("- [\(e(path))](\(linkPath(path)))")
        }
        lines += ["", "APK 快照保存在原始运行目录中，分享导出默认不包含 APK。日志和截图可能包含业务内容，请在分享前检查。", ""]
        return lines.joined(separator: "\n")
    }
    public static func artifactExists(_ path: String, in directory: URL) -> Bool {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let target = directory.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL.path
        return target.hasPrefix(root) && (try? URL(fileURLWithPath: target).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    private static func linkPath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?()"))) ?? path
    }
}

public enum AutomationStorage {
    public static func save(_ result: AutomationResult, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AutomationJSON.encode(result).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        try AutomationReport.render(result, directory: directory).write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        if result.endedAt != nil { try manifest(result, directory: directory) }
    }
    private struct Manifest: Encodable {
        struct Entry: Encodable { let path: String; let present: Bool; let sha256: String? }
        let schemaVersion = 1
        let runID: String
        let apkSHA256: String
        let files: [Entry]
    }
    private static func manifest(_ result: AutomationResult, directory: URL) throws {
        var paths = Set(result.artifacts + ["report.md", "result.json"])
        for test in result.cases {
            for step in test.steps { if let p = step.log { paths.insert(p) }; if let p = step.screenshot { paths.insert(p) } }
        }
        for path in ["input/suite.snapshot.json", "input/suite.resolved.json"] where AutomationReport.artifactExists(path, in: directory) { paths.insert(path) }
        let entries = try paths.sorted().map { path -> Manifest.Entry in
            let present = AutomationReport.artifactExists(path, in: directory)
            return Manifest.Entry(path: path, present: present, sha256: present ? try APKInspector.sha256(directory.appendingPathComponent(path)) : nil)
        }
        try AutomationJSON.encode(Manifest(runID: result.id, apkSHA256: result.apk.sha256, files: entries))
            .write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }
    public static func load(_ directory: URL, recover: Bool = false) throws -> AutomationResult {
        var result = try AutomationJSON.decode(AutomationResult.self, from: Data(contentsOf: directory.appendingPathComponent("result.json")))
        if recover && result.endedAt == nil { result.recoverInterrupted(); try save(result, directory: directory) }
        return result
    }
    public static func export(_ result: AutomationResult, from source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw AutomationError.configuration("导出目录已存在，请选择新的目录名称") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            var exported = result
            var paths = Set(result.artifacts)
            for test in result.cases {
                for step in test.steps { if let path = step.screenshot { paths.insert(path) }; if let path = step.log { paths.insert(path) } }
            }
            for path in paths.sorted() {
                guard AutomationReport.artifactExists(path, in: source) else { exported.warnings.append("导出时附件缺失：\(path)"); continue }
                guard path.hasPrefix("evidence/") else { continue }
                let target = destination.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source.appendingPathComponent(path), to: target)
            }
            exported.artifacts = paths.sorted().filter { $0.hasPrefix("evidence/") && AutomationReport.artifactExists($0, in: destination) }
            try save(exported, directory: destination)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}
