import XCTest
@testable import LogcatCore

final class LogChunkMergerTests: XCTestCase {
    private func part(_ index: Int, _ payload: String, total: Int = 3, id: UInt64? = nil,
                      time: String = "21:11:09.052", pid: String = "1", tid: String = "2",
                      tag: String = "API", context: String = "api_method=taskConfig ", date: String = "2026-10-12") -> LogEntry {
        LogParser.parse("\(date) \(time) \(pid) \(tid) I \(tag): \(context)result_part=\(index)/\(total) result=\(payload)", id: id ?? UInt64(index))!
    }
    private func zeroPart(_ index: Int, _ payload: String, id: UInt64? = nil,
                          time: String = "17:52:42.919", pid: String = "10190", tid: String = "24623",
                          tag: String = "Demo.Config", level: String = "D", date: String = "2026-10-14") -> LogEntry {
        LogParser.parse("\(date) \(time) \(pid) \(tid) \(level) \(tag): \(time)[15714] part_\(index): \(payload)", id: id ?? UInt64(index + 1))!
    }
    private func countedPart(_ index: Int, _ payload: String, total: Int = 15, id: UInt64? = nil,
                             tid: String = "30610", tag: String = "MD.MiraApi") -> LogEntry {
        let loggerTime = index == 1 ? "19:57:43.423" : "19:57:43.424"
        return LogParser.parse("2026-10-14 19:57:43.424 28548 \(tid) D \(tag): \(loggerTime)[559] (\(index)/\(total)) \(payload)", id: id ?? UInt64(index))!
    }
    func testParenthesizedFifteenPartResponseMergesAcrossBatchesWithHeaderOnlyOnce() throws {
        let header = "response path=/mira/v1/drama/video/list trace_id=qa-trace code=200 success=true cost_ms=478 body="
        let json = #"{"data":{"list":[{"title":"中文标题","description":"第一行\n第二行 \"引号\" 😀","url":"https://example.test/video?a=1&b=2"}]},"result_code":200}"#
        let characters = Array(header + json)
        let parts = (0..<15).map { index in
            countedPart(index + 1, String(characters[(characters.count * index / 15)..<(characters.count * (index + 1) / 15)]))
        }
        var buffer = LogBuffer()
        buffer.append(Array(parts.prefix(4)))
        XCTAssertEqual(buffer.entries, Array(parts.prefix(4)))
        for part in parts.dropFirst(4).dropLast() { buffer.append([part]) }
        XCTAssertEqual(buffer.entries.count, 14)
        XCTAssertEqual(buffer.append([parts[14]]), 0)
        XCTAssertEqual(buffer.entries.count, 1)
        let merged = try XCTUnwrap(buffer.entries.first)
        XCTAssertEqual(merged.message, header + json)
        XCTAssertEqual(merged.sourceIDs, Array(1...15).map(UInt64.init))
        XCTAssertEqual(merged.mergedParts, 15)
        XCTAssertEqual(merged.raw, parts.map(\.raw).joined(separator: "\n"))
        XCTAssertFalse(merged.fullText.contains("(1/15)"))
        XCTAssertFalse(merged.fullText.contains("[559]"))
        let document = try XCTUnwrap(LogJSONDocument.parse(merged.displayMessage))
        XCTAssertEqual(document.fragments.count, 1)
        XCTAssertEqual(document.fragments.first?.prefix, header)
        XCTAssertTrue(document.suffix.isEmpty)
        XCTAssertEqual(try LogFilter(query: "result_code").apply(to: buffer.entries).count, 1)
    }
    func testParenthesizedChunksRejectMissingReorderedMixedOrConflictingGroups() {
        let first = countedPart(1, "response body={", total: 3)
        let second = countedPart(2, #""result_code":200"#, total: 3)
        let last = countedPart(3, "}", total: 3)
        let cases = [
            [first, last], [second, first, last], [first, first, last],
            [first, countedPart(2, "x", total: 4), last],
            [first, countedPart(2, "x", total: 3, tid: "30611"), last],
            [first, countedPart(2, "x", total: 3, tag: "Other"), last],
            [first, countedPart(2, "x", total: 3, id: 10), last],
            [first, part(2, "x"), last], [first, zeroPart(1, "x"), last],
            [countedPart(0, "first", total: 2), countedPart(2, "last", total: 2)],
            [countedPart(1, "first", total: 257), countedPart(257, "last", total: 257)]
        ]
        for entries in cases {
            var buffer = LogBuffer(); buffer.append(entries)
            XCTAssertEqual(buffer.entries, entries)
        }
    }
    func testParenthesizedChunksPreserveTruncatedTextWithoutInventingJSON() {
        let parts = [countedPart(1, "response body={\"text\":\"前文�", total: 2),
                     countedPart(2, "  后文（日志已截断）", total: 2)]
        var buffer = LogBuffer(); buffer.append(parts)
        XCTAssertEqual(buffer.entries.count, 1)
        XCTAssertEqual(buffer.entries.first?.message, "response body={\"text\":\"前文�  后文（日志已截断）")
        XCTAssertEqual(buffer.entries.first?.raw, parts.map(\.raw).joined(separator: "\n"))
        XCTAssertNil(LogJSONDocument.parse(buffer.entries.first?.displayMessage ?? ""))
    }
    func testZeroBasedChunksWaitForCompleteJSONAcrossBatchesAndPreserveContent() throws {
        let parts = [zeroPart(0, #"{"data":{"task_"#),
                     zeroPart(1, #"available_at":0,"message":"中文"#),
                     zeroPart(2, #"  😀 \"quoted\" \\ end","portal":""},"result_code":200}"#)]
        let expected = #"{"data":{"task_available_at":0,"message":"中文  😀 \"quoted\" \\ end","portal":""},"result_code":200}"#
        var buffer = LogBuffer()
        buffer.append([parts[0]])
        buffer.append([parts[1]])
        XCTAssertEqual(buffer.entries, Array(parts.prefix(2)))
        XCTAssertEqual(buffer.append([parts[2]]), 0)
        XCTAssertEqual(buffer.entries.count, 1)
        let merged = try XCTUnwrap(buffer.entries.first)
        XCTAssertEqual(merged.message, expected)
        XCTAssertEqual(merged.sourceIDs, [1, 2, 3])
        XCTAssertEqual(merged.mergedParts, 3)
        XCTAssertEqual(merged.raw, parts.map(\.raw).joined(separator: "\n"))
        XCTAssertEqual(merged.fullText, "2026-10-14 17:52:42.919 10190 24623 D Demo.Config: " + expected)
        let document = try XCTUnwrap(LogJSONDocument.parse(merged.displayMessage))
        XCTAssertEqual(document.fragments.count, 1)
        XCTAssertEqual(document.fragments.first?.prefix, "")
        XCTAssertEqual(document.suffix, "")
        XCTAssertEqual(try LogFilter(query: "task_available_at").apply(to: buffer.entries).count, 1)
        XCTAssertEqual(try LogFilter(query: "part_1").apply(to: buffer.entries).count, 1)
    }
    func testZeroBasedChunksRejectMissingReorderedInterleavedAndConflictingParts() {
        let first = zeroPart(0, #"{"value":""#), second = zeroPart(1, "middle"), last = zeroPart(2, #""}"#)
        let cases: [[LogEntry]] = [
            [first, last], [second, first, last], [first, first, last], [second, last],
            [first, zeroPart(1, "middle", pid: "2"), last], [first, zeroPart(1, "middle", tid: "3"), last],
            [first, zeroPart(1, "middle", tag: "Other"), last], [first, zeroPart(1, "middle", level: "I"), last],
            [first, zeroPart(1, "middle", id: 22), last], [first, zeroPart(1, "middle", time: "17:52:41.000"), last],
            [first, second, zeroPart(2, #""}"#, time: "17:52:45.000")],
            [first, second, zeroPart(2, #""}"#, date: "2026-10-15")],
            [first, part(2, "middle"), last],
            [first, LogParser.parse("2026-10-14 17:52:42.919 10190 24623 D Demo.Config: unrelated", id: 2)!, second, last],
            [zeroPart(0, "plain "), zeroPart(1, "text")],
            [zeroPart(0, #"{"nested":{}"#), zeroPart(1, " trailing")],
            [zeroPart(0, #"{"value":1"#), zeroPart(1, "} trailing")]
        ]
        for entries in cases {
            var buffer = LogBuffer(); buffer.append(entries)
            XCTAssertEqual(buffer.entries, entries)
        }
    }
    func testZeroBasedChunksSupportAdjacentObjectsArraysAndEscapedStringBoundaries() {
        let parts = [zeroPart(0, #"{"text":"escaped \"#), zeroPart(1, #""quote\""}"#),
                     zeroPart(0, #"[{"value":1},"#, id: 3), zeroPart(1, #"{"value":2}]"#, id: 4)]
        var buffer = LogBuffer(); buffer.append(parts)
        XCTAssertEqual(buffer.entries.map(\.message), [#"{"text":"escaped \"quote\""}"#, #"[{"value":1},{"value":2}]"#])
        XCTAssertEqual(buffer.entries.map(\.sourceIDs), [[1, 2], [3, 4]])
    }
    func testZeroBasedChunkLimitsClearAndEvictionKeepIncompleteParts() {
        let first = zeroPart(0, #"{"value":""#), second = zeroPart(1, "middle"), last = zeroPart(2, #""}"#)
        var cleared = LogBuffer(); cleared.append([first]); cleared.clear(); cleared.append([second, last])
        XCTAssertEqual(cleared.entries, [second, last])
        var evicted = LogBuffer(limit: 1); evicted.append([first]); evicted.append([second]); evicted.append([last])
        XCTAssertEqual(evicted.entries, [last]); XCTAssertEqual(evicted.evicted, 2)
        let largeParts = [zeroPart(0, #"{"value":""# + String(repeating: "a", count: 1_048_576)),
                          zeroPart(1, String(repeating: "b", count: 1_048_576) + #""}"#)]
        var large = LogBuffer(); large.append(largeParts); XCTAssertEqual(large.entries, largeParts)
        let tooMany = [first] + (1..<256).map { zeroPart($0, "x") } + [zeroPart(256, #""}"#)]
        var capped = LogBuffer(); capped.append(tooMany); XCTAssertEqual(capped.entries, tooMany)
    }
    func testMergesAcrossBatchesAndKeepsOriginalRecordsAndSearchableJoinedWords() throws {
        var buffer = LogBuffer()
        let parts = [part(1, #"{"mess"#), part(2, #"age":"中"#), part(3, #"文😀"}"#)]
        buffer.append(Array(parts.prefix(2)))
        XCTAssertEqual(buffer.entries, Array(parts.prefix(2)))
        buffer.append([parts[2]])
        let merged = try XCTUnwrap(buffer.entries.first)
        XCTAssertEqual(buffer.entries.count, 1)
        XCTAssertEqual(merged.id, 1); XCTAssertEqual(merged.sourceIDs, [1, 2, 3]); XCTAssertEqual(merged.mergedParts, 3)
        XCTAssertEqual(merged.message, #"api_method=taskConfig result={"message":"中文😀"}"#)
        XCTAssertEqual(merged.raw, parts.map(\.raw).joined(separator: "\n"))
        XCTAssertEqual(merged.fullText, "2026-10-12 21:11:09.052 1 2 I API: " + merged.message)
        XCTAssertFalse(merged.fullText.contains("result_part=")); XCTAssertFalse(merged.fullText.contains("\n"))
        XCTAssertEqual(parts[0].fullText, parts[0].raw)
        XCTAssertNotNil(LogJSONDocument.parse(merged.displayMessage))
        XCTAssertEqual(try LogFilter(query: "message|missing").apply(to: buffer.entries).count, 1)
        XCTAssertEqual(try LogFilter(query: "中文😀", regex: true).apply(to: buffer.entries).count, 1)
        XCTAssertEqual(try LogFilter(query: "result_part=2/3").apply(to: buffer.entries).count, 1)
    }
    func testNeverMergesMissingReorderedInterleavedOrConflictingParts() {
        let first = part(1, "a"), second = part(2, "b"), last = part(3, "c")
        let cases: [[LogEntry]] = [
            [first, last], [second, first, last], [first, first, last],
            [first, part(2, "b", pid: "3"), last], [first, part(2, "b", tid: "3"), last],
            [first, part(2, "b", tag: "Other"), last], [first, part(2, "b", context: "api_method=other "), last],
            [first, part(2, "b", total: 4), last], [first, part(2, "b", id: 22), last],
            [first, part(2, "b", time: "21:11:08.000"), last],
            [first, second, part(3, "c", time: "21:11:12.000")],
            [first, second, part(3, "c", date: "2026-10-13")],
            [first, LogParser.parse("2026-10-12 21:11:09.052 1 2 I API: unrelated", id: 2)!, second, last]
        ]
        for entries in cases {
            var buffer = LogBuffer(); buffer.append(entries)
            XCTAssertEqual(buffer.entries, entries)
        }
    }
    func testTimestampPrefixAndAdjacentCompleteGroups() {
        var buffer = LogBuffer()
        var first = part(1, "a", total: 2)
        first.message = "21:11:09.052[77] " + first.message
        buffer.append([first, part(2, "b", total: 2), part(1, "c", total: 2, id: 3), part(2, "d", total: 2, id: 4)])
        XCTAssertEqual(buffer.entries.map(\.message), ["api_method=taskConfig result=ab", "api_method=taskConfig result=cd"])
        XCTAssertEqual(buffer.entries.map(\.mergedParts), [2, 2])
    }
    func testClearEvictionAndOversizeKeepIncompletePartsSeparate() {
        var buffer = LogBuffer(limit: 2)
        buffer.append([part(1, "a")]); buffer.clear()
        buffer.append([part(2, "b"), part(3, "c")])
        XCTAssertEqual(buffer.entries.count, 2); XCTAssertTrue(buffer.entries.allSatisfy { $0.mergedParts == 1 })
        buffer.clear()
        buffer.append([part(1, "a"), part(2, "b"), part(3, "c")])
        XCTAssertEqual(buffer.entries.count, 1); XCTAssertEqual(buffer.evicted, 0)
        var large = LogBuffer()
        let parts = [part(1, String(repeating: "a", count: 1_048_576), total: 2), part(2, String(repeating: "b", count: 1_048_576), total: 2)]
        large.append(parts); XCTAssertEqual(large.entries, parts)
    }
    func testSyntheticThreePartConfigBecomesCompleteJSON() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task-config-parts", withExtension: "log", subdirectory: "Fixtures"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let entries = try lines.enumerated().map { try XCTUnwrap(LogParser.parse($0.element, id: UInt64($0.offset + 1))) }
        var buffer = LogBuffer(); entries.forEach { buffer.append([$0]) }
        XCTAssertEqual(buffer.entries.count, 1)
        let merged = try XCTUnwrap(buffer.entries.first)
        XCTAssertEqual(merged.mergedParts, 3)
        let document = try XCTUnwrap(LogJSONDocument.parse(merged.displayMessage))
        XCTAssertEqual(document.fragments.count, 1)
        XCTAssertEqual(document.fragments[0].root.children.map(\.key), ["\"msg\"", "\"timestamp\"", "\"data\"", "\"result_code\""])
        XCTAssertTrue(document.suffix.isEmpty)
        XCTAssertEqual(merged.raw, lines.joined(separator: "\n"))
    }
}
