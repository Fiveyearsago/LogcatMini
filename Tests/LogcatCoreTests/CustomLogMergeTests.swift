import XCTest
@testable import LogcatCore

final class CustomLogMergeTests: XCTestCase {
    private func entry(_ id: UInt64, _ text: String, time: String = "20:00:01.000495", tid: String = "2", tag: String = "Runner / com.example.demo", level: LogLevel = .debug) -> LogEntry {
        LogEntry(id: id, date: "2026-11-04", time: time, pid: "1", tid: tid, level: level, tag: tag, message: text,
                 raw: "2026-11-04 \(time) 1 \(tid) \(level.rawValue) \(tag): \(text)")
    }
    func testSequenceTenPartsAcrossBatchesRetainsUnicodeWhitespaceAndOriginals() throws {
        let json = #"{"message":"你好🙂 two  spaces","nested":{"values":[1,2,3,4,5]}}"#
        let chars = Array(json), chunks = (0..<10).map { n in String(chars[(chars.count * n / 10)..<(chars.count * (n + 1) / 10)]) }
        let parts = chunks.enumerated().map { entry(UInt64($0.offset + 1), "seq=13708 part=\($0.offset + 1)/10 \($0.element)") }
        var buffer = LogBuffer()
        for part in parts { buffer.append([part]) }
        XCTAssertEqual(buffer.entries.count, 1)
        let log = try XCTUnwrap(buffer.entries.first)
        XCTAssertEqual(log.message, "seq=13708 " + json)
        XCTAssertEqual(log.sourceIDs, Array(1...10).map(UInt64.init))
        XCTAssertEqual(log.raw, parts.map(\.raw).joined(separator: "\n"))
        XCTAssertEqual(log.originalParts, parts)
        XCTAssertEqual(LogJSONDocument.parse(log.displayMessage)?.fragments.count, 1)
        XCTAssertFalse(log.fullText.contains("part="))
        XCTAssertEqual(try LogFilter(query: "two  spaces").apply(to: buffer.entries).count, 1)
    }
    func testIOSUnifiedTimestampTimezoneAndExportReimport() throws {
        let messages = [#"seq=42 part=1/2 {"message":"你好"#, #"seq=42 part=2/2 世界"}"#]
        let entries = try messages.enumerated().map { index, message in
            let data = try JSONSerialization.data(withJSONObject: ["eventMessage": message, "timestamp": "2026-11-04 20:00:00.00000\(index)+0800",
                "processID": 123, "threadID": 456, "messageType": "Debug", "processImagePath": "/example/Runner", "subsystem": "com.example.qa"])
            return try XCTUnwrap(IOSLogParser.simulator(String(decoding: data, as: UTF8.self), id: UInt64(index + 1)))
        }
        var buffer = LogBuffer(); buffer.append(entries)
        XCTAssertEqual(buffer.entries.count, 1)
        XCTAssertEqual(buffer.entries.first?.message, #"seq=42 {"message":"你好世界"}"#)
        XCTAssertNotNil(LogParser.parse(buffer.entries[0].fullText, id: 1))
        XCTAssertEqual(try XCTUnwrap(LogParser.parse(entries[0].raw, id: 1)).time, entries[0].time)
    }
    func testSequenceRejectsIncompleteDifferentIDsSourcesOrderAndOversizedGroups() {
        let first = entry(1, "seq=7 part=1/2 a"), last = entry(2, "seq=7 part=2/2 b")
        let cases = [[first], [last, first], [first, entry(2, "seq=8 part=2/2 b")],
                     [first, entry(3, "seq=7 part=2/2 b")], [first, entry(2, "seq=7 part=2/2 b", tid: "3")],
                     [first, entry(2, "seq=7 part=2/2 b", tag: "Other")], [first, entry(2, "seq=7 part=2/2 b", level: .info)],
                     [first, entry(2, "seq=7 part=2/2 b", time: "20:00:04.000000")],
                     [entry(1, "seq=7 part=1/1 a"), entry(2, "seq=8 part=1/1 b")],
                     [first, entry(2, "seq=7 part=2/3 b")],
                     [entry(1, "seq=7 part=1/257 a"), entry(2, "seq=7 part=2/257 b")],
                     [entry(1, "seq=7 part=1/2 " + String(repeating: "x", count: 2 * 1024 * 1024)), last]]
        for parts in cases { var buffer = LogBuffer(); buffer.append(parts); XCTAssertEqual(buffer.entries, parts) }
    }
    func testTemplateLiteralPunctuationTagTimeAndJSONRequirement() throws {
        var rule = LogMergeRule(); rule.pattern = "request={key} [{index}/{total}] {body}"
        rule.tagContains = "Runner"; rule.requireJSON = true; rule.maximumSeconds = 5
        try rule.validate()
        let parts = [entry(1, #"request=a [1/2] {"message":"中文 "#), entry(2, #"request=a [2/2]  two"}"#, time: "20:00:05.000000")]
        var buffer = LogBuffer(mergeRules: [rule]); buffer.append(parts)
        XCTAssertEqual(buffer.entries.count, 1); XCTAssertEqual(buffer.entries.first?.message, #"{"message":"中文  two"}"#)
        for invalid in [parts.map { entry($0.id, $0.message, tag: "Unrelated") },
                        [parts[0], entry(2, "request=b [2/2] end")], [parts[0], entry(2, "request=a [2/2] invalid")]] {
            var candidate = LogBuffer(mergeRules: [rule]); candidate.append(invalid); XCTAssertEqual(candidate.entries, invalid)
        }
        rule.enabled = false; buffer.setMergeRules([rule]); XCTAssertEqual(buffer.entries, parts)
        rule.enabled = true; buffer.setMergeRules([rule]); XCTAssertEqual(buffer.entries.count, 1)
        buffer.setMergeRules([]); XCTAssertEqual(buffer.entries, parts)
    }
    func testAdvancedPatternPrefixAndRulesDoNotMix() throws {
        var rule = LogMergeRule(); rule.mode = .regex
        rule.pattern = #"^(?<prefix>trace=(?<key>\S+) )chunk\[(?<index>\d+)/(?<total>\d+)\] (?<body>.*)$"#
        var buffer = LogBuffer(mergeRules: [rule])
        buffer.append([entry(1, "trace=hello chunk[1/2] abc"), entry(2, "trace=hello chunk[2/2] def")])
        XCTAssertEqual(buffer.entries.first?.message, "trace=hello abcdef")
        var second = LogMergeRule(); second.pattern = "request={key} [{index}/{total}] {body}"
        buffer = LogBuffer(mergeRules: [rule, second])
        buffer.append([entry(1, "trace=hello chunk[1/2] abc"), entry(2, "request=hello [2/2] def")])
        XCTAssertEqual(buffer.entries.count, 2)
    }
    func testValidationAndPathologicalRegexAreBounded() throws {
        var rule = LogMergeRule()
        rule.pattern = "part={index}/{total} {body}"; XCTAssertThrowsError(try rule.validate())
        rule.pattern = "{key} {index} {index} {total} {body}"; XCTAssertThrowsError(try rule.validate())
        rule = LogMergeRule(); rule.maximumSeconds = .infinity; XCTAssertThrowsError(try rule.validate())
        rule = LogMergeRule(); rule.mode = .regex; rule.pattern = "("; XCTAssertThrowsError(try rule.validate())
        rule.pattern = #"^(?<key>(a+)+)!(?<index>\d+)/(?<total>\d+) (?<body>.*)$"#
        try rule.validate()
        let start = Date(); var buffer = LogBuffer(mergeRules: [rule])
        buffer.append([entry(1, String(repeating: "a", count: 20_000) + "?")])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(buffer.entries.count, 1)
    }
    func testOptInLocalIOSSequenceSample() throws {
        guard let path = ProcessInfo.processInfo.environment["LOGCAT_MINI_SEQUENCE_SAMPLE"] else { throw XCTSkip("Opt in to a local sample; real logs are never committed") }
        let parts = try String(contentsOfFile: path).components(separatedBy: "\n").filter { !$0.isEmpty }.enumerated().map { pair in
            try XCTUnwrap(IOSLogParser.simulator(pair.element, id: UInt64(pair.offset + 1)) ?? LogParser.parse(pair.element, id: UInt64(pair.offset + 1)))
        }
        var buffer = LogBuffer(); buffer.append(parts)
        XCTAssertGreaterThan(parts.count, 1); XCTAssertEqual(buffer.entries.count, 1)
        XCTAssertEqual(buffer.entries.first?.mergedParts, parts.count)
        let payloads = parts.map { entry -> String in
            let range = entry.message.range(of: #"part=\d+/\d+ "#, options: .regularExpression)!
            return String(entry.message[range.upperBound...])
        }
        XCTAssertTrue(buffer.entries[0].message.hasSuffix(payloads.joined()))
        XCTAssertEqual(buffer.entries[0].raw, parts.map(\.raw).joined(separator: "\n"))
        XCTAssertEqual(buffer.entries[0].sourceWasTruncated, parts.contains { $0.sourceWasTruncated })
    }
}
