import XCTest
@testable import LogcatCore

final class LogSyntaxTests: XCTestCase {
    private func values(_ text: String) -> [(String, LogTokenKind)] {
        LogSyntax.tokens(in: text).map { ((text as NSString).substring(with: $0.range), $0.kind) }
    }
    func testJSONAndKeyValueTokensPreserveUnicodeAndEscapes() {
        let text = #"收到🔋 {"状态":"成功","message":"say \"hello\" 250 true","coins":-2.5e+3,"cached":false} retry=1 cache=null"#
        let tokens = values(text)
        XCTAssertEqual(tokens.map(\.0), [#""状态""#, #""成功""#, #""message""#, #""say \"hello\" 250 true""#, #""coins""#, "-2.5e+3", #""cached""#, "false", "retry", "1", "cache", "null"])
        XCTAssertEqual(tokens.map(\.1), [.key, .string, .key, .string, .key, .number, .key, .literal, .key, .number, .key, .literal])
        for token in LogSyntax.tokens(in: text) { XCTAssertNotNil(Range(token.range, in: text)) }
    }
    func testURLsAndQuotedValuesAreNotSplitIntoNestedTokens() {
        let text = #"GET https://api.example.com/v2/reward?id=250&cached=false {"url":"https://example.com/42"} source='daily_task'"#
        let tokens = values(text)
        XCTAssertEqual(tokens.map(\.0), ["https://api.example.com/v2/reward?id=250&cached=false", #""url""#, #""https://example.com/42""#, "source", "'daily_task'"])
        XCTAssertEqual(tokens.map(\.1), [.url, .key, .url, .key, .string])
    }
    func testNumbersDoNotColorPartsOfIdentifiers() {
        let tokens = values("PJD110 abc123 deadbeef42 0x2A 16.7 ms -12 nil true")
        XCTAssertEqual(tokens.map(\.0), ["0x2A", "16.7", "-12", "nil", "true"])
        XCTAssertEqual(tokens.map(\.1), [.number, .number, .number, .literal, .literal])
    }
    func testLargeOrIncompletePayloadHasBoundedValidRanges() {
        let text = String(repeating: "🔋中文 123 ", count: 10_000) + #" {"unfinished":"#
        let tokens = LogSyntax.tokens(in: text)
        XCTAssertLessThanOrEqual(tokens.count, 512)
        for token in tokens {
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), 16_384)
            XCTAssertNotNil(Range(token.range, in: text))
        }
        XCTAssertTrue(LogSyntax.tokens(in: "plain text without structured values").isEmpty)
    }
    func testTagFamiliesUseStableColors() {
        let count = 5
        XCTAssertEqual(LogSyntax.tagColorIndex("MD.Network.Request", count: count), LogSyntax.tagColorIndex("MD.Network.Response", count: count))
        XCTAssertEqual(LogSyntax.tagColorIndex("MD.CFG_CacheManager", count: count), LogSyntax.tagColorIndex("MD.CFG_CacheABInfo", count: count))
        for tag in ["", "MD.Network", "中文🔋", "Cache", "com.example.api"] {
            XCTAssertTrue((0..<count).contains(LogSyntax.tagColorIndex(tag, count: count)))
        }
    }
}
