import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct AutomationElement: Identifiable, Equatable {
    public let id = UUID()
    public let resourceID: String
    public let text: String
    public let description: String
    public let bounds: String
    public let enabled: Bool
    public let focused: Bool
    public let password: Bool
    public let hint: String
    public var inputValue: String { text == hint ? "" : text }
    public var target: TestTarget {
        if !resourceID.isEmpty { return TestTarget(id: resourceID, text: text.isEmpty ? nil : text) }
        return TestTarget(text: text.isEmpty ? nil : text, contentDescription: description.isEmpty ? nil : description)
    }
    public func matches(_ target: TestTarget) -> Bool {
        (target.id == nil || target.id == resourceID) && (target.text == nil || target.text == text)
            && (target.contentDescription == nil || target.contentDescription == description)
    }
    public var summary: String { [resourceID, text, description].filter { !$0.isEmpty }.joined(separator: " · ") }
}

private final class HierarchyParser: NSObject, XMLParserDelegate {
    var elements: [AutomationElement] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard name == "node", let bounds = attributes["bounds"], bounds != "[0,0][0,0]" else { return }
        elements.append(AutomationElement(resourceID: attributes["resource-id"] ?? "", text: attributes["text"] ?? "",
            description: attributes["content-desc"] ?? "", bounds: bounds, enabled: attributes["enabled"] == "true",
            focused: attributes["focused"] == "true", password: attributes["password"] == "true", hint: attributes["hint"] ?? ""))
    }
}

private final class JUnitParser: NSObject, XMLParserDelegate {
    var cases = 0, failures = 0, errors = 0, skipped = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "testcase" { cases += 1 }
        if name == "failure" { failures += 1 }
        if name == "error" { errors += 1 }
        if name == "skipped" { skipped += 1 }
    }
}

