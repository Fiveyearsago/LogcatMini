import XCTest
@testable import LogcatCore

final class LogSearchTests: XCTestCase {
    func testLiteralCaseInsensitiveMatchesUseUTF16Offsets() {
        let text = "🙂请求 OK|a / ok|A / 结束"
        let ranges = LogSearch.ranges(in: text, query: "ok|a")
        XCTAssertEqual(ranges, [NSRange(location: 5, length: 4), NSRange(location: 12, length: 4)])
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0).lowercased() }, ["ok|a", "ok|a"])
        XCTAssertTrue(LogSearch.ranges(in: text, query: "").isEmpty)
        XCTAssertTrue(LogSearch.ranges(in: text, query: "unknown").isEmpty)
        XCTAssertEqual(LogSearch.ranges(in: "aaaa", query: "aa"), [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }
    func testFindsCollapsedJSONDescendantsAndTheirAncestorPath() throws {
        let document = try XCTUnwrap(LogJSONDocument.parse(#"result={"outer":{"items":[{"name":"TARGET🙂"},{"name":"Other"}]},"targetKey":false}"#))
        let hits = LogSearch.jsonHits(in: document, query: "target")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].ancestors.count, 4)
        XCTAssertEqual(hits[1].ancestors, [document.fragments[0].root.id])
        let collapsed = LogJSONTreeRow.visible(root: document.fragments[0].root, expanded: [])
        XCTAssertFalse(collapsed.contains { $0.node.id == hits[0].nodeID })
        let revealed = LogJSONTreeRow.visible(root: document.fragments[0].root, expanded: hits[0].ancestors)
        XCTAssertTrue(revealed.contains { $0.node.id == hits[0].nodeID })
    }
}
