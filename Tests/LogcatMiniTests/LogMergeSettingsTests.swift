import XCTest
import LogcatCore
@testable import LogcatMini

@MainActor final class LogMergeSettingsTests: XCTestCase {
    private func configuration() -> (UserDefaults, LogMergeSettings) {
        let defaults = UserDefaults(suiteName: "LogMergeQA.\(UUID().uuidString)")!
        return (defaults, LogMergeSettings(defaults: defaults))
    }
    private func rule() -> LogMergeRule { var rule = LogMergeRule(); rule.name = "测试模板"; rule.pattern = "record={key} [{index}/{total}] {body}"; return rule }
    private func entry(_ id: UInt64, _ message: String) -> LogEntry {
        LogEntry(id: id, date: "2026-11-04", time: "20:00:00.000", pid: "10", tid: "11", level: .debug, tag: "QA", message: message, raw: "2026-11-04 20:00:00.000 10 11 D QA: \(message)")
    }
    private func wait(_ models: LogViewModel...) async throws {
        for _ in 0..<300 {
            if models.allSatisfy({ !$0.rebuildingMergeRules }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Merge rebuild timed out")
    }
    func testPersistenceValidationAndDelete() throws {
        let (defaults, settings) = configuration(), rule = rule()
        try settings.save(rule)
        XCTAssertEqual(LogMergeSettings(defaults: defaults).rules, [rule])
        settings.setEnabled(rule.id, false)
        XCTAssertFalse(LogMergeSettings(defaults: defaults).rules[0].enabled)
        var bad = rule; bad.pattern = "invalid"
        XCTAssertThrowsError(try settings.save(bad)); XCTAssertEqual(settings.rules.count, 1)
        settings.remove(rule.id); XCTAssertTrue(LogMergeSettings(defaults: defaults).rules.isEmpty)
    }
    func testPreviewUsesOnlyDraftAndRetainsTextAndSourceBoundaries() throws {
        let result = try LogMergePreview.evaluate(rule: rule(), sample: "record=x [1/2] 你好\nrecord=x [2/2] 世界")
        XCTAssertEqual(result.inputCount, 2); XCTAssertEqual(result.mergedCount, 1); XCTAssertTrue(result.output.contains("你好世界"))
        let nonMatch = try LogMergePreview.evaluate(rule: rule(), sample: "seq=7 part=1/2 a\nseq=7 part=2/2 b")
        XCTAssertEqual(nonMatch.mergedCount, 0, "Built-in rules must not hide a mismatched custom rule")
        let differentSources = "2026-11-04 20:00:00.000 10 11 D QA: record=x [1/2] a\n2026-11-04 20:00:00.001 12 11 D QA: record=x [2/2] b"
        XCTAssertEqual(try LogMergePreview.evaluate(rule: rule(), sample: differentSources).mergedCount, 0)
    }
    func testSharedRulesRebuildBothPlatformsWithoutDroppingLiveTailAndRefreshSelection() async throws {
        let (defaults, settings) = configuration()
        let android = LogViewModel(defaults: defaults, mergeSettings: settings)
        let ios = LogViewModel(defaults: defaults, mergeSettings: settings)
        defer { android.shutdown(); ios.shutdown() }
        let first = entry(1, "record=x [1/2] first"), second = entry(2, "record=x [2/2] last")
        for model in [android, ios] { model.ingest([first, second]); model.selectedLog = second }
        try settings.save(rule())
        let tail = entry(3, "arrived during rebuild")
        for model in [android, ios] { model.ingest([tail]) }
        try await wait(android, ios)
        for model in [android, ios] {
            XCTAssertEqual(model.visible.map(\.message), ["firstlast", tail.message])
            XCTAssertEqual(model.selectedLog?.sourceIDs, [1, 2]); XCTAssertEqual(model.totalCount, 2)
        }
        var edited = settings.rules[0]; edited.mode = .regex
        edited.pattern = #"^(?<prefix>record=(?<key>\S+) )\[(?<index>\d+)/(?<total>\d+)\] (?<body>.*)$"#
        try settings.save(edited); try await wait(android, ios)
        for model in [android, ios] { XCTAssertEqual(model.selectedLog?.message, "record=x firstlast") }
        settings.remove(settings.rules[0].id); try await wait(android, ios)
        for model in [android, ios] { XCTAssertEqual(model.visible, [first, second, tail]) }
    }
    func testPausedViewportClearAndSavedSessionAreNotReplacedByOldRebuild() async throws {
        let (defaults, settings) = configuration(), rule = rule()
        let model = LogViewModel(defaults: defaults, mergeSettings: settings); defer { model.shutdown() }
        model.activateDevice("qa-device")
        model.ingest([entry(1, "record=x [1/2] a"), entry(2, "record=x [2/2] b")]); model.togglePause()
        try settings.save(rule); model.ingest([entry(3, "background")]); try await wait(model)
        XCTAssertTrue(model.paused); XCTAssertEqual(model.visible.map(\.message), ["ab"]); XCTAssertEqual(model.totalCount, 2)
        model.togglePause(); XCTAssertEqual(model.visible.count, 2)
        settings.setEnabled(rule.id, false)
        model.selectPackage("other", startCapture: false)
        model.ingest([entry(10, "other app")]); try await wait(model)
        XCTAssertEqual(model.visible.map(\.message), ["other app"])
        model.selectPackage("", startCapture: false); try await wait(model)
        XCTAssertEqual(model.visible.map(\.id), [1, 2, 3])
        settings.setEnabled(rule.id, true); model.clear(); model.ingest([entry(11, "after clear")]); try await wait(model)
        XCTAssertEqual(model.visible.map(\.message), ["after clear"])
    }
}
