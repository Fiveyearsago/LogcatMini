import Foundation

public enum TestStatus: String, Codable, CaseIterable {
    case pending, running, passed, failed, blocked, cancelled, notRun = "not_run"
    public var title: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "执行中"
        case .passed: return "通过"
        case .failed: return "失败"
        case .blocked: return "阻塞"
        case .cancelled: return "已取消"
        case .notRun: return "未执行"
        }
    }
}

public enum TestAction: String, Codable, CaseIterable {
    case launchApp, restartApp, tap, inputText, swipe, pressKey, waitVisible
    case assertVisible, assertNotVisible, assertText, assertForeground, assertLog, assertNoLog, screenshot
    public var title: String {
        switch self {
        case .launchApp: return "启动应用"
        case .restartApp: return "重启应用"
        case .tap: return "点击"
        case .inputText: return "输入文字"
        case .swipe: return "滑动"
        case .pressKey: return "按键"
        case .waitVisible: return "等待元素"
        case .assertVisible: return "检查可见"
        case .assertNotVisible: return "检查不可见"
        case .assertText: return "检查文字"
        case .assertForeground: return "检查前台应用"
        case .assertLog: return "检查日志出现"
        case .assertNoLog: return "检查日志不出现"
        case .screenshot: return "截图"
        }
    }
    public var isAssertion: Bool { rawValue.hasPrefix("assert") }
    public var needsTarget: Bool {
        [.tap, .inputText, .waitVisible, .assertVisible, .assertNotVisible, .assertText].contains(self)
    }
}

