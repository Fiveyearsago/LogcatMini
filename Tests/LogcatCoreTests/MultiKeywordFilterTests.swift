import XCTest
@testable import LogcatCore

final class MultiKeywordFilterTests: XCTestCase {
    private func entry(_ id: UInt64, _ message: String, level: LogLevel = .info, tag: String = "Network", pid: String = "100") -> LogEntry {
        LogEntry(id: id, date: "2026-10-12", time: "18:00:00.000", pid: pid, tid: "200", level: level, tag: tag,
                 message: message, raw: "2026-10-12 18:00:00.000 \(pid) 200 \(level.rawValue) \(tag): \(message)")
    }

    func testAnyKeywordMatchesOriginalMessageTagOrPIDWithoutDuplicatingRows() throws {
        let rows = [entry(1, "登录成功🔋"), entry(2, "支付完成", tag: "Payments"),
                    entry(3, "both 登录 and 支付"), entry(4, "unrelated", pid: "29440"), entry(5, "unrelated")]
        let filtered = try LogFilter(query: "登录|payments|29440").apply(to: rows)
        XCTAssertEqual(filtered.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(filtered.map(\.raw), [rows[0].raw, rows[1].raw, rows[2].raw, rows[3].raw])
    }

    func testBlankSegmentsDoNotAccidentallyMatchAllLogs() throws {
        let rows = [entry(1, "timeout"), entry(2, "请求失败"), entry(3, "unrelated")]
        XCTAssertEqual(try LogFilter(query: " | TIMEOUT || 请求失败 | TIMEOUT | ").apply(to: rows).map(\.id), [1, 2])
        XCTAssertEqual(try LogFilter(query: " | \t || ").apply(to: rows), rows)
        XCTAssertEqual(try LogFilter(query: "not found|").apply(to: rows), [])
    }

    func testTagAlternativesStillCombineWithQueryAndSeverity() throws {
        let rows = [entry(1, "timeout", level: .error), entry(2, "请求失败", level: .warning, tag: "ApiMetrics"),
                    entry(3, "timeout", level: .debug), entry(4, "timeout", level: .error, tag: "Other"),
                    entry(5, "success", level: .error)]
        let filtered = try LogFilter(minimum: .warning, query: "timeout|请求失败", tag: " network | APIMETRICS || ").apply(to: rows)
        XCTAssertEqual(filtered.map(\.id), [1, 2])
        XCTAssertEqual(try LogFilter(minimum: .error, query: " | ", tag: " || ").apply(to: rows).map(\.id), [1, 4, 5])
    }

    func testNormalKeywordsStayLiteralAndRegexKeepsGroupingAndEscapes() throws {
        let rows = [entry(1, "[error]"), entry(2, "request.*failed"), entry(3, "requestABCfailed"),
                    entry(4, "login failed"), entry(5, "pay timeout"), entry(6, "a|b")]
        XCTAssertEqual(try LogFilter(query: "[error]|request.*failed").apply(to: rows).map(\.id), [1, 2])
        XCTAssertEqual(try LogFilter(query: "(login|pay) (failed|timeout)", regex: true).apply(to: rows).map(\.id), [4, 5])
        XCTAssertEqual(try LogFilter(query: #"a\|b"#, regex: true).apply(to: rows).map(\.id), [6])
        XCTAssertThrowsError(try LogFilter(query: "(login|pay", regex: true).apply(to: rows))
    }
}
