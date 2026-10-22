import XCTest
@testable import LogcatCore

final class LogJSONTests: XCTestCase {
    func testExtractsNestedPayloadAndRetainsContextAndExactNumbers() throws {
        let input = #"response body {"id":123456789012345678901234567890,"data":{"items":[true,null,{},[]]},"amount":1.2300e-7} trailing text"#
        let doc = try XCTUnwrap(LogJSONDocument.parse(input))
        let root = try XCTUnwrap(doc.fragments.first?.root)
        XCTAssertEqual(doc.fragments.first?.prefix, "response body ")
        XCTAssertEqual(doc.suffix, " trailing text")
        XCTAssertEqual(root.children.map(\.key), ["\"id\"", "\"data\"", "\"amount\""])
        XCTAssertEqual(root.children[0].value, "123456789012345678901234567890")
        XCTAssertEqual(root.children[2].value, "1.2300e-7")
        let items = root.children[1].children[0].children
        XCTAssertEqual(items.map(\.key), ["[0]", "[1]", "[2]", "[3]"])
        XCTAssertEqual(items[0].kind, .literal)
        XCTAssertEqual(items[1].value, "null")
        XCTAssertEqual(items[2].kind, .object)
        XCTAssertEqual(items[3].kind, .array)
    }
    func testStringsContainEscapedQuotesBackslashesBracesAndUnicode() throws {
        let input = #"prefix [INFO] {"文本":"中文😀 } [ \"quoted\" \\ end","escaped":"\u4e2d\nline"}"#
        let doc = try XCTUnwrap(LogJSONDocument.parse(input))
        XCTAssertEqual(doc.fragments.count, 1)
        XCTAssertEqual(doc.fragments[0].prefix, "prefix [INFO] ")
        XCTAssertEqual(doc.fragments[0].root.children[0].value, #""中文😀 } [ \"quoted\" \\ end""#)
        XCTAssertEqual(doc.fragments[0].root.children[1].value, #""\u4e2d\nline""#)
    }
    func testMultipleContainersHaveUniqueIDsAndPreserveSeparators() throws {
        let doc = try XCTUnwrap(LogJSONDocument.parse(#"a={"ok":true} b=[{"x":1},2] done"#))
        XCTAssertEqual(doc.fragments.count, 2)
        XCTAssertEqual(doc.fragments[1].prefix, " b=")
        XCTAssertEqual(doc.suffix, " done")
        let rows = doc.fragments.flatMap { LogJSONTreeRow.visible(root: $0.root, expanded: doc.containerIDs) }
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
    func testMalformedTruncatedAndPlainTextDoNotBecomeJSON() {
        for input in ["ordinary text", "false", "123", #"{"a":1"#, #"{"a":1,}"#, "[1,2,]", #"{"a":"unterminated}"#, #"[1,2}"#] {
            XCTAssertNil(LogJSONDocument.parse(input), input)
        }
        XCTAssertNotNil(LogJSONDocument.parse(#"{not JSON} payload={"ok":true}"#))
    }
    func testCollapseOnlyChangesVisibleNodes() throws {
        let doc = try XCTUnwrap(LogJSONDocument.parse(#"{"data":{"items":[1,2]},"code":200}"#))
        let root = doc.fragments[0].root, data = root.children[0]
        XCTAssertEqual(LogJSONTreeRow.visible(root: root, expanded: []).count, 1)
        let firstLevel = LogJSONTreeRow.visible(root: root, expanded: [root.id])
        XCTAssertEqual(firstLevel.count, 4)
        XCTAssertTrue(firstLevel.last!.isClosing)
        XCTAssertFalse(firstLevel.contains { $0.node.key == "\"items\"" })
        let expanded = LogJSONTreeRow.visible(root: root, expanded: [root.id, data.id])
        XCTAssertTrue(expanded.contains { $0.node.key == "\"items\"" })
        XCTAssertFalse(expanded.contains { $0.node.key == "[0]" })
        XCTAssertTrue(LogJSONTreeRow.visible(root: root, expanded: doc.containerIDs).contains { $0.node.value == "2" })
    }
    func testPreviewLimitsRejectExcessiveDepthOrNodesWithoutMutatingInput() {
        let nested = String(repeating: "[", count: 140) + "0" + String(repeating: "]", count: 140)
        XCTAssertNil(LogJSONDocument.parse(nested))
        let many = "[" + Array(repeating: "0", count: 20_001).joined(separator: ",") + "]"
        XCTAssertNil(LogJSONDocument.parse(many))
        let large = "{\"s\":\"" + String(repeating: "a", count: 2 * 1_024 * 1_024) + "\"}"
        XCTAssertNil(LogJSONDocument.parse(large))
    }
}