public struct TestTarget: Codable, Equatable {
    public var id: String?
    public var text: String?
    public var contentDescription: String?
    public var belowText: String?
    public init(id: String? = nil, text: String? = nil, contentDescription: String? = nil, belowText: String? = nil) {
        self.id = id; self.text = text; self.contentDescription = contentDescription; self.belowText = belowText
    }
    public var summary: String {
        [id.map { "ID=\($0)" }, text.map { "文字=\($0)" }, contentDescription.map { "描述=\($0)" }, belowText.map { "位于文字下方=\($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
    public var isEmpty: Bool { [id, text, contentDescription].compactMap { $0 }.allSatisfy(\.isEmpty) }
}

public struct TestStep: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var action: TestAction
    public var target: TestTarget?
    public var expected: String?
    public var text: String?
    public var match: String?
    public var timeoutMs: Int?
    public var direction: String?
    public var count: Int?
    public var key: String?
    public var label: String?
    public var tag: String?
    public var content: String?
    public var sinceStep: String?
    public var clear: Bool?
    public init(id: String = UUID().uuidString, name: String = "", action: TestAction = .assertForeground,
                target: TestTarget? = nil, expected: String? = nil, text: String? = nil, timeoutMs: Int? = nil) {
        self.id = id; self.name = name.isEmpty ? action.title : name; self.action = action
        self.target = target; self.expected = expected; self.text = text; self.timeoutMs = timeoutMs
    }
    public var timeout: TimeInterval { Double(timeoutMs ?? (action == .assertNoLog || action == .assertNotVisible ? 5000 : 10000)) / 1000 }
    public var expectation: String {
        if let expected { return expected }
        if let content { return "\(tag ?? "*") · \(content)" }
        if let target { return target.summary }
        return action.title
    }
}

public struct AutomationCase: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var requirement: String
    public var priority: String
    public var tags: [String]?
    public var startPolicy: String
    public var timeoutMs: Int
    public var preconditionNotes: String
    public var preconditions: [TestStep]?
    public var steps: [TestStep]
    public var cleanup: [TestStep]?
    public init(id: String = "CASE-" + String(UUID().uuidString.prefix(8)), name: String = "新用例",
                steps: [TestStep] = [TestStep(action: .assertForeground)]) {
        self.id = id; self.name = name; self.steps = steps
        requirement = "验证所配置的界面结果"; priority = "P1"; startPolicy = "restart"
        timeoutMs = 180000; preconditionNotes = "设备已解锁，应用所需账号已准备"
    }
}

public struct TestVariable: Codable, Equatable {
    public var type: String
    public var defaultValue: String
    public var sensitive: Bool
    enum CodingKeys: String, CodingKey { case type, defaultValue = "default", sensitive }
    public init(value: String) { type = "string"; defaultValue = value; sensitive = false }
}

public struct TestSuite: Codable, Equatable {
    public struct App: Codable, Equatable { public var packageName: String; public init(packageName: String) { self.packageName = packageName } }
    public var schemaVersion: Int
    public var suiteId: String
    public var name: String
    public var revision: Int
    public var app: App
    public var variables: [String: TestVariable]?
    public var cases: [AutomationCase]
    public init(packageName: String, name: String = "基础启动检查", cases: [AutomationCase]? = nil) {
        schemaVersion = 1; suiteId = UUID().uuidString; revision = 1; self.name = name
        app = App(packageName: packageName)
        self.cases = cases ?? [AutomationCase(id: "START-001", name: "应用进入前台", steps: [
            TestStep(id: "foreground", action: .assertForeground), TestStep(id: "screenshot", action: .screenshot)
        ])]
    }
    public func validated() throws -> TestSuite {
        func reject(_ message: String) throws -> Never { throw AutomationError.configuration(message) }
        guard schemaVersion == 1 else { try reject("仅支持 schemaVersion 1") }
        guard Self.validPackage(app.packageName) else { try reject("包名无效") }
        guard !cases.isEmpty, cases.count <= 100 else { try reject("用例数必须为 1–100") }
        guard Set(cases.map(\.id)).count == cases.count else { try reject("用例编号不能重复") }
        let vars = variables ?? [:]
        for (name, variable) in vars {
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  variable.type == "string", !variable.sensitive else {
                try reject("变量 \(name)：当前仅支持普通字符串；请在设备上提前完成敏感账号输入")
            }
        }
        var resolved = self
        for i in cases.indices {
            let item = cases[i]
            guard Self.validID(item.id), !item.name.isEmpty, !item.requirement.isEmpty else { try reject("用例编号、名称或关联需求无效") }
            guard ["restart", "clearAndRestart"].contains(item.startPolicy),
                  (1000...600000).contains(item.timeoutMs) else { try reject("\(item.name)：起始策略或超时无效") }
            guard item.steps.contains(where: { $0.action.isAssertion }), item.steps.count <= 200 else { try reject("\(item.name)：需要至少一个结果断言，且最多 200 步") }
            let all = (item.preconditions ?? []) + item.steps + (item.cleanup ?? [])
            guard all.count <= 200 else { try reject("\(item.name)：前置、主体与收尾合计不能超过 200 步") }
            guard Set(all.map(\.id)).count == all.count, all.allSatisfy({ Self.validID($0.id) }) else { try reject("\(item.name)：步骤编号无效或重复") }
            var known = Set<String>()
            func resolve(_ steps: [TestStep]) throws -> [TestStep] {
                try steps.map { original in
                    var step = original
                    func value(_ input: String?) throws -> String? {
                        guard var input else { return nil }
                        for (key, v) in vars { input = input.replacingOccurrences(of: "{{\(key)}}", with: v.defaultValue) }
                        guard !input.contains("{{"), !input.contains("$" + "{"), !input.contains("\0") else { try reject("\(step.name)：存在未定义变量或不支持的表达式") }
                        return input
                    }
                    step.text = try value(step.text); step.expected = try value(step.expected); step.content = try value(step.content)
                    if let target = step.target {
                        step.target = TestTarget(id: try value(target.id), text: try value(target.text), contentDescription: try value(target.contentDescription), belowText: try value(target.belowText))
                    }
                    guard !step.name.isEmpty, (100...60000).contains(step.timeoutMs ?? 10000) else { try reject("\(item.name)：步骤名称或超时无效（0.1–60 秒）") }
                    if step.action.needsTarget && (step.target?.isEmpty ?? true) { try reject("\(step.name)：请配置控件目标") }
                    if step.action == .assertText && step.expected == nil { try reject("\(step.name)：缺少预期文字") }
                    if step.action == .inputText && step.text == nil { try reject("\(step.name)：缺少输入内容") }
                    if step.action == .inputText && !(step.text ?? "").unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) {
                        try reject("\(step.name)：此执行器的 Android 文字输入目前仅支持 ASCII；中文定位和断言可用")
                    }
                    if let match = step.match, !["exact", "contains", "regex"].contains(match) { try reject("\(step.name)：匹配模式无效") }
                    if step.match == "regex" { _ = try NSRegularExpression(pattern: step.expected ?? step.content ?? "") }
                    if [.assertLog, .assertNoLog].contains(step.action) {
                        guard let start = step.sinceStep, known.contains(start), let content = step.content, !content.isEmpty else {
                            try reject("\(step.name)：日志规则需引用已执行步骤并填写内容")
                        }
                    }
                    if step.action == .swipe && (!["UP", "DOWN", "LEFT", "RIGHT"].contains(step.direction ?? "UP") || !(1...5).contains(step.count ?? 1)) { try reject("\(step.name)：滑动方向或次数无效") }
                    if step.action == .pressKey && !["Back", "Home", "Enter"].contains(step.key ?? "Back") { try reject("\(step.name)：按键无效") }
                    known.insert(step.id)
                    return step
                }
            }
            guard (item.preconditions ?? []).allSatisfy({ $0.action.isAssertion || $0.action == .waitVisible }) else { try reject("\(item.name)：前置检查只能使用断言或等待") }
            resolved.cases[i].preconditions = try resolve(item.preconditions ?? [])
            resolved.cases[i].steps = try resolve(item.steps)
            resolved.cases[i].cleanup = try resolve(item.cleanup ?? [])
        }
        return resolved
    }
    public static func validID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil }
    public static func validPackage(_ value: String) -> Bool { value.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$", options: .regularExpression) != nil }
}

