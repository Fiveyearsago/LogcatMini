import Foundation
import Combine
import LogcatCore

@MainActor final class LogMergeSettings: ObservableObject {
    static let shared = LogMergeSettings()
    @Published private(set) var rules: [LogMergeRule]
    private let defaults: UserDefaults
    private static let storageKey = "logs.customMergeRules.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([LogMergeRule].self, from: $0) } ?? []
        rules = Array(rules.prefix(32)).filter { (try? $0.validate()) != nil }
    }
    func save(_ rule: LogMergeRule) throws {
        try rule.validate()
        var next = rules
        if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index] = rule }
        else {
            guard next.count < 32 else { throw NSError(domain: "LogMergeRule", code: 1, userInfo: [NSLocalizedDescriptionKey: "最多保存 32 条自定义规则，请先删除不再使用的规则。"]) }
            next.append(rule)
        }
        try persist(next)
    }
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.enabled = enabled; try? save(rule)
    }
    func remove(_ id: UUID) { try? persist(rules.filter { $0.id != id }) }
    private func persist(_ next: [LogMergeRule]) throws {
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: Self.storageKey); rules = next
    }
}

struct LogMergePreview {
    let inputCount: Int
    let mergedCount: Int
    let output: String
    static func evaluate(rule: LogMergeRule, sample: String) throws -> Self {
        try rule.validate()
        guard sample.utf8.count <= 1024 * 1024 else { throw NSError(domain: "LogMergeRule", code: 1, userInfo: [NSLocalizedDescriptionKey: "样例请控制在 1 MiB 以内。只需粘贴一组完整分段。 "]) }
        var lines = sample.components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty, lines.count <= 256 else { throw NSError(domain: "LogMergeRule", code: 1, userInfo: [NSLocalizedDescriptionKey: "请粘贴 1～256 行样例，每行一个分段。 "]) }
        let entries = lines.enumerated().map { index, line in
            let id = UInt64(index + 1)
            return LogParser.parse(line, id: id) ?? IOSLogParser.simulator(line, id: id) ??
                LogEntry(id: id, date: "2000-01-01", time: "12:00:00.000", pid: "1", tid: "1", level: .debug,
                         tag: rule.tagContains.isEmpty ? "Preview" : rule.tagContains, message: line, raw: line)
        }
        var active = rule; active.enabled = true
        var buffer = LogBuffer(mergeRules: [active], includesBuiltInRules: false)
        buffer.append(entries)
        return .init(inputCount: entries.count, mergedCount: buffer.entries.filter { $0.mergedParts > 1 }.count,
                     output: buffer.entries.map { "[\($0.mergedParts > 1 ? "已合并 \($0.mergedParts) 段" : "未合并")]\n\($0.message)" }.joined(separator: "\n\n"))
    }
}
