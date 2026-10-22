import Foundation

/// Finds complete s values without requiring an HTTP method, URL or request body.
public enum LogSExtractor {
    private static let jsonField = try! NSRegularExpression(pattern: #"(?<!\\)"s"\s*:\s*("(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*")"#)
    private static let assignment = try! NSRegularExpression(pattern: #"(?:^|[\s?&;,])s=(?:"([A-Za-z0-9+/%=_-]+)"|'([A-Za-z0-9+/%=_-]+)'|([A-Za-z0-9+/%=_-]+)(?=$|[\s&#;,})\]]))"#)

    public static func values(in text: String) -> [String] {
        guard text.utf8.count <= 2 * 1_024 * 1_024 else { return [] }
        var result: [String] = [], seen = Set<String>()
        func add(_ value: String?) {
            guard let value, !value.isEmpty, result.count < 64, seen.insert(value).inserted else { return }
            result.append(value)
        }
        func decode(_ token: String) -> String? {
            try? JSONSerialization.jsonObject(with: Data(token.utf8), options: [.fragmentsAllowed]) as? String
        }
        func plain(_ text: String) {
            let range = NSRange(text.startIndex..., in: text)
            // A complete quoted value can be extracted even when surrounding log JSON is incomplete.
            for match in jsonField.matches(in: text, range: range) {
                add(decode((text as NSString).substring(with: match.range(at: 1))))
            }
            for match in assignment.matches(in: text, range: range) {
                for index in 1...3 where match.range(at: index).location != NSNotFound {
                    let value = (text as NSString).substring(with: match.range(at: index))
                    // A literal + in Base64 must never become a space.
                    add(value.removingPercentEncoding)
                }
            }
        }
        func visit(_ node: LogJSONNode) {
            if let key = node.key, decode(key) == "s", node.kind == .string { add(decode(node.value)) }
            node.children.forEach(visit)
        }
        if let document = LogJSONDocument.parse(text) {
            for fragment in document.fragments { plain(fragment.prefix); visit(fragment.root) }
            plain(document.suffix)
        } else { plain(text) }
        return result
    }
}