public enum AutomationError: Error, LocalizedError {
    case configuration(String), infrastructure(String), assertion(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .configuration(let s), .infrastructure(let s), .assertion(let s): return s
        case .cancelled: return "用户停止测试"
        }
    }
    public var status: TestStatus { switch self { case .assertion: return .failed; case .cancelled: return .cancelled; default: return .blocked } }
}

public struct APKInfo: Codable, Equatable {
    public var name: String
    public var packageName: String
    public var versionName: String
    public var versionCode: String
    public var minimumSDK: Int
    public var abi: String
    public var debuggable: Bool
    public var sha256: String
}

public struct StepResult: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var action: String
    public var expected: String
    public var actual: String = ""
    public var status: TestStatus = .pending
    public var startedAt: Date?
    public var duration: Double = 0
    public var screenshot: String?
    public var log: String?
    public var phase: String
    public init(step: TestStep, phase: String = "steps") {
        id = step.id; name = step.name; action = step.action.title; expected = step.expectation; self.phase = phase
    }
}

public struct CaseResult: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var requirement: String
    public var priority: String
    public var preconditions: String
    public var status: TestStatus = .pending
    public var reason: String = ""
    public var steps: [StepResult]
    public var startedAt: Date?
    public var duration: Double = 0
    public init(test: AutomationCase) {
        id = test.id; name = test.name; requirement = test.requirement; priority = test.priority; preconditions = test.preconditionNotes
        steps = (test.preconditions ?? []).map { StepResult(step: $0, phase: "preconditions") }
            + test.steps.map { StepResult(step: $0) }
            + (test.cleanup ?? []).map { StepResult(step: $0, phase: "cleanup") }
    }
}

