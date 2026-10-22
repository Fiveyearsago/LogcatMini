import XCTest
@testable import LogcatCore

final class OkHTTPChunkMergerTests: XCTestCase {
    private func row(_ id: UInt64, _ payload: String, time: String = "19:36:49.133",
                     pid: String = "101", tid: String = "102", tag: String = "okhttp.OkHttpClient",
                     level: String = "I", date: String = "2026-10-15") -> LogEntry {
        LogParser.parse("\(date) \(time) \(pid) \(tid) \(level) \(tag): \(payload)", id: id)!
    }

    func testFourThousandCharacterChunksBecomeOneExactJSONAcrossBatches() throws {
        let expected = #"{"msg":"succeed","data":{"text":""# + String(repeating: "中文😀", count: 3000)
            + #"","escaped":"quote \" and slash \\"},"result_code":200}"#
        let characters = Array(expected)
        let parts = stride(from: 0, to: characters.count, by: 4000).enumerated().map { offset, start in
            row(UInt64(offset + 1), String(characters[start..<min(start + 4000, characters.count)]))
        }
        XCTAssertEqual(parts.count, 3)
        var buffer = LogBuffer()
        buffer.append(Array(parts.prefix(2)))
        XCTAssertEqual(buffer.entries, Array(parts.prefix(2)))
        XCTAssertEqual(buffer.append([parts[2]]), 0)
        let merged = try XCTUnwrap(buffer.entries.first)
        XCTAssertEqual(buffer.entries.count, 1)
        XCTAssertEqual(merged.message, expected)
        XCTAssertEqual(merged.sourceIDs, [1, 2, 3])
        XCTAssertEqual(merged.mergedParts, 3)
        XCTAssertEqual(merged.raw, parts.map(\.raw).joined(separator: "\n"))
        XCTAssertEqual(merged.fullText, "2026-10-15 19:36:49.133 101 102 I okhttp.OkHttpClient: " + expected)
        let document = try XCTUnwrap(LogJSONDocument.parse(merged.displayMessage))
        XCTAssertEqual(document.fragments.count, 1); XCTAssertTrue(document.suffix.isEmpty)
        XCTAssertEqual(try LogFilter(query: "result_code").apply(to: buffer.entries).count, 1)
    }

    func testNestedContainersAndEscapedStringBoundariesWaitForOuterJSON() {
        let pieces = ["[", #"{"text":"escaped \"#, #""quote\" and braces } ]"}"#, "]"]
        let parts = pieces.enumerated().map { row(UInt64($0.offset + 1), $0.element) }
        var buffer = LogBuffer()
        buffer.append(Array(parts.prefix(3)))
        // The inner object is complete at row 3, but must not be merged without its outer array.
        XCTAssertEqual(buffer.entries, Array(parts.prefix(3)))
        buffer.append([parts[3]])
        XCTAssertEqual(buffer.entries.map(\.message), [pieces.joined()])
        XCTAssertEqual(buffer.entries.first?.sourceIDs, [1, 2, 3, 4])
    }

    func testCompleteAdjacentBodiesAndHTTPEnvelopesStaySeparate() {
        let parts = [row(1, "<-- 200 https://example.test/first"), row(2, #"{"one":1}"#),
                     row(3, #"{"two":"#), row(4, "2}"), row(5, "<-- END HTTP"),
                     row(6, "--> POST https://example.test/next"), row(7, "[1,"), row(8, "2]")]
        var buffer = LogBuffer(); buffer.append(parts)
        XCTAssertEqual(buffer.entries.map(\.message), [parts[0].message, parts[1].message, #"{"two":2}"#,
                                                       parts[4].message, parts[5].message, "[1,2]"])
        XCTAssertEqual(buffer.entries.map(\.mergedParts), [1, 1, 2, 1, 1, 2])
    }

    func testSourceGapsReorderingInterleavingAndIncompleteOrInvalidJSONStayRaw() {
        let first = row(1, #"{"key":"value"#), last = row(2, #""}"#)
        let variants = [row(2, last.message, pid: "9"), row(2, last.message, tid: "9"),
                        row(2, last.message, tag: "Other"), row(2, last.message, level: "E"),
                        row(2, last.message, date: "2026-10-16"), row(2, last.message, time: "19:36:48.133"),
                        row(2, last.message, time: "19:36:52.133"), row(3, last.message)]
        var cases = variants.map { [first, $0] }
        cases += [[last, first], [first], [first, row(2, "unrelated", tag: "Other"), row(3, last.message)],
                  [first, row(2, "<-- END HTTP"), row(3, last.message)],
                  [row(1, "plain "), row(2, "text}")], [row(1, #"{"value":"#), row(2, "invalid}")],
                  [row(1, #"{"value":"#), row(2, "1} trailing")],
                  [row(1, "["), row(2, "}")]]
        for parts in cases {
            var buffer = LogBuffer(); buffer.append(parts)
            XCTAssertEqual(buffer.entries, parts)
        }
        var other = LogBuffer()
        let otherParts = [row(1, "{", tag: "Custom"), row(2, "}", tag: "Custom")]
        other.append(otherParts); XCTAssertEqual(other.entries, otherParts)
    }

    func testClearEvictionAndSizeAndPartLimitsPreserveOriginalRows() {
        let parts = [row(1, #"{"text":""#), row(2, "middle"), row(3, #""}"#)]
        var cleared = LogBuffer(); cleared.append([parts[0]]); cleared.clear(); cleared.append(Array(parts.suffix(2)))
        XCTAssertEqual(cleared.entries, Array(parts.suffix(2)))
        var evicted = LogBuffer(limit: 1); parts.forEach { evicted.append([$0]) }
        XCTAssertEqual(evicted.entries, [parts[2]])
        let largeParts = [row(1, #"{"text":""# + String(repeating: "x", count: 1_048_576)),
                          row(2, String(repeating: "x", count: 1_048_576) + #""}"#)]
        var large = LogBuffer(); large.append(largeParts); XCTAssertEqual(large.entries, largeParts)
        let tooMany = [parts[0]] + (2...256).map { row(UInt64($0), "x") } + [row(257, #""}"#)]
        var capped = LogBuffer(); capped.append(tooMany); XCTAssertEqual(capped.entries, tooMany)
    }

    func testAttachedOkHTTPSampleWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["LOGCAT_MINI_OKHTTP_SAMPLE"] else {
            throw XCTSkip("Set LOGCAT_MINI_OKHTTP_SAMPLE to validate a local sample without committing private logs.")
        }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        let parts = try lines.enumerated().map { try XCTUnwrap(LogParser.parse($0.element, id: UInt64($0.offset + 1))) }
        var buffer = LogBuffer(); parts.forEach { buffer.append([$0]) }
        XCTAssertGreaterThan(parts.count, 1); XCTAssertEqual(buffer.entries.count, 1)
        let merged = try XCTUnwrap(buffer.entries.first)
        XCTAssertEqual(merged.message, parts.map(\.message).joined())
        XCTAssertEqual(merged.sourceIDs, parts.map(\.id))
        XCTAssertEqual(merged.raw, lines.joined(separator: "\n"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(merged.message.utf8)))
        let document = try XCTUnwrap(LogJSONDocument.parse(merged.displayMessage))
        XCTAssertEqual(document.fragments.count, 1); XCTAssertTrue(document.suffix.isEmpty)
    }
}
