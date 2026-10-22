import Foundation

public enum LogSearch {
    /// Non-overlapping, case-insensitive literal matches, expressed in UTF-16 for AppKit.
    public static func ranges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let value = text as NSString
        var result: [NSRange] = [], start = 0
        while start < value.length {
            let range = value.range(of: query, options: [.caseInsensitive], range: NSRange(location: start, length: value.length - start))
            guard range.location != NSNotFound, range.length > 0 else { break }
            result.append(range); start = NSMaxRange(range)
        }
        return result
    }
    public struct JSONHit: Equatable {
        public let nodeID: Int
        public let ancestors: Set<Int>
    }
    public static func jsonHits(in document: LogJSONDocument, query: String) -> [JSONHit] {
        guard !query.isEmpty else { return [] }
        var hits: [JSONHit] = []
        func visit(_ node: LogJSONNode, ancestors: Set<Int>) {
            if !(ranges(in: (node.key ?? "") + ": " + node.value, query: query)).isEmpty {
                hits.append(JSONHit(nodeID: node.id, ancestors: ancestors))
            }
            node.children.forEach { visit($0, ancestors: ancestors.union([node.id])) }
        }
        document.fragments.forEach { visit($0.root, ancestors: []) }
        return hits
    }
}
