import XCTest
@testable import LogcatCore

final class NumberedEnvelopeTests: XCTestCase {
    private func part(_ n: Int, _ payload: String, id: UInt64? = nil, context: String = "stage=some_api log_id=7 status=response ", field: String = "data", tag: String = "Any.Tag", total: Int = 3) -> LogEntry {
        LogParser.parse("2026-10-16 10:46:09.503 28807 28854 I \(tag): 10:46:09.50\(n)[201] \(context)part=\(n)/\(total) \(field)=\(payload)", id: id ?? UInt64(n))!
    }
    func testGenericEnvelopeMergesAcrossBatchesWithDifferentTagsAndPayloadLabels() throws {
        for tag in ["Demo.Client", "Other.Client"] {
            for field in ["data", "body", "content", "result"] {
                let parts = [part(1, #"http_code=200 body={"mess"#, field: field, tag: tag),
                             part(2, #"age":"中文  \"# , field: field, tag: tag),
                             part(3, #""quoted\"","result_code":200}"#, field: field, tag: tag)]
                var buffer = LogBuffer()
                for item in parts { buffer.append([item]) }
                let merged = try XCTUnwrap(buffer.entries.first)
                XCTAssertEqual(buffer.entries.count, 1)
                XCTAssertEqual(merged.message, "stage=some_api log_id=7 status=response \(field)=" + #"http_code=200 body={"message":"中文  \"quoted\"","result_code":200}"#)
                XCTAssertEqual(merged.sourceIDs, [1, 2, 3])
                XCTAssertEqual(merged.raw, parts.map(\.raw).joined(separator: "\n"))
                XCTAssertEqual(LogJSONDocument.parse(merged.message)?.fragments.count, 1)
            }
        }
    }
    func testMissingConflictingInterleavedAndMixedEnvelopesRemainSeparate() {
        let first = part(1, "a"), middle = part(2, "b"), last = part(3, "c")
        let cases = [
            [first, last], [middle, first, last], [first, first, last],
            [first, part(2, "b", context: "stage=some_api log_id=8 status=response "), last],
            [first, part(2, "b", context: "stage=some_api log_id=7 status=request "), last],
            [first, part(2, "b", field: "body"), last], [first, part(2, "b", tag: "Other"), last],
            [first, part(2, "b", total: 4), last], [first, part(2, "b", id: 9), last],
            [first, LogParser.parse("2026-10-16 10:46:09.503 28807 28854 I Any.Tag: unrelated", id: 2)!, last],
            [part(1, "a", total: 257), part(2, "b", total: 257)],
            [first, LogParser.parse("2026-10-16 10:46:09.503 28807 28854 I Any.Tag: stage=some_api log_id=7 status=response data_part=2/3 data=b", id: 2)!, last]
        ]
        for entries in cases { var buffer = LogBuffer(); buffer.append(entries); XCTAssertEqual(buffer.entries, entries) }
    }
    func testUserProvidedFourPartSampleWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["LOGCAT_MINI_NUMBERED_SAMPLE"] else { throw XCTSkip("Opt in to a local log sample; user logs are not test resources") }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        let entries = try lines.enumerated().map { try XCTUnwrap(LogParser.parse($0.element, id: UInt64($0.offset + 1))) }
        var buffer = LogBuffer(); entries.forEach { buffer.append([$0]) }
        XCTAssertEqual(entries.count, 4); XCTAssertEqual(buffer.entries.count, 1)
        let merged = try XCTUnwrap(buffer.entries.first)
        XCTAssertEqual(merged.mergedParts, 4)
        XCTAssertEqual(merged.message, "stage=demo_api log_id=7 status=response data=" + entries.map { $0.message.components(separatedBy: " data=").last! }.joined())
        let document = try XCTUnwrap(LogJSONDocument.parse(merged.message))
        XCTAssertEqual(document.fragments.count, 1); XCTAssertTrue(document.suffix.isEmpty)
        XCTAssertEqual(merged.raw, lines.joined(separator: "\n"))
    }
}
