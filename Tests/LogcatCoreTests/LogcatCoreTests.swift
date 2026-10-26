import XCTest
@testable import LogcatCore

final class LogcatCoreTests: XCTestCase {
    private let line = "2026-10-12 16:35:55.138  1938 20223 E Demo Tasks: 请求失败：http://localhost/path:a"
    func testParsesThreadtimeWithoutBreakingMessageColons() throws {
        let entry = try XCTUnwrap(LogParser.parse(line, id: 9))
        XCTAssertEqual(entry.date, "2026-10-12"); XCTAssertEqual(entry.time, "16:35:55.138")
        XCTAssertEqual(entry.pid, "1938"); XCTAssertEqual(entry.tid, "20223")
        XCTAssertEqual(entry.level, .error); XCTAssertEqual(entry.tag, "Demo Tasks")
        XCTAssertEqual(entry.message, "请求失败：http://localhost/path:a"); XCTAssertEqual(entry.raw, line)
    }
    func testLegacyDateAndAssertLevel() throws {
        let entry = try XCTUnwrap(LogParser.parse("10-12 16:35:55.100 1 2 A Test: abort", id: 1))
        XCTAssertEqual(entry.level, .fatal); XCTAssertEqual(entry.date, "10-12")
        XCTAssertNil(LogParser.parse("--------- beginning of main", id: 2))
        XCTAssertNil(LogParser.parse("error: device unauthorized", id: 3))
    }
    func testEveryUTF8ChunkBoundaryPreservesChineseAndEmoji() {
        let bytes = Data("中文日志🔋\nsecond\n剩余".utf8)
        for split in 0...bytes.count {
            var framer = LineFramer()
            let lines = framer.append(Data(bytes.prefix(split))) + framer.append(Data(bytes.dropFirst(split)))
            XCTAssertEqual(lines, ["中文日志🔋", "second"], "split=\(split)")
            XCTAssertEqual(framer.finish(), "剩余")
            XCTAssertNil(framer.finish())
        }
    }
    func testFiltersCombineSeverityTagAndRegex() throws {
        let error = try XCTUnwrap(LogParser.parse(line, id: 1))
        let debug = try XCTUnwrap(LogParser.parse("2026-10-12 16:35:55.100 1 2 D Network: success", id: 2))
        XCTAssertEqual(try LogFilter(minimum: .warning).apply(to: [error, debug]), [error])
        XCTAssertEqual(try LogFilter(query: "请求.*localhost", tag: "DEMO", regex: true).apply(to: [error, debug]), [error])
        XCTAssertTrue(try LogFilter(query: "success", tag: "Demo").apply(to: [error, debug]).isEmpty)
        XCTAssertThrowsError(try LogFilter(query: "[", regex: true).apply(to: [error]))
    }
    func testPackageUIDParsingAndDeduplication() {
        let apps = AndroidPackage.parse("package:com.example.b uid:10123\npackage:com.example.a uid:10124\npackage:com.example.b uid:10123\npackage:bad uid:oops\nerror: unauthorized")
        XCTAssertEqual(apps.map(\.id), ["com.example.a", "com.example.b"])
        XCTAssertEqual(apps.map(\.uid), ["10124", "10123"])
    }
    func testDeviceStatesAndWirelessSerials() {
        let devices = AndroidDevice.parse("List of devices attached\nabc device product:x model:Pixel_6 device:y\n192.168.1.2:5555 offline\nxyz unauthorized\n* daemon started successfully *")
        XCTAssertEqual(devices.count, 3); XCTAssertEqual(devices[0].name, "Pixel 6")
        XCTAssertTrue(devices[0].ready); XCTAssertFalse(devices[1].ready)
        XCTAssertEqual(devices[1].id, "192.168.1.2:5555")
    }
    func testBoundedBufferKeepsNewestRecords() throws {
        var buffer = LogBuffer(limit: 3)
        buffer.append(try (1...5).map { try XCTUnwrap(LogParser.parse(line, id: UInt64($0))) })
        XCTAssertEqual(buffer.entries.map(\.id), [3, 4, 5]); XCTAssertEqual(buffer.evicted, 2)
        buffer.clear(); XCTAssertTrue(buffer.entries.isEmpty); XCTAssertEqual(buffer.evicted, 0)
    }
    func testCommandRunnerPassesArgumentsLiterally() async throws {
        let value = "a; $(touch /tmp/should-not-run) 中文"
        let output = try await ADB.run(path: "/bin/echo", arguments: [value])
        XCTAssertEqual(output, value)
    }
    func testCommandRunnerSurfacesFailure() async {
        do { _ = try await ADB.run(path: "/usr/bin/false", arguments: []); XCTFail("Expected failure") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
    func testCommandRunnerTimesOut() async {
        let start = Date()
        do { _ = try await ADB.run(path: "/bin/sleep", arguments: ["10"], timeout: 0.1); XCTFail("Expected timeout") }
        catch { XCTAssertLessThan(Date().timeIntervalSince(start), 3) }
    }
    func testDefaultBufferRetainsAllOneHundredThousandLogsUntilCleared() throws {
        let parsed = try XCTUnwrap(LogParser.parse(line, id: 1))
        var buffer = LogBuffer()
        for batch in 0..<100 {
            buffer.append((0..<1000).map { n in
                LogEntry(id: UInt64(batch * 1000 + n), date: parsed.date, time: parsed.time, pid: parsed.pid, tid: parsed.tid, level: parsed.level, tag: parsed.tag, message: parsed.message, raw: parsed.raw)
            })
        }
        XCTAssertEqual(buffer.entries.count, 100_000)
        XCTAssertEqual(buffer.entries.first?.id, 0)
        XCTAssertEqual(buffer.entries.last?.id, 99_999)
        XCTAssertEqual(buffer.evicted, 0)
        buffer.clear(); XCTAssertTrue(buffer.entries.isEmpty)
        XCTAssertTrue(LogBuffer().entries.isEmpty)
    }
}