public struct AutomationResult: Codable, Identifiable, Equatable {
    public var schemaVersion = 1
    public var id: String
    public var parentRunID: String?
    public var name: String
    public var apk: APKInfo
    public var apkFileName: String
    public var serial: String
    public var deviceName: String
    public var environment: String
    public var suiteName: String
    public var suiteRevision: Int
    public var startedAt = Date()
    public var endedAt: Date?
    public var duration: Double = 0
    public var phase = "准备中"
    public var reason = ""
    public var deviceDetails: String = ""
    public var installedVersion: String = "未安装"
    public var engineVersion: String = ""
    public var clearData = false
    public var cases: [CaseResult]
    public var warnings: [String] = []
    public var artifacts: [String] = []
    public init(name: String, apk: APKInfo, apkFileName: String, serial: String, deviceName: String, environment: String, suite: TestSuite) {
        let date = DateFormatter(); date.dateFormat = "yyyyMMdd-HHmmss"
        id = date.string(from: Date()) + "-" + String(UUID().uuidString.prefix(8))
        self.name = name; self.apk = apk; self.apkFileName = apkFileName; self.serial = serial
        self.deviceName = deviceName; self.environment = environment; suiteName = suite.name; suiteRevision = suite.revision
        cases = suite.cases.map { CaseResult(test: $0) }
    }
    public func count(_ status: TestStatus) -> Int { cases.filter { $0.status == status }.count }
    public var verdict: String {
        if endedAt == nil { return phase }
        if count(.failed) > 0 { return isComplete ? "发现失败" : "发现失败，验收未完成" }
        return !cases.isEmpty && count(.passed) == cases.count ? "所选用例通过" : "未完成验收"
    }
    public var isComplete: Bool { !cases.isEmpty && count(.passed) + count(.failed) == cases.count }
    public mutating func recoverInterrupted() {
        guard endedAt == nil else { return }
        phase = "异常中断"; reason = "客户端在运行完成前退出，未自动恢复设备操作"; endedAt = Date()
        for i in cases.indices {
            if cases[i].status == .running { cases[i].status = .blocked; cases[i].reason = reason }
            if cases[i].status == .pending { cases[i].status = .notRun; cases[i].reason = reason }
            for j in cases[i].steps.indices {
                if cases[i].steps[j].status == .running { cases[i].steps[j].status = .blocked; cases[i].steps[j].actual = reason }
                if cases[i].steps[j].status == .pending { cases[i].steps[j].status = .notRun }
            }
        }
    }
}

public enum AutomationJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // Unknown case fields usually mean a typo or a newer unsupported schema, not a safe default.
        if type == TestSuite.self {
            try AutomationJSONShape.suite(JSONSerialization.jsonObject(with: data))
        } else if type == AutomationCase.self {
            try AutomationJSONShape.test(JSONSerialization.jsonObject(with: data))
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

private enum AutomationJSONShape {
    static func fields(_ value: Any, allowed: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw AutomationError.configuration("配置对象格式错误") }
        let unknown = Set(object.keys).subtracting(allowed.split(separator: " ").map(String.init))
        guard unknown.isEmpty else { throw AutomationError.configuration("不支持的配置字段：\(unknown.sorted().joined(separator: ", "))") }
        return object
    }
    static func suite(_ value: Any) throws {
        let object = try fields(value, allowed: "schemaVersion suiteId name revision app variables cases")
        if let app = object["app"] { _ = try fields(app, allowed: "packageName") }
        if let vars = object["variables"] as? [String: Any] {
            for value in vars.values { _ = try fields(value, allowed: "type default sensitive") }
        }
        for item in object["cases"] as? [Any] ?? [] { try test(item) }
    }
    static func test(_ value: Any) throws {
        let object = try fields(value, allowed: "id name requirement priority tags startPolicy timeoutMs preconditionNotes preconditions steps cleanup")
        for phase in ["preconditions", "steps", "cleanup"] {
            for step in object[phase] as? [Any] ?? [] {
                let fields = try fields(step, allowed: "id name action target expected text match timeoutMs direction count key label tag content sinceStep clear")
                if let target = fields["target"] { _ = try self.fields(target, allowed: "id text contentDescription belowText") }
            }
        }
    }
}
