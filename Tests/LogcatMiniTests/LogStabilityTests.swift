import XCTest
import AppKit
import LogcatCore
@testable import LogcatMini

final class LogStabilityTests: XCTestCase {
    @MainActor func testFollowResumesPausedSnapshotAndRevealsBufferedLogs() {
        let model = model(); defer { model.shutdown() }
        for following in [true, false] {
            model.clear(); model.follow = following
            model.ingest([entry(1, "before pause")])
            model.togglePause()
            model.ingest([entry(2, "received while paused")])
            XCTAssertFalse(model.isFollowing)
            XCTAssertEqual(model.visible.map(\.id), [1])
            XCTAssertEqual(model.receivedWhilePaused, 1)
            model.toggleFollow()
            XCTAssertFalse(model.paused); XCTAssertTrue(model.isFollowing)
            XCTAssertEqual(model.visible.map(\.id), [1, 2])
            XCTAssertEqual(model.receivedWhilePaused, 0)
            model.toggleFollow(); XCTAssertFalse(model.isFollowing)
        }
    }
    @MainActor func testNumberedSLogBecomesOneSelectedDecryptableRecord() throws {
        let model = model(); defer { model.shutdown() }
        let value = Data([1] + Array(#"{"message":"中文"}"#.utf8)).base64EncodedString()
        let middle = value.index(value.startIndex, offsetBy: value.count / 2)
        model.ingest([entry(1, "10:00:00.001[201] stage=encode log_id=7 part=1/2 data={\"s\":\"" + value[..<middle])])
        model.selectedLog = model.visible.first
        XCTAssertTrue(LogSExtractor.values(in: model.selectedLog!.message).isEmpty)
        model.ingest([entry(2, "10:00:00.002[201] stage=encode log_id=7 part=2/2 data=" + value[middle...] + "\"}")])
        let selected = try XCTUnwrap(model.selectedLog)
        XCTAssertEqual(model.visible.count, 1); XCTAssertEqual(selected.mergedParts, 2)
        XCTAssertEqual(LogSExtractor.values(in: selected.message), [value])
    }
    private func entry(_ id: UInt64, _ text: String, tag: String = "QA") -> LogEntry {
        LogParser.parse("2026-10-14 10:00:00.001 123 123 I \(tag): \(text)", id: id)!
    }
    @MainActor private func model() -> LogViewModel {
        let name = "LogStabilityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let model = LogViewModel(defaults: defaults)
        model.adbPath = nil
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return model
    }

    @MainActor func testAppSwitchRestoresLogsFiltersAndSelectionWithoutMixingDevices() {
        let model = model(); defer { model.shutdown() }
        model.activateDevice("phone-a"); model.selectPackage("alpha")
        model.ingest([entry(1, "alpha match")]); model.query = "match"; model.regex = false
        model.selectedLog = model.visible.first; model.follow = false
        model.selectPackage("beta")
        XCTAssertEqual(model.query, ""); XCTAssertTrue(model.visible.isEmpty)
        model.ingest([entry(2, "beta")])
        model.selectPackage(""); model.ingest([entry(3, "all apps")])
        model.selectPackage("alpha")
        XCTAssertEqual(model.visible.map(\.id), [1]); XCTAssertEqual(model.query, "match")
        XCTAssertEqual(model.selectedLog?.id, 1); XCTAssertFalse(model.follow)
        model.activateDevice("phone-b"); model.selectPackage("alpha")
        XCTAssertTrue(model.visible.isEmpty)
        model.ingest([entry(4, "other phone")])
        model.activateDevice("phone-a")
        XCTAssertEqual(model.selectedPackage, "alpha"); XCTAssertEqual(model.visible.map(\.id), [1])
        model.clear(); model.selectPackage("beta")
        XCTAssertEqual(model.visible.map(\.id), [2])
        model.selectPackage("alpha"); XCTAssertTrue(model.visible.isEmpty)
        model.selectPackage(""); XCTAssertEqual(model.visible.map(\.id), [3])
    }

    @MainActor func testIncrementalFilteringMatchesFullPassIncludingCrossBatchMergePauseAndClear() throws {
        let model = model(); defer { model.shutdown() }
        var reference = LogBuffer()
        model.query = "target|result_part"; model.tag = "QA"; model.regex = false
        let batches = [
            [entry(1, "not matched"), entry(2, "target"), entry(3, "result_part=1/3 result={\"tar")],
            [entry(4, "result_part=2/3 result=get\":")],
            [entry(5, "result_part=3/3 result=true}"), entry(6, "target", tag: "Other")],
            [entry(7, "target"), entry(8, "ignored")]
        ]
        for batch in batches {
            reference.append(batch); model.ingest(batch)
            let expected = try LogFilter(query: model.query, tag: model.tag).apply(to: reference.entries)
            XCTAssertEqual(model.visible, expected)
            if model.selectedLog == nil { model.selectedLog = model.visible.last }
        }
        XCTAssertEqual(model.selectedLog?.mergedParts, 3)
        model.togglePause(); let snapshot = model.visible
        model.ingest([entry(9, "target")]); XCTAssertEqual(model.visible, snapshot)
        model.togglePause(); XCTAssertEqual(model.visible.last?.id, 9)
        model.query = "["; model.regex = true; XCTAssertNotNil(model.filterError)
        model.ingest([entry(10, "target")]); XCTAssertTrue(model.visible.isEmpty)
        model.query = "target"; model.regex = false; XCTAssertNil(model.filterError)
        XCTAssertEqual(model.visible.last?.id, 10)
        model.clear(); model.ingest([entry(11, "target")]); XCTAssertEqual(model.visible.map(\.id), [11])
    }

    @MainActor func testSearchTailUpdateKeepsCurrentHitAndRemovesMergedParts() {
        let find = LogFindState(); find.query = "target"; find.replaceMatches(["1", "3", "4"]); find.move(1)
        var merged = entry(3, "target combined"); merged.sourceIDs = [3, 4, 5]
        find.replaceLogSuffix(from: 3, entries: [merged, entry(6, "target new")])
        XCTAssertEqual(find.matches, ["1", "3", "6"]); XCTAssertEqual(find.current, "3")
        find.replaceLogSuffix(from: 3, entries: [entry(3, "no hit")])
        XCTAssertEqual(find.matches, ["1"]); XCTAssertEqual(find.current, "1")
    }

    @MainActor func testZeroBasedMergeRefreshesSelectedPartAndFilteredListAcrossBatches() throws {
        let model = model(); defer { model.shutdown() }
        model.query = "part_|task_available_at"; model.regex = false
        model.ingest([entry(1, "unrelated"), entry(2, #"10:00:00.001[77] part_0: {"data":{"task_"#)])
        model.ingest([entry(3, #"10:00:00.001[77] part_1: available_at":0},"result_"#)])
        XCTAssertEqual(model.visible.map(\.id), [2, 3])
        model.selectedLog = model.visible.last
        model.ingest([entry(4, "10:00:00.001[77] part_2: code\":200}")])
        XCTAssertEqual(model.totalCount, 2)
        XCTAssertEqual(model.visible.map(\.id), [2])
        let selected = try XCTUnwrap(model.selectedLog)
        XCTAssertEqual(selected.id, 2)
        XCTAssertEqual(selected.mergedParts, 3)
        XCTAssertEqual(selected.message, #"{"data":{"task_available_at":0},"result_code":200}"#)
        XCTAssertFalse(selected.fullText.contains("part_"))
        let document = try XCTUnwrap(LogJSONDocument.parse(selected.displayMessage))
        XCTAssertEqual(document.fragments.count, 1)
        XCTAssertTrue(document.suffix.isEmpty)
    }

    @MainActor func testParenthesizedResponseFlowsThroughInboxAndRefreshesSelectedPart() throws {
        let model = model(); defer { model.shutdown() }
        let inbox = LogInbox(), session = UUID(); inbox.reset(session)
        let lines = [entry(1, #"10:00:00.001[559] (1/3) response path=/qa trace_id=sample body={"da"#).raw,
                     entry(2, #"10:00:00.002[559] (2/3) ta":{"value":"中文"},"result_"#).raw,
                     entry(3, #"10:00:00.002[559] (3/3) code":200}"#).raw]
        inbox.receive(Array(lines.prefix(2)), session: session)
        model.ingest(inbox.drain().0)
        XCTAssertEqual(model.visible.count, 2)
        model.selectedLog = model.visible.last
        inbox.receive([lines[2]], session: session)
        model.ingest(inbox.drain().0)
        XCTAssertEqual(model.visible.count, 1)
        let selected = try XCTUnwrap(model.selectedLog)
        XCTAssertEqual(selected.sourceIDs, [1, 2, 3])
        XCTAssertEqual(selected.message, #"response path=/qa trace_id=sample body={"data":{"value":"中文"},"result_code":200}"#)
        XCTAssertEqual(selected.raw, lines.joined(separator: "\n"))
        XCTAssertFalse(selected.fullText.contains("(1/3)"))
        XCTAssertNotNil(LogJSONDocument.parse(selected.displayMessage))
    }

    @MainActor func testOkHTTPMergeRefreshesSelectionSearchAndCopiedDetailAcrossBatches() throws {
        let model = model(); defer { model.shutdown() }
        let inbox = LogInbox(), session = UUID(); inbox.reset(session)
        model.query = "task_available_at|task_"; model.regex = false
        let lines = [entry(1, #"{"data":{"task_"#, tag: "okhttp.OkHttpClient").raw,
                     entry(2, #"available_at":0},"result_"#, tag: "okhttp.OkHttpClient").raw,
                     entry(3, #"code":200}"#, tag: "okhttp.OkHttpClient").raw]
        inbox.receive(Array(lines.prefix(2)), session: session); model.ingest(inbox.drain().0)
        XCTAssertEqual(model.visible.count, 1)
        model.selectedLog = model.visible.first
        inbox.receive([lines[2]], session: session); model.ingest(inbox.drain().0)
        XCTAssertEqual(model.totalCount, 1); XCTAssertEqual(model.visible.count, 1)
        let selected = try XCTUnwrap(model.selectedLog)
        XCTAssertEqual(selected.sourceIDs, [1, 2, 3])
        XCTAssertEqual(selected.message, #"{"data":{"task_available_at":0},"result_code":200}"#)
        XCTAssertEqual(selected.raw, lines.joined(separator: "\n"))
        XCTAssertEqual(selected.fullText.components(separatedBy: "okhttp.OkHttpClient:").count, 2)
        XCTAssertNotNil(LogJSONDocument.parse(selected.displayMessage))
    }

    func testBurstDrainsInOrderAndRejectsLateCallbacksAfterSwitch() {
        let inbox = LogInbox(), first = UUID(), second = UUID()
        inbox.reset(first)
        inbox.receive((1...12_345).map { entry(UInt64($0), "first \($0)").raw }, session: first)
        var received: [LogEntry] = []
        for _ in 0..<13 {
            let batch = inbox.drain(limit: 1_000).0
            XCTAssertLessThanOrEqual(batch.count, 1_000); received.append(contentsOf: batch)
        }
        XCTAssertEqual(received.count, 12_345)
        XCTAssertEqual(received.map(\.id), Array(1...12_345).map(UInt64.init))
        inbox.reset(second)
        inbox.receive([entry(0, "old callback").raw], session: first)
        inbox.receive([entry(0, "second").raw], session: second)
        XCTAssertEqual(inbox.drain().0.map(\.message), ["second"])
    }

    @MainActor func testLargeHistoryAppendWorkload() throws {
        let model = model(); defer { model.shutdown() }
        let history = (1...100_000).map { entry(UInt64($0), "event=background index=\($0)") }
        model.query = "needle|error"; model.regex = false
        model.ingest(history)
        let start = CFAbsoluteTimeGetCurrent()
        for batch in 0..<30 {
            model.ingest((1...100).map { entry(UInt64(100_000 + batch * 100 + $0), "needle value=\($0)") })
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(model.totalCount, 103_000); XCTAssertEqual(model.visible.count, 3_000)
        print("Stability benchmark: 100k history, 30 x 100 new records: \(elapsed * 1000 / 30) ms/batch")
    }

    @MainActor func testLargeJSONDisclosureLookupAndNativeScrolling() throws {
        let json = "[" + (0..<4_000).map { "{\"index\":\($0)}" }.joined(separator: ",") + "]"
        let document = try XCTUnwrap(LogJSONDocument.parse(json))
        let layout = document.textLayout(expanded: document.containerIDs)
        let last = try XCTUnwrap(layout.lines.last)
        XCTAssertEqual(DetailNativeTextView.firstVisibleLine(in: layout.lines, at: last.range.location), layout.lines.count - 1)
        XCTAssertEqual(DetailNativeTextView.firstVisibleLine(in: layout.lines, at: last.range.location + 1), layout.lines.count)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 250))
        let view = DetailNativeTextView(frame: scroll.bounds)
        view.isVerticallyResizable = true; view.textContainer?.widthTracksTextView = true
        view.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = view; view.jsonLines = layout.lines
        view.replaceContent(NSAttributedString(string: layout.text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)]))
        view.scrollRangeToVisible(NSRange(location: last.range.location, length: 1)); view.updateDisclosureButtons()
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertLessThan(view.subviews.compactMap { $0 as? NSButton }.count, 30)
        view.scrollRangeToVisible(NSRange(location: 0, length: 1)); view.updateDisclosureButtons()
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 10)
    }

    @MainActor func testPackageRefreshKeepsMissingSessionAndRebindsChangedUID() async throws {
        let model = model(); defer { model.shutdown() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adb = root.appendingPathComponent("fake-adb"), packages = root.appendingPathComponent("packages")
        let script = #"""
        #!/usr/bin/python3
        import pathlib, sys, time, re
        root = pathlib.Path(__file__).parent
        args = sys.argv[1:]
        if args == ['devices', '-l']:
            print('List of devices attached\nphone device model:QA')
        elif 'package' in args:
            print((root/'packages').read_text())
        else:
            command = args[-1]
            uid = re.search(r'--uid=(\d+)', command)
            (root/'capture').write_text(uid[1] if uid else 'all')
            print('2026-10-14 10:00:00.001 123 123 I QA: uid=' + (uid[1] if uid else 'all'), flush=True)
            time.sleep(10)
        """#
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        model.activateDevice("phone"); model.selectPackage("alpha")
        model.devices = AndroidDevice.parse("phone device model:QA")
        model.ingest([entry(0, "retained")]); model.adbPath = adb.path
        try "package:alpha uid:10001".write(to: packages, atomically: true, encoding: .utf8)
        await model.refreshPackages()
        try await waitForCapture("10001", root: root)
        XCTAssertTrue(model.running)
        try "package:alpha uid:10002".write(to: packages, atomically: true, encoding: .utf8)
        await model.refreshDevices()
        try await waitForCapture("10002", root: root)
        XCTAssertTrue(model.running)
        try "package:beta uid:10003".write(to: packages, atomically: true, encoding: .utf8)
        await model.refreshPackages()
        XCTAssertEqual(model.selectedPackage, "alpha"); XCTAssertFalse(model.running)
        XCTAssertTrue(model.visible.contains { $0.message == "retained" }); XCTAssertNotNil(model.errorMessage)
    }

    private func waitForCapture(_ uid: String, root: URL) async throws {
        for _ in 0..<100 {
            if (try? String(contentsOf: root.appendingPathComponent("capture"))) == uid { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Stream did not bind UID \(uid)")
    }
}