public final class AutomationDevice {
    public let tools: AutomationTools
    public let serial: String
    public let cancellation: AutomationCancellation
    public var deadline: Double = .infinity
    public init(tools: AutomationTools, serial: String, cancellation: AutomationCancellation) {
        self.tools = tools; self.serial = serial; self.cancellation = cancellation
    }
    public func adb(_ args: [String], timeout: Double = 15, output: URL? = nil) async throws -> String {
        try checkDeadline()
        return try await AutomationProcess.checked(tools.adb, ["-s", serial] + args, timeout: min(timeout, deadline - ProcessInfo.processInfo.systemUptime), cancellation: cancellation, output: output)
    }
    public func checkDeadline() throws {
        if ProcessInfo.processInfo.systemUptime >= deadline { throw AutomationError.infrastructure("用例或任务已达到超时上限") }
    }
    public func ensureOnline() async throws {
        guard try await adb(["get-state"], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines) == "device" else {
            throw AutomationError.infrastructure("目标设备离线或未授权：\(serial)")
        }
    }
    public func launch(package: String, restart: Bool) async throws -> String {
        if restart { _ = try await adb(["shell", "am", "force-stop", package]) }
        let resolved = try await adb(["shell", "cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", package])
        guard let component = resolved.split(whereSeparator: \.isNewline).map(String.init).last,
              component.hasPrefix(package + "/"), component.range(of: "^[A-Za-z0-9_.$/]+$", options: .regularExpression) != nil else {
            throw AutomationError.infrastructure("无法解析应用启动入口：\(resolved)")
        }
        let output = try await adb(["shell", "am", "start", "-W", "-n", component], timeout: 30)
        if output.contains("Error:") || output.contains("Exception") { throw AutomationError.infrastructure(output) }
        return output
    }
    public func foreground(package: String) async throws -> Bool {
        let activity = try await adb(["shell", "dumpsys", "activity", "activities"])
        return activity.split(whereSeparator: \.isNewline).contains {
            ($0.contains("mResumedActivity") || $0.contains("topResumedActivity")) && $0.contains(" \(package)/")
        }
    }
    public func hierarchy() async throws -> [AutomationElement] {
        let remote = "/data/local/tmp/lcm-ui-" + UUID().uuidString + ".xml"
        do {
            let dumped = try await adb(["shell", "uiautomator", "dump", remote], timeout: 12)
            if !dumped.contains("dumped"), dumped.contains("idle") {
                // Video ads may never become idle. Maestro can read their live accessibility tree.
                try tools.validate(needsMaestro: true)
                let json = try await AutomationProcess.checked(tools.maestro,
                    ["--device", serial, "hierarchy", "--no-ansi"], timeout: min(30, deadline - ProcessInfo.processInfo.systemUptime),
                    cancellation: cancellation, environment: tools.engineEnvironment)
                return try Self.parseMaestroHierarchy(json)
            }
            guard dumped.contains("dumped") else { throw AutomationError.infrastructure("无法读取页面控件：\(dumped)") }
            let xml = try await adb(["shell", "cat", remote])
            _ = try? await adb(["shell", "rm", "-f", remote], timeout: 3)
            return try Self.parseHierarchy(xml)
        } catch {
            // The generated path is the only remote file we remove; cancellation still permits this bounded cleanup.
            _ = try? await AutomationProcess.run(tools.adb, ["-s", serial, "shell", "rm", "-f", remote], timeout: 3)
            throw error
        }
    }
    public static func parseHierarchy(_ xml: String) throws -> [AutomationElement] {
        let parser = XMLParser(data: Data(xml.utf8)); let delegate = HierarchyParser()
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw AutomationError.infrastructure("页面控件数据不是有效 XML") }
        return delegate.elements
    }
    public static func parseMaestroHierarchy(_ json: String) throws -> [AutomationElement] {
        struct Node: Decodable { var attributes: [String: String]; var children: [Node]? }
        guard let root = try? JSONDecoder().decode(Node.self, from: Data(json.utf8)) else {
            throw AutomationError.infrastructure("Maestro 页面控件数据不是有效 JSON")
        }
        var elements: [AutomationElement] = []
        func visit(_ node: Node) {
            let a = node.attributes
            if let bounds = a["bounds"], bounds != "[0,0][0,0]" {
                elements.append(AutomationElement(resourceID: a["resource-id"] ?? "", text: a["text"] ?? "",
                    description: a["accessibilityText"] ?? "", bounds: bounds, enabled: a["enabled"] == "true",
                    focused: a["focused"] == "true", password: a["password"] != "false", hint: a["hintText"] ?? ""))
            }
            for child in node.children ?? [] { visit(child) }
        }
        visit(root)
        return elements
    }
    public func screenshot(to url: URL) async throws {
        try checkDeadline()
        let result = try await AutomationProcess.run(tools.adb, ["-s", serial, "exec-out", "screencap", "-p"],
            timeout: min(20, deadline - ProcessInfo.processInfo.systemUptime), cancellation: cancellation, output: url)
        let data = try Data(contentsOf: url)
        guard result.code == 0, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), data.count > 24 else {
            try? FileManager.default.removeItem(at: url)
            throw AutomationError.infrastructure("设备未返回有效 PNG 截图")
        }
    }
    public func checkUI(_ step: TestStep) async throws -> String {
        let start = ProcessInfo.processInfo.systemUptime
        var actual = "未找到目标元素"
        repeat {
            try cancellation.check()
            try checkDeadline()
            if step.action == .assertForeground {
                if try await foreground(package: step.expected ?? "") { return "目标应用位于前台" }
                actual = "目标应用不在前台"
            } else {
                let elements = try await hierarchy()
                let target = step.target ?? TestTarget()
                let matches = try Self.matching(target, in: elements)
                if step.action == .assertNotVisible {
                    if !matches.isEmpty { throw AutomationError.assertion("观察窗口中出现了不应可见的元素：\(matches[0].summary)") }
                    actual = "在完整观察窗口中未发现目标元素"
                } else {
                    if matches.count > 1 { throw AutomationError.assertion("目标不唯一（\(matches.count) 个），请补充控件 ID 或文字") }
                    if let element = matches.first {
                        actual = element.summary
                        if step.action != .assertText || Self.textMatches(element.text, expected: step.expected ?? "", mode: step.match ?? "exact") {
                            if [.tap, .inputText].contains(step.action) && !element.enabled { throw AutomationError.assertion("目标控件被禁用：\(actual)") }
                            if [.tap, .inputText].contains(step.action) {
                                let selectorText = target.text ?? target.contentDescription
                                let projected = try Self.relativeFilter(elements.filter {
                                    (target.id == nil || $0.resourceID == target.id) &&
                                    (selectorText == nil || $0.text == selectorText || $0.description == selectorText)
                                }, target: target, in: elements)
                                guard projected.count == 1 else { throw AutomationError.configuration("当前动作执行器无法唯一表达此组合定位，请补充唯一控件 ID") }
                            }
                            return actual
                        }
                        actual = "实际文字：\(element.text)"
                    }
                }
            }
            if ProcessInfo.processInfo.systemUptime - start >= step.timeout { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        } while true
        if step.action == .assertNotVisible { return actual }
        throw AutomationError.assertion("等待 \(Int(step.timeout)) 秒后仍不满足预期。\(actual)")
    }
    public static func matching(_ target: TestTarget, in elements: [AutomationElement]) throws -> [AutomationElement] {
        try relativeFilter(elements.filter { $0.matches(target) }, target: target, in: elements)
    }
    private static func relativeFilter(_ candidates: [AutomationElement], target: TestTarget, in elements: [AutomationElement]) throws -> [AutomationElement] {
        guard let text = target.belowText else { return candidates }
        // Match Maestro's text projection too, so an accessibility label cannot introduce an ambiguous anchor.
        let anchors = elements.filter { $0.text == text || $0.description == text }
        guard anchors.count <= 1 else { throw AutomationError.assertion("下方定位的参照文字不唯一：\(text)") }
        guard let anchor = anchors.first else { return [] }
        func coordinates(_ bounds: String) throws -> [Int] {
            guard bounds.range(of: "^\\[-?[0-9]+,-?[0-9]+\\]\\[-?[0-9]+,-?[0-9]+\\]$", options: .regularExpression) != nil else {
                throw AutomationError.infrastructure("页面控件坐标无效")
            }
            return bounds.split { "[],".contains($0) }.compactMap { Int($0) }
        }
        let bottom = try coordinates(anchor.bounds)[3]
        return try candidates.filter { try coordinates($0.bounds)[1] >= bottom }
    }
    public static func textMatches(_ actual: String, expected: String, mode: String) -> Bool {
        switch mode {
        case "contains": return actual.contains(expected)
        case "regex": return actual.range(of: expected, options: .regularExpression) != nil
        default: return actual == expected
        }
    }
    public func executeUI(_ step: TestStep, package: String, directory: URL) async throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let flow = directory.appendingPathComponent("flow.yaml")
        var eraseCount = 1
        var inputElement: AutomationElement?
        if step.action == .inputText {
            let matches = try Self.matching(step.target ?? TestTarget(), in: await hierarchy())
            guard matches.count == 1 else { throw AutomationError.assertion("输入前目标已变化，请重新确认用例") }
            guard !matches[0].password else { throw AutomationError.configuration("当前输入动作只支持可读取内容的普通文本框，不支持密码框") }
            inputElement = matches[0]
            eraseCount = max(1, matches[0].inputValue.utf16.count)
            if (step.clear ?? true) && eraseCount > 100 { throw AutomationError.configuration("输入框原文超过 100 字符，请先手动清空；当前版本不自动清除长文本") }
        }
        try Self.flow(step, package: package, eraseCount: eraseCount).write(to: flow, atomically: true, encoding: .utf8)
        let junit = directory.appendingPathComponent("junit.xml")
        let output: CommandOutput
        do {
            output = try await AutomationProcess.run(tools.maestro,
                ["--device", serial, "--no-ansi", "test", "--format", "JUNIT", "--output", junit.path,
                 "--debug-output", directory.appendingPathComponent("debug").path, flow.path],
                timeout: min(max(45, step.timeout + 35), deadline - ProcessInfo.processInfo.systemUptime), cancellation: cancellation, environment: tools.engineEnvironment,
                output: directory.appendingPathComponent("engine.log"))
        } catch {
            // Stop this adapter's Android driver too; killing the host JVM alone can leave an in-flight RPC running.
            _ = try? await AutomationProcess.run(tools.adb, ["-s", serial, "shell", "am", "force-stop", "dev.mobile.maestro"], timeout: 5)
            throw error
        }
        guard let data = try? Data(contentsOf: junit) else {
            throw AutomationError.infrastructure("执行器未生成有效结果：\(String(output.text.suffix(1500)))")
        }
        let parser = XMLParser(data: data); let result = JUnitParser(); parser.delegate = result
        guard parser.parse(), result.cases > 0, result.errors == 0, result.skipped == 0 else {
            throw AutomationError.infrastructure("执行器结果无效、错误或跳过：\(String(output.text.suffix(1500)))")
        }
        if result.failures > 0 { throw AutomationError.assertion("设备动作未完成：\(String(output.text.suffix(1500)))") }
        guard output.code == 0 else { throw AutomationError.infrastructure("执行器退出码 \(output.code)：\(String(output.text.suffix(1500)))") }
        if step.action == .inputText, let inputElement {
            // Maestro typing can stall with OEM IMEs. ADB injects the validated ASCII text into the focused field.
            let focused = try Self.locateInput(inputElement, in: await hierarchy())
            guard focused.focused else { throw AutomationError.infrastructure("输入框未获得焦点，已停止输入") }
            _ = try await adb(["shell", "input", "keyevent", "KEYCODE_MOVE_END"])
            if step.clear ?? true {
                _ = try await adb(["shell", "input", "keyevent"] + Array(repeating: "KEYCODE_DEL", count: eraseCount), timeout: 15)
            }
            for command in Self.inputCommands(step.text ?? "") { _ = try await adb(["shell", command], timeout: 20) }
            let expected = ((step.clear ?? true) ? "" : inputElement.inputValue) + (step.text ?? "")
            let end = ProcessInfo.processInfo.systemUptime + step.timeout
            repeat {
                let actual = try Self.locateInput(inputElement, in: await hierarchy())
                if Self.inputMatches(actual, expected: expected) { return "已核对输入框内容与预期一致（业务结果由后续断言检查）" }
                if ProcessInfo.processInfo.systemUptime >= end {
                    throw AutomationError.infrastructure("输入框内容与预期不一致。请将设备输入法切换为英文 / ASCII 后重试；中文输入法可能将文字保留在候选区。")
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            } while true
        }
        return "执行引擎确认动作完成（业务结果由后续断言检查）"
    }
    private static func locateInput(_ original: AutomationElement, in elements: [AutomationElement]) throws -> AutomationElement {
        let candidates = elements.filter { original.resourceID.isEmpty ? $0.bounds == original.bounds : $0.resourceID == original.resourceID }
        let matches = candidates.count == 1 ? candidates : candidates.filter { $0.bounds == original.bounds }
        guard matches.count == 1, !matches[0].password else { throw AutomationError.infrastructure("无法唯一确认输入框，已停止输入检查") }
        return matches[0]
    }
    public static func inputMatches(_ element: AutomationElement, expected: String) -> Bool {
        // UI Automator can report a hint as text. Never treat a placeholder as a verified input value.
        !element.password && (element.hint.isEmpty || element.text != element.hint) && element.text == expected
    }
    public static func inputCommands(_ text: String) -> [String] {
        // Android input interprets %s as space. Split literal percent signs to preserve a literal "%s".
        let parts = text.components(separatedBy: "%")
        return parts.enumerated().compactMap { index, part in
            let value = part.replacingOccurrences(of: " ", with: "%s") + (index < parts.count - 1 ? "%" : "")
            guard !value.isEmpty else { return nil }
            return "input text '" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
    }
    public static func flow(_ step: TestStep, package: String, eraseCount: Int = 50) -> String {
        func quoted(_ s: String) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(data: try! encoder.encode(s), encoding: .utf8)!
        }
        func literal(_ s: String) -> String { "^" + NSRegularExpression.escapedPattern(for: s) + "$" }
        func selector(_ target: TestTarget) -> [String] {
            var rows: [String] = []
            if let id = target.id { rows.append("    id: " + quoted(literal(id))) }
            if let text = target.text ?? target.contentDescription { rows.append("    text: " + quoted(literal(text))) }
            if let text = target.belowText { rows += ["    below:", "      text: " + quoted(literal(text))] }
            return rows
        }
        var rows = ["appId: " + quoted(package), "---"]
        switch step.action {
        case .tap, .inputText:
            rows += ["- tapOn:"] + selector(step.target ?? TestTarget()) + ["    retryTapIfNoChange: false"]
        case .swipe:
            for _ in 0..<(step.count ?? 1) { rows += ["- swipe:", "    direction: " + quoted(step.direction ?? "UP")] }
        case .pressKey: rows += ["- pressKey: " + quoted(step.key ?? "Back")]
        default: break
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
