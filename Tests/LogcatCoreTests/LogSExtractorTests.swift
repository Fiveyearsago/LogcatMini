import XCTest
@testable import LogcatCore

final class LogSExtractorTests: XCTestCase {
    func testJSONAndKeyValueLogsDoNotRequireARequest() {
        XCTAssertEqual(LogSExtractor.values(in: #"stage=wire data={"s":"a+b\/c=","nested":{"\u0073":"second=="}}"#), ["a+b/c=", "second=="])
        XCTAssertEqual(LogSExtractor.values(in: "stage=wire s=a%2Bb%2Fc%3D status=done"), ["a+b/c="])
        XCTAssertEqual(LogSExtractor.values(in: "https://example.test/?q=1&s=a+b/c=&keep=1"), ["a+b/c="])
        XCTAssertEqual(LogSExtractor.values(in: "s=\"a+b/c=\""), ["a+b/c="])
        XCTAssertEqual(LogSExtractor.values(in: #"{"s":"complete==", "partial":"#), ["complete=="])
    }
    func testMissingTruncatedOrQuotedFakeFieldsAreNotExtracted() {
        for text in [#"{"s":"truncated"#, #"{"status":"ok","params":"s=fake=="}"#, #"{"message":"\"s\":\"fake==\""}"#, "params=fake==", "https://example.test/?xs=fake=="] {
            XCTAssertTrue(LogSExtractor.values(in: text).isEmpty, text)
        }
    }
    func testMultipleValuesKeepOrderAndDeduplicate() {
        XCTAssertEqual(LogSExtractor.values(in: #"data=[{"s":"one=="},{"s":"two=="},{"s":"one=="}]"#), ["one==", "two=="])
        XCTAssertTrue(LogSExtractor.values(in: String(repeating: "x", count: 2 * 1_024 * 1_024) + " s=one==").isEmpty)
    }
}
