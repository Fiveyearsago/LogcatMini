import Foundation

public struct LogJSONTextLine: Sendable {
    public let id: String
    public let range: NSRange
    public let containerID: Int?
    public let expanded: Bool
    public let label: String
}

/// One continuous document for native text selection. Array indexes are navigation metadata,
/// not JSON keys; commas and original scalar tokens are retained in the formatted output.
public struct LogJSONTextLayout: Sendable {
    public let text: String
    public let lines: [LogJSONTextLine]
}

extension LogJSONDocument {
    public func textLayout(expanded: Set<Int>) -> LogJSONTextLayout {
        var text = "", lines: [LogJSONTextLine] = [], offset = 0
        func append(_ value: String, id: String, containerID: Int? = nil, open: Bool = false, label: String = "") {
            if !text.isEmpty { text += "\n"; offset += 1 }
            let length = value.utf16.count
            lines.append(LogJSONTextLine(id: id, range: NSRange(location: offset, length: length),
                                        containerID: containerID, expanded: open, label: label))
            text += value; offset += length
        }
        func node(_ value: LogJSONNode, depth: Int, objectMember: Bool, comma: Bool) {
            let indent = String(repeating: "  ", count: depth)
            let key = objectMember ? (value.key.map { $0 + ": " } ?? "") : ""
            let suffix = comma ? "," : ""
            let expandable = !value.children.isEmpty
            let open = expandable && expanded.contains(value.id)
            let body: String
            if value.isContainer {
                body = expandable ? (open ? value.opening : value.opening + " … " + value.closing) : value.opening + value.closing
            } else { body = value.value }
            append(indent + key + body + (open ? "" : suffix), id: "node:\(value.id)",
                   containerID: expandable ? value.id : nil, open: open, label: value.key ?? "JSON")
            if open {
                for (index, child) in value.children.enumerated() {
                    node(child, depth: depth + 1, objectMember: value.kind == .object, comma: index < value.children.count - 1)
                }
                append(indent + value.closing + suffix, id: "close:\(value.id)")
            }
        }
        for fragment in fragments {
            let prefix = fragment.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { append(prefix, id: "prefix:\(fragment.id)") }
            node(fragment.root, depth: 0, objectMember: false, comma: false)
        }
        let tail = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { append(tail, id: "suffix") }
        return LogJSONTextLayout(text: text, lines: lines)
    }
    public var formattedText: String { textLayout(expanded: containerIDs).text }
}
