import Foundation

public struct LogJSONNode: Identifiable, Sendable {
    public enum Kind: Sendable { case object, array, string, number, literal }
    public let id: Int
    /// JSON-quoted object key, or an array index such as [0].
    public let key: String?
    public let kind: Kind
    public let value: String
    public let children: [LogJSONNode]
    public var isContainer: Bool { kind == .object || kind == .array }
    public var opening: String { kind == .object ? "{" : "[" }
    public var closing: String { kind == .object ? "}" : "]" }
}

public struct LogJSONFragment: Identifiable, Sendable {
    public var id: Int { root.id }
    public let prefix: String
    public let root: LogJSONNode
}

public struct LogJSONDocument: Sendable {
    public let fragments: [LogJSONFragment]
    public let suffix: String
    public var containerIDs: Set<Int> {
        var ids = Set<Int>()
        func visit(_ node: LogJSONNode) {
            if node.isContainer { ids.insert(node.id) }
            node.children.forEach(visit)
        }
        fragments.forEach { visit($0.root) }
        return ids
    }

    /// Extract complete containers while retaining surrounding log text, key order and exact number tokens.
    /// Limits apply only to the tree preview; the original log is always available.
    public static func parse(_ text: String) -> Self? {
        guard text.utf8.count <= 2 * 1_024 * 1_024 else { return nil }
        let bytes = Array(text.utf8)
        var index = 0, previousEnd = 0, nextID = 0
        var fragments: [LogJSONFragment] = []
        while index < bytes.count {
            guard bytes[index] == 123 || bytes[index] == 91 else { index += 1; continue }
            let start = index
            guard let end = containerEnd(bytes, from: start) else { break }
            index = end
            let data = Data(bytes[start..<end])
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else { continue }
            var parser = TreeParser(bytes: bytes, index: start, nextID: nextID)
            guard let root = parser.node(key: nil, depth: 0), parser.index == end else { return nil }
            nextID = parser.nextID
            fragments.append(LogJSONFragment(prefix: String(decoding: bytes[previousEnd..<start], as: UTF8.self), root: root))
            previousEnd = end
        }
        guard !fragments.isEmpty else { return nil }
        return Self(fragments: fragments, suffix: String(decoding: bytes[previousEnd...], as: UTF8.self))
    }

    private static func containerEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var stack: [UInt8] = [], inString = false, escaped = false
        for i in start..<bytes.count {
            let c = bytes[i]
            if inString {
                if escaped { escaped = false }
                else if c == 92 { escaped = true }
                else if c == 34 { inString = false }
                continue
            }
            if c == 34 { inString = true }
            else if c == 123 || c == 91 { stack.append(c) }
            else if c == 125 || c == 93 {
                guard let opening = stack.last, (opening == 123 && c == 125) || (opening == 91 && c == 93) else { return i + 1 }
                stack.removeLast()
                if stack.isEmpty { return i + 1 }
            }
        }
        return nil
    }
}

/// Input is validated by Foundation first; this pass preserves tokens instead of rounding large numbers.
private struct TreeParser {
    let bytes: [UInt8]
    var index: Int
    var nextID: Int
    mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    mutating func stringToken() -> String {
        let start = index
        index += 1
        while index < bytes.count {
            let c = bytes[index]; index += 1
            if c == 92 { index += 1 }
            else if c == 34 { break }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
    mutating func node(key: String?, depth: Int) -> LogJSONNode? {
        guard depth <= 128, nextID < 20_000 else { return nil }
        whitespace()
        guard index < bytes.count else { return nil }
        let id = nextID; nextID += 1
        let first = bytes[index]
        if first == 123 || first == 91 {
            let object = first == 123, close: UInt8 = first == 123 ? 125 : 93
            index += 1; whitespace()
            var children: [LogJSONNode] = []
            guard index < bytes.count else { return nil }
            while bytes[index] != close {
                let childKey: String
                if object {
                    guard bytes[index] == 34 else { return nil }
                    childKey = stringToken(); whitespace()
                    guard index < bytes.count, bytes[index] == 58 else { return nil }
                    index += 1
                } else { childKey = "[\(children.count)]" }
                guard let child = node(key: childKey, depth: depth + 1) else { return nil }
                children.append(child); whitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == close { break }
                guard bytes[index] == 44 else { return nil }
                index += 1; whitespace()
                guard index < bytes.count, bytes[index] != close else { return nil }
            }
            index += 1
            return LogJSONNode(id: id, key: key, kind: object ? .object : .array, value: "", children: children)
        }
        let value: String, kind: LogJSONNode.Kind
        if first == 34 { value = stringToken(); kind = .string }
        else {
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            value = String(decoding: bytes[start..<index], as: UTF8.self)
            kind = first == 45 || (48...57).contains(first) ? .number : .literal
        }
        return LogJSONNode(id: id, key: key, kind: kind, value: value, children: [])
    }
}

public struct LogJSONTreeRow: Identifiable {
    public var id: Int { node.id * 2 + (isClosing ? 1 : 0) }
    public let node: LogJSONNode
    public let depth: Int
    public let isClosing: Bool
    public static func visible(root: LogJSONNode, expanded: Set<Int>) -> [Self] {
        var rows: [Self] = []
        func append(_ node: LogJSONNode, _ depth: Int) {
            rows.append(Self(node: node, depth: depth, isClosing: false))
            if !node.children.isEmpty && expanded.contains(node.id) {
                node.children.forEach { append($0, depth + 1) }
                rows.append(Self(node: node, depth: depth, isClosing: true))
            }
        }
        append(root, 0)
        return rows
    }
}
