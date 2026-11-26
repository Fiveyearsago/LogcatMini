import Foundation

/// A local, declarative rule for explicitly numbered messages. No executable code or scripts.
public struct LogMergeRule: Codable, Equatable, Identifiable {
    public enum Mode: String, Codable, CaseIterable { case template, regex }
    public var id = UUID()
    public var name = "自定义分段"
    public var enabled = true
    public var mode: Mode = .template
    public var pattern = "seq={key} part={index}/{total} {body}"
    public var tagContains = ""
    public var maximumSeconds: Double = 2
    public var requireJSON = false
    public init() {}

    public func validate() throws { _ = try CompiledLogMergeRule(self) }
}

struct CompiledLogMergeRule {
    let rule: LogMergeRule
    let expression: NSRegularExpression
    let hasPrefix: Bool
    struct Match {
        let key: String, body: String, prefix: String
        let index: Int, total: Int
    }
    init(_ rule: LogMergeRule) throws {
        func invalid(_ text: String) -> NSError { NSError(domain: "LogMergeRule", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("请填写规则名称。") }
        guard rule.pattern.utf8.count <= 2048 else { throw invalid("匹配规则过长，请控制在 2048 字节以内。") }
        guard rule.maximumSeconds.isFinite, (0.1...30).contains(rule.maximumSeconds) else { throw invalid("合并时间跨度应在 0.1～30 秒之间。") }
        var pattern = rule.pattern
        if rule.mode == .template {
            let tokens = ["key", "index", "total", "body"]
            for token in tokens {
                guard pattern.components(separatedBy: "{\(token)}").count == 2 else { throw invalid("模板必须各包含一次 {key}、{index}、{total}、{body}。") }
            }
            let marker = try NSRegularExpression(pattern: #"\{(key|index|total|body)\}"#)
            var result = "^", start = pattern.startIndex
            for match in marker.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)) {
                let range = Range(match.range, in: pattern)!, tokenRange = Range(match.range(at: 1), in: pattern)!
                result += NSRegularExpression.escapedPattern(for: String(pattern[start..<range.lowerBound]))
                let token = String(pattern[tokenRange])
                result += "(?<\(token)>" + (["index", "total"].contains(token) ? "[0-9]+" : token == "body" ? "[\\s\\S]*" : ".+?") + ")"
                start = range.upperBound
            }
            pattern = result + NSRegularExpression.escapedPattern(for: String(pattern[start...])) + "$"
        } else {
            for name in ["key", "index", "total", "body"] where !pattern.contains("(?<\(name)>") {
                throw invalid("正则需要命名捕获组 key、index、total、body，例如 (?<index>[0-9]+)。")
            }
        }
        do { expression = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) }
        catch { throw invalid("正则表达式无效：\(error.localizedDescription)") }
        hasPrefix = pattern.contains("(?<prefix>")
        self.rule = rule
    }
    func match(_ entry: LogEntry) -> Match? {
        guard rule.enabled, entry.mergedParts == 1,
              rule.tagContains.isEmpty || entry.tag.localizedCaseInsensitiveContains(rule.tagContains),
              entry.message.utf8.count <= 2 * 1024 * 1024 else { return nil }
        let message = entry.displayMessage, range = NSRange(message.startIndex..., in: message)
        // User expressions are bounded and interruptible, including pathological backtracking.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.01
        var found: NSTextCheckingResult?
        expression.enumerateMatches(in: message, options: [.reportProgress], range: range) { result, _, stop in
            if ProcessInfo.processInfo.systemUptime > deadline { stop.pointee = true; return }
            if let result { if result.range == range { found = result }; stop.pointee = true }
        }
        guard let match = found else { return nil }
        func value(_ name: String) -> String? { Range(match.range(withName: name), in: message).map { String(message[$0]) } }
        guard let key = value("key"), !key.isEmpty, let body = value("body"),
              let i = value("index").flatMap(Int.init), let n = value("total").flatMap(Int.init),
              (2...256).contains(n), (1...n).contains(i) else { return nil }
        return Match(key: key, body: body, prefix: hasPrefix ? value("prefix") ?? "" : "", index: i, total: n)
    }
}
