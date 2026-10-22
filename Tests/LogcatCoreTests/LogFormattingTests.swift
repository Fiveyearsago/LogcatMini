import XCTest
@testable import LogcatCore

final class LogFormattingTests: XCTestCase {
    func testAndroidMapFromScreenshot() throws {
        let input = "onEvent(): lc_api_request, info = {endpoint=/incentive/v1/task/config, result=success, duration_ms=131, http_code=200}"
        let result = try XCTUnwrap(LogFormattedDocument.parse(input))
        XCTAssertEqual(result.style, .keyValue)
        XCTAssertEqual(result.text, """
        onEvent(): lc_api_request,
        info = {
          endpoint=/incentive/v1/task/config,
          result=success,
          duration_ms=131,
          http_code=200
        }
        """)
        XCTAssertEqual(withoutWhitespace(result.text), withoutWhitespace(input))
    }

    func testNestedObjectsListsAndDuplicateKeysKeepOrderAndValues() throws {
        let input = #"event=done data=User(name="张三, key=fake", children=[Child(id=1, active=true), Child(id=2, active=false)]) id=3 id=4"#
        let result = try XCTUnwrap(LogFormattedDocument.parse(input))
        XCTAssertEqual(result.style, .keyValue)
        XCTAssertTrue(result.text.contains("\n  children=[Child(\n      id=1,"))
        XCTAssertTrue(result.text.contains(#"name="张三, key=fake""#))
        XCTAssertTrue(result.text.hasSuffix("id=3\nid=4"))
        XCTAssertEqual(withoutWhitespace(result.text), withoutWhitespace(input))
    }

    func testQuotedValuesURLsTimesAndBase64StayIntact() throws {
        let input = #"request url=https://[::1]:8443/a(b)?x=a,b=c&sign=abc==#node key=next time=15:25:26.889 ip=127.0.0.1:443 token=YWJjZA== msg="hello  world, a=b \"quoted\"" end=true"#
        let result = try XCTUnwrap(LogKeyValueFormatter.format(input))
        XCTAssertTrue(result.contains("url=https://[::1]:8443/a(b)?x=a,b=c&sign=abc==#node\nkey=next"))
        XCTAssertTrue(result.contains("time=15:25:26.889\nip=127.0.0.1:443\ntoken=YWJjZA=="))
        XCTAssertTrue(result.contains(#"msg="hello  world, a=b \"quoted\"""#))
        XCTAssertEqual(withoutWhitespace(result), withoutWhitespace(input))
    }

    func testColonHashAndSemicolonFields() throws {
        let input = "Beyla Event = eventType:0#eventName:lc_api_request#result:success; duration:544"
        let output = try XCTUnwrap(LogKeyValueFormatter.format(input))
        XCTAssertTrue(output.contains("\neventType:0#\neventName:lc_api_request#\nresult:success;\nduration:544"))
        XCTAssertEqual(withoutWhitespace(output), withoutWhitespace(input))
        let quoted = try XCTUnwrap(LogKeyValueFormatter.format("{'姓名': '小明', 'count': 3}"))
        XCTAssertTrue(quoted.contains("\n  '姓名': '小明',\n  'count': 3\n}"))
    }

    func testJSONRetainsTreeAndExactTokens() throws {
        let input = #"response={"large":12345678901234567890,"nested":{"ok":true},"items":[1,2]} elapsed=12"#
        let result = try XCTUnwrap(LogFormattedDocument.parse(input))
        XCTAssertEqual(result.style, .json)
        let json = try XCTUnwrap(result.json)
        XCTAssertEqual(json.fragments[0].root.children[0].value, "12345678901234567890")
        XCTAssertEqual(json.fragments[0].prefix, "response=")
        XCTAssertEqual(json.suffix, "elapsed=12")
        XCTAssertGreaterThan(json.containerIDs.count, 1)
    }

    func testPlainOrMalformedTextIsPreservedWithoutInventingStructure() throws {
        for input in ["hello world\n\tat Example.kt:42\n\tat foo.bar(Baz.java:23)", "https://host/path?a=1&b=2", "15:26:60.123", "cacheData == null", #"data={a=1, msg="unterminated"#] {
            let result = try XCTUnwrap(LogFormattedDocument.parse(input))
            XCTAssertEqual(result.style, .text, input)
            XCTAssertEqual(result.text, input)
        }
    }

    func testResourceLimitsFallBackSafely() {
        XCTAssertNil(LogFormattedDocument.parse(String(repeating: "a", count: 2 * 1024 * 1024 + 1)))
        let deep = String(repeating: "{", count: 129) + "a=1" + String(repeating: "}", count: 129)
        XCTAssertEqual(LogFormattedDocument.parse(deep)?.text, deep)
        let many = (0..<20_001).map { "key\($0)=1" }.joined(separator: " ")
        XCTAssertEqual(LogFormattedDocument.parse(many)?.style, .text)
    }

    private func withoutWhitespace(_ value: String) -> String {
        String(value.filter { !$0.isWhitespace })
    }
}
