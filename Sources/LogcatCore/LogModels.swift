import Foundation

public enum LogLevel: String, CaseIterable {
    case verbose = "V", debug = "D", info = "I", warning = "W", error = "E", fatal = "F"
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
    public var title: String {
        switch self {
        case .verbose: return "Verbose"
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warn"
        case .error: return "Error"
        case .fatal: return "Fatal"
        }
    }
}

public struct LogEntry: Identifiable, Equatable {
    public let id: UInt64
    public let date: String
    public let time: String
    public let pid: String
    public let tid: String
    public let level: LogLevel
    public let tag: String
    public var message: String
    public var raw: String
    public var sourceIDs: [UInt64] = []
    public var mergedParts: Int { max(1, sourceIDs.count) }
    /// A merged group is one logical record in the inspector, clipboard and export.
    public var fullText: String {
        guard mergedParts > 1 else { return raw }
        return "\(date) \(time) \(pid) \(tid) \(level.rawValue) \(tag): \(message)"
    }

    public init(id: UInt64, date: String, time: String, pid: String, tid: String, level: LogLevel, tag: String, message: String, raw: String) {
        self.id = id; self.date = date; self.time = time; self.pid = pid; self.tid = tid
        self.level = level; self.tag = tag; self.message = message; self.raw = raw
    }
}

public struct LogParser {
    private static let pattern = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}|\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2}\.\d+)\s+(\d+)\s+(\d+)\s+([VDIWEFA])\s+(.+?)\s*:\s?(.*)$"#)
    public static func parse(_ line: String, id: UInt64) -> LogEntry? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pattern.firstMatch(in: line, range: range) else { return nil }
        func field(_ n: Int) -> String { Range(match.range(at: n), in: line).map { String(line[$0]) } ?? "" }
        let level = field(5) == "A" ? LogLevel.fatal : LogLevel(rawValue: field(5)) ?? .verbose
        return LogEntry(id: id, date: field(1), time: field(2), pid: field(3), tid: field(4), level: level, tag: field(6).trimmingCharacters(in: .whitespaces), message: field(7), raw: line)
    }
}

/// Keeps partial UTF-8 bytes until a complete line arrives from the process pipe.
public struct LineFramer {
    private var pending = Data()
    public init() {}
    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let end = pending.firstIndex(of: 10) {
            let bytes = pending[..<end]
            lines.append(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines))
            pending.removeSubrange(...end)
        }
        // Android log records are much smaller; cap malformed input without growing forever.
        if pending.count > 1_048_576 { pending.removeAll(keepingCapacity: true) }
        return lines
    }
    public mutating func finish() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

public struct LogFilter {
    public var minimum: LogLevel
    public var query: String
    public var tag: String
    public var regex: Bool
    public init(minimum: LogLevel = .verbose, query: String = "", tag: String = "", regex: Bool = false) {
        self.minimum = minimum; self.query = query; self.tag = tag; self.regex = regex
    }
    public func apply(to entries: [LogEntry]) throws -> [LogEntry] {
        let expression = regex && !query.isEmpty ? try NSRegularExpression(pattern: query, options: [.caseInsensitive]) : nil
        // Prepare once per filter pass, not once per log line. Empty segments must not match every line.
        let keywords = regex ? [] : Self.segments(query)
        let tags = Self.segments(tag)
        if minimum == .verbose && expression == nil && keywords.isEmpty && tags.isEmpty { return entries }
        return entries.filter { entry in
            let searchable = entry.mergedParts > 1 ? entry.raw + "\n" + entry.message : entry.raw
            guard entry.level.rank >= minimum.rank else { return false }
            guard tags.isEmpty || tags.contains(where: { entry.tag.localizedCaseInsensitiveContains($0) }) else { return false }
            if let expression = expression {
                return expression.firstMatch(in: searchable, range: NSRange(searchable.startIndex..., in: searchable)) != nil
            }
            return keywords.isEmpty || keywords.contains { searchable.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func segments(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: "|").compactMap { part in
            let keyword = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty, seen.insert(keyword).inserted else { return nil }
            return keyword
        }
    }
}

public struct AndroidDevice: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let state: String
    public var ready: Bool { state == "device" }
    public static func parse(_ output: String) -> [AndroidDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, ["device", "offline", "unauthorized", "recovery"].contains(fields[1]) else { return nil }
            let model = fields.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return AndroidDevice(id: fields[0], name: model ?? fields[0], state: fields[1])
        }
    }
}

public struct AndroidPackage: Identifiable, Equatable {
    public let id: String
    public let uid: String
    public init(id: String, uid: String) { self.id = id; self.uid = uid }
    public var shortName: String { id.split(separator: ".").suffix(2).joined(separator: ".") }
    public static func parse(_ output: String) -> [AndroidPackage] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let name = fields.first, name.hasPrefix("package:"),
                  let uidField = fields.first(where: { $0.hasPrefix("uid:") }) else { return nil }
            let id = String(name.dropFirst(8)), uid = String(uidField.dropFirst(4))
            guard !id.isEmpty, !uid.isEmpty, uid.allSatisfy(\.isNumber), seen.insert(id).inserted else { return nil }
            return AndroidPackage(id: id, uid: uid)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

public struct LogBuffer {
    public private(set) var entries: [LogEntry] = []
    public private(set) var evicted = 0
    public let limit: Int?
    public init(limit: Int? = nil) { self.limit = limit.map { max(1, $0) } }
    /// The unchanged prefix survives appends and cross-batch chunk merges.
    @discardableResult public mutating func append(_ batch: [LogEntry]) -> Int {
        var changedFrom = entries.count
        for entry in batch {
            entries.append(entry)
            LogChunkMerger.mergeTail(&entries)
            changedFrom = min(changedFrom, entries.count - 1)
        }
        if let limit, entries.count > limit {
            let excess = entries.count - limit
            entries.removeFirst(excess); evicted += excess
            changedFrom = 0
        }
        return changedFrom
    }
    public mutating func clear() { entries.removeAll(keepingCapacity: true); evicted = 0 }
}
