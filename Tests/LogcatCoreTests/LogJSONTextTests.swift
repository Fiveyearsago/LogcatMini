import XCTest
@testable import LogcatCore

final class LogJSONTextTests: XCTestCase {
    func testFormattedCopyIsValidJSONWithCommasAndNoSyntheticArrayKeys() throws {
        let source = #"{"Accept":"application\/json","items":[{"id":1},true,null,[],{}],"ok":false}"#
        let formatted = try XCTUnwrap(LogFormattedDocument.parse(source))
        let expected = """
        {
          "Accept": "application\\/json",
          "items": [
            {
              "id": 1
            },
            true,
            null,
            [],
            {}
          ],
          "ok": false
        }
        """
        XCTAssertEqual(formatted.text, expected)
        let originalValue = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? NSDictionary
        let copiedValue = try JSONSerialization.jsonObject(with: Data(formatted.text.utf8)) as? NSDictionary
        XCTAssertEqual(originalValue, copiedValue)
        XCTAssertFalse(formatted.text.contains("[0]:"))
    }
    func testCopyRetainsExactNumbersEscapesOrderAndRepeatedKeys() throws {
        let source = #"{"id":123456789012345678901234567890,"rate":1.2300e-7,"name":"中文😀\n\"test\"","id":2}"#
        let doc = try XCTUnwrap(LogJSONDocument.parse(source))
        XCTAssertEqual(doc.formattedText, """
        {
          "id": 123456789012345678901234567890,
          "rate": 1.2300e-7,
          "name": "中文😀\\n\\"test\\"",
          "id": 2
        }
        """)
    }
    func testCollapsedDisplayAndFullCopyRemainIndependent() throws {
        let formatted = try XCTUnwrap(LogFormattedDocument.parse(#"result={"data":{"secret":"kept"},"code":200}"#))
        let doc = try XCTUnwrap(formatted.json)
        XCTAssertEqual(doc.textLayout(expanded: []).text, "result=\n{ … }")
        let rootOnly = doc.textLayout(expanded: [doc.fragments[0].root.id])
        XCTAssertTrue(rootOnly.text.contains("\"data\": { … },"))
        XCTAssertTrue(formatted.text.contains("\"secret\": \"kept\""))
        XCTAssertFalse(formatted.text.contains("…"))
        let output = try XCTUnwrap(LogJSONDocument.parse(formatted.text))
        XCTAssertEqual(output.fragments[0].root.children[0].children[0].value, "\"kept\"")
    }
    func testLineRangesAndSearchIDsRemainCorrectForUnicodeAndMultipleFragments() throws {
        let doc = try XCTUnwrap(LogJSONDocument.parse(#"中文😀 a={"x":"你好"} b=[1,2] end"#))
        let layout = doc.textLayout(expanded: doc.containerIDs)
        XCTAssertEqual(Set(layout.lines.map(\.id)).count, layout.lines.count)
        XCTAssertEqual(layout.lines.filter { $0.containerID != nil }.count, 2)
        for line in layout.lines {
            let text = (layout.text as NSString).substring(with: line.range)
            XCTAssertFalse(text.isEmpty)
            XCTAssertLessThanOrEqual(NSMaxRange(line.range), layout.text.utf16.count)
        }
        XCTAssertEqual((layout.text as NSString).substring(with: layout.lines[0].range), "中文😀 a=")
        XCTAssertTrue(layout.text.hasSuffix("]\nend"))
    }
}
