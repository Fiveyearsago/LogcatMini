import Foundation

/// Source records stay untouched; details can display and copy the formatted representation.
public struct LogFormattedDocument: Sendable {
    public enum Style: Sendable { case json, keyValue, text }
    public let style: Style
    public let json: LogJSONDocument?
    public let text: String

    public static func parse(_ message: String) -> Self? {
        guard message.utf8.count <= 2 * 1_024 * 1_024 else { return nil }
        if let json = LogJSONDocument.parse(message) {
            let formatted = LogJSONDocument(fragments: json.fragments.map {
                LogJSONFragment(prefix: LogKeyValueFormatter.format($0.prefix) ?? $0.prefix, root: $0.root)
            }, suffix: LogKeyValueFormatter.format(json.suffix) ?? json.suffix)
            return Self(style: .json, json: formatted, text: formatted.formattedText)
        }
        if let formatted = LogKeyValueFormatter.format(message) {
            return Self(style: .keyValue, json: nil, text: formatted)
        }
        return Self(style: .text, json: nil, text: message)
    }
}

/// Whitespace-only layout for logfmt, Android Map/toString and colon-separated fields.
/// Unlike splitting on commas, a lexical scan protects quoted values, URLs and nested groups.
public enum LogKeyValueFormatter {
    public static func format(_ text: String) -> String? {
        guard text.utf8.count <= 2 * 1_024 * 1_024 else { return nil }
        var scanner = Scanner(bytes: Array(text.utf8))
        return scanner.format()
    }
}

private struct Scanner {
    struct Group { let opening: UInt8; var close: Int?; let ancestors: [Int] }
    struct Field { let start: Int; let ancestors: [Int] }
    let bytes: [UInt8]
    var groups: [Group] = []
    var stack: [Int] = []
    var fields: [Field] = []

    func space(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
    func boundary(_ i: Int) -> Bool {
        i == 0 || space(bytes[i - 1]) || [44, 59, 35, 123, 91, 40].contains(bytes[i - 1])
    }
    func keyStart(_ c: UInt8) -> Bool { c == 95 || (65...90).contains(c) || (97...122).contains(c) || c >= 128 }
    func keyBody(_ c: UInt8) -> Bool { keyStart(c) || (48...57).contains(c) || c == 46 || c == 45 }
    func quotedEnd(_ start: Int) -> Int? {
        let quote = bytes[start]
        var i = start + 1
        while i < bytes.count {
            if bytes[i] == 92 { i += 2; continue }
            if bytes[i] == quote { return i + 1 }
            i += 1
        }
        return nil
    }
    func fieldEnd(_ start: Int) -> Int? {
        var i = start
        if bytes[i] == 34 || bytes[i] == 39 {
            guard let end = quotedEnd(i), end > i + 2 else { return nil }
            i = end
        } else {
            guard keyStart(bytes[i]) else { return nil }
            while i < bytes.count && keyBody(bytes[i]) { i += 1 }
        }
        while i < bytes.count && space(bytes[i]) { i += 1 }
        guard i < bytes.count, bytes[i] == 61 || bytes[i] == 58 else { return nil }
        if bytes[i] == 58, i + 1 < bytes.count, (48...57).contains(bytes[i + 1]) {
            let key = String(decoding: bytes[start..<i], as: UTF8.self)
            // Preserve source locations inside stack traces, e.g. Example.kt:42.
            if [".kt", ".java", ".swift", ".m", ".mm", ".c", ".cpp", ".h", ".cs", ".py", ".js", ".ts"].contains(where: { key.hasSuffix($0) }) { return nil }
        }
        // Comparisons, URL schemes and namespace separators are not field assignments.
        if i + 1 < bytes.count {
            if bytes[i + 1] == 61 { return nil }
            if bytes[i] == 58 && [58, 47].contains(bytes[i + 1]) { return nil }
            if bytes[i] == 58 && i == start + 1 && bytes[i + 1] == 92 { return nil }
        }
        return i + 1
    }
    func urlEnd(_ start: Int) -> Int? {
        // Recognize schemes instead of treating query parameters or URL fragments as fields.
        guard keyStart(bytes[start]), start == 0 || !keyBody(bytes[start - 1]) else { return nil }
        var i = start
        while i < bytes.count && (keyBody(bytes[i]) || bytes[i] == 43) { i += 1 }
        guard i + 2 < bytes.count, bytes[i] == 58, bytes[i + 1] == 47, bytes[i + 2] == 47 else { return nil }
        i += 3
        var nested: [UInt8] = []
        while i < bytes.count && !space(bytes[i]) && ![34, 39].contains(bytes[i]) {
            let c = bytes[i]
            if [123, 91, 40].contains(c) { nested.append(c) }
            if [125, 93, 41].contains(c) {
                guard let last = nested.last,
                      (last == 123 && c == 125) || (last == 91 && c == 93) || (last == 40 && c == 41) else { break }
                nested.removeLast()
            }
            i += 1
        }
        return i
    }
    mutating func format() -> String? {
        var i = 0
        while i < bytes.count {
            if let end = urlEnd(i) { i = end; continue }
            if boundary(i), let end = fieldEnd(i) {
                guard fields.count < 20_000 else { return nil }
                fields.append(Field(start: i, ancestors: stack)); i = end; continue
            }
            let c = bytes[i]
            if (c == 34 || c == 39), boundary(i) || i > 0 && [61, 58].contains(bytes[i - 1]) {
                guard let end = quotedEnd(i) else { return nil }
                i = end; continue
            }
            if [123, 91, 40].contains(c) {
                guard stack.count < 128, groups.count < 20_000 else { return nil }
                groups.append(Group(opening: c, close: nil, ancestors: stack)); stack.append(groups.count - 1)
            } else if [125, 93, 41].contains(c), let last = stack.last {
                guard (groups[last].opening == 123 && c == 125) || (groups[last].opening == 91 && c == 93) || (groups[last].opening == 40 && c == 41) else { return nil }
                groups[last].close = i; stack.removeLast()
            }
            i += 1
        }
        guard stack.isEmpty, !fields.isEmpty else { return nil }
        let active = Set(fields.flatMap(\.ancestors))
        var breaks = fields.map { (index: $0.start, depth: $0.ancestors.count) }
        for id in active {
            if let end = groups[id].close { breaks.append((end, groups[id].ancestors.count)) }
        }
        breaks.sort { $0.index < $1.index }
        var result = "", previous = 0
        for point in breaks {
            result += String(decoding: bytes[previous..<point.index], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty { result += "\n" }
            result += String(repeating: "  ", count: point.depth)
            previous = point.index
        }
        result += String(decoding: bytes[previous...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
