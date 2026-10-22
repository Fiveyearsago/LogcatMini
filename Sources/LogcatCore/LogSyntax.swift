import Foundation

public enum LogTokenKind: CaseIterable {
    case key, string, number, literal, url
}

public struct LogToken: Equatable {
    public let range: NSRange
    public let kind: LogTokenKind
}

/// Presentation-only lexer: ranges reference the original UTF-16 text, which is never rewritten.
public enum LogSyntax {
    private static let expression = try! NSRegularExpression(pattern: #"(?<url>\bhttps?://[^\s<>"'\\]+)|(?<quoted>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?<key>\b[A-Za-z_][A-Za-z0-9_.-]*(?=\s*=))|(?<literal>\b(?:true|false|null|nil)\b)|(?<number>(?<![\p{L}\p{N}_./-])-?(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(?![\p{L}\p{N}_./-]))"#)

    public static func tokens(in text: String) -> [LogToken] {
        let source = text as NSString
        var result: [LogToken] = []
        // Bound work for unusually large payloads; the rest still displays and copies verbatim.
        let limit = min(source.length, 16_384)
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: limit)) { match, _, stop in
            guard let match = match else { return }
            let kind: LogTokenKind
            if match.range(withName: "url").location != NSNotFound { kind = .url }
            else if match.range(withName: "quoted").location != NSNotFound {
                var end = NSMaxRange(match.range)
                while end < limit && [9, 10, 13, 32].contains(source.character(at: end)) { end += 1 }
                if end < limit && [58, 61].contains(source.character(at: end)) { kind = .key }
                else {
                    let value = source.substring(with: match.range).dropFirst().dropLast()
                    kind = value.hasPrefix("https://") || value.hasPrefix("http://") ? .url : .string
                }
            } else if match.range(withName: "key").location != NSNotFound { kind = .key }
            else if match.range(withName: "literal").location != NSNotFound { kind = .literal }
            else { kind = .number }
            result.append(LogToken(range: match.range, kind: kind))
            if result.count >= 512 { stop.pointee = true }
        }
        return result
    }

    /// Keep a tag family in one color across rows, refreshes and app launches.
    public static func tagColorIndex(_ tag: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let family = tag.split(separator: ".").prefix(2).joined(separator: ".")
            .split(separator: "_").first.map(String.init) ?? tag
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in family.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(count))
    }
}
