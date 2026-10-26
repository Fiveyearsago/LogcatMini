import XCTest
@testable import LogcatCore

final class AutomationTests: XCTestCase {
    private func apk() throws -> APKInfo {
        try APKInspector.parse("package: name='com.example.demo' versionCode='42' versionName='1.2'\nsdkVersion:'26'\napplication-label:'Demo'\n", sha256: String(repeating: "a", count: 64))
    }
    private func result(_ count: Int = 3) throws -> AutomationResult {
        let suite = TestSuite(packageName: "com.example.demo", cases: (0..<count).map { AutomationCase(id: "CASE-\($0)") })
        return AutomationResult(name: "Run", apk: try apk(), apkFileName: "release.apk", serial: "test-device", deviceName: "Fixture", environment: "test", suite: suite)
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testReleaseMetadataAndSplitRejection() throws {
        let value = try apk()
        XCTAssertFalse(value.debuggable); XCTAssertEqual(value.versionCode, "42"); XCTAssertEqual(value.minimumSDK, 26)
        XCTAssertThrowsError(try APKInspector.parse("package: name='com.example.demo' versionCode='1' split='config.en'", sha256: "a"))
        XCTAssertThrowsError(try APKInspector.parse("package: name='com.example;bad' versionCode='1'", sha256: "a"))
    }
    func testModernAaptMinimumSDKDoesNotFallBackToAPI1OrTargetSDK() throws {
        let metadata = """
        package: name='com.example.demo' versionCode='42' versionName='1.2'
        minSdkVersion:'24'
        targetSdkVersion:'36'
        application-label:'Demo'
        """
        let value = try APKInspector.parse(metadata, sha256: String(repeating: "b", count: 64))
        XCTAssertEqual(value.minimumSDK, 24)
        XCTAssertEqual(value.packageName, "com.example.demo")
        XCTAssertFalse(value.debuggable)
    }
    func testAnimatedHierarchyPreservesCloseSelectorAndRejectsUnknownPasswordState() throws {
        let json = #"{"attributes":{},"children":[{"attributes":{"bounds":"[969,199][1056,286]","enabled":"true","accessibilityText":"default_close","resource-id":"ad_close"}},{"attributes":{"bounds":"[0,0][0,0]","text":"hidden"}}]}"#
        let elements = try AutomationDevice.parseMaestroHierarchy(json)
        XCTAssertEqual(elements.count, 1)
        XCTAssertTrue(elements[0].matches(TestTarget(contentDescription: "default_close")))
        XCTAssertEqual(elements[0].resourceID, "ad_close")
        XCTAssertTrue(elements[0].password, "Without a password flag this fallback must not permit text injection")
        XCTAssertThrowsError(try AutomationDevice.parseMaestroHierarchy("not a hierarchy"))
    }
    func testRepeatedActionCanBeLocatedBelowUniqueText() throws {
        let xml = """
        <hierarchy><node resource-id="action" text="Go" bounds="[800,100][1000,200]" enabled="true"/>
        <node text="Redeem (coins)" bounds="[200,230][650,280]"/>
        <node resource-id="action" text="Go" bounds="[800,300][1000,400]" enabled="true"/></hierarchy>
        """
        let elements = try AutomationDevice.parseHierarchy(xml)
        let target = TestTarget(id: "action", text: "Go", belowText: "Redeem (coins)")
        XCTAssertEqual(try AutomationDevice.matching(target, in: elements).map(\.bounds), ["[800,300][1000,400]"])
        XCTAssertTrue(try AutomationDevice.matching(TestTarget(id: "action", belowText: "Missing"), in: elements).isEmpty)
        XCTAssertThrowsError(try AutomationDevice.matching(target, in: elements + [elements[1]]))
        let yaml = AutomationDevice.flow(TestStep(action: .tap, target: target), package: "com.example.demo")
        XCTAssertTrue(yaml.contains("    below:\n      text: "))
        XCTAssertTrue(yaml.contains("Redeem \\\\(coins\\\\)"))
        var suite = TestSuite(packageName: "com.example.demo")
        suite.variables = ["anchor": TestVariable(value: "Redeem (coins)")]
        suite.cases[0].steps[0].action = .assertVisible
        suite.cases[0].steps[0].target = TestTarget(id: "action", belowText: "{{anchor}}")
        let decoded = try AutomationJSON.decode(TestSuite.self, from: AutomationJSON.encode(suite))
        XCTAssertEqual(try decoded.validated().cases[0].steps[0].target?.belowText, "Redeem (coins)")
    }
    func testInvalidCasesCannotLookPassed() throws {
        var suite = TestSuite(packageName: "com.example.demo")
        suite.cases[0].steps = [TestStep(action: .launchApp)]
        XCTAssertThrowsError(try suite.validated())
        suite.cases[0].steps = [TestStep(id: "../escape", action: .assertForeground)]
        XCTAssertThrowsError(try suite.validated())
        suite.cases[0].steps = [TestStep(id: "same", action: .assertForeground), TestStep(id: "same", action: .screenshot)]
        XCTAssertThrowsError(try suite.validated())
    }
    func testUnknownFieldCannotSilentlyChangeMeaning() throws {
        let data = try AutomationJSON.encode(TestSuite(packageName: "com.example.demo"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["runScript"] = "unexpected"
        XCTAssertThrowsError(try AutomationJSON.decode(TestSuite.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testVariablesAndLogsRequireValidObservationWindow() throws {
        var suite = TestSuite(packageName: "com.example.demo")
        suite.variables = ["label": TestVariable(value: "首页")]
        suite.cases[0].steps = [TestStep(id: "first", action: .assertText, target: TestTarget(id: "title"), expected: "{{label}}")]
        XCTAssertEqual(try suite.validated().cases[0].steps[0].expected, "首页")
        suite.cases[0].steps[0].expected = "{{missing}}"
        XCTAssertThrowsError(try suite.validated())
        var rule = TestStep(id: "log", action: .assertLog); rule.content = "saved"; rule.sinceStep = "future"
        suite.cases[0].steps = [rule, TestStep(id: "future", action: .assertForeground)]
        XCTAssertThrowsError(try suite.validated())
    }
    func testDangerousExpressionAndNonASCIIInputRejected() throws {
        var suite = TestSuite(packageName: "com.example.demo")
        let target = TestTarget(id: "input")
        suite.cases[0].steps.insert(TestStep(action: .inputText, target: target, text: "$" + "{output = 1}"), at: 0)
        XCTAssertThrowsError(try suite.validated())
        suite.cases[0].steps[0].text = "中文"
        XCTAssertThrowsError(try suite.validated())
        suite.cases[0].steps[0].text = "ASCII 123"
        XCTAssertNoThrow(try suite.validated())
    }
    func testHierarchyMatchesAllSelectorFields() throws {
        let xml = """
        <hierarchy><node resource-id="com.example:id/title" text="A &amp; B" content-desc="title" bounds="[0,0][100,100]" enabled="true"/><node text="hidden" bounds="[0,0][0,0]"/></hierarchy>
        """
        let elements = try AutomationDevice.parseHierarchy(xml)
        XCTAssertEqual(elements.count, 1)
        XCTAssertTrue(elements[0].matches(TestTarget(id: "com.example:id/title", text: "A & B", contentDescription: "title")))
        XCTAssertFalse(elements[0].matches(TestTarget(id: "com.example:id/title", text: "other")))
        XCTAssertThrowsError(try AutomationDevice.parseHierarchy("<broken"))
    }
    func testFlowEscapesRegexAndYAMLWithoutExpanding() {
        let step = TestStep(action: .tap, target: TestTarget(id: "com.demo:id/a.b", text: "a\"b\nc"))
        let yaml = AutomationDevice.flow(step, package: "com.example.demo")
        XCTAssertTrue(yaml.contains("a\\\\.b"))
        XCTAssertTrue(yaml.contains("a\\\"b\\nc"))
        XCTAssertTrue(yaml.contains("retryTapIfNoChange: false"))
        XCTAssertFalse(yaml.contains("\\\\\\/"), "JSON-only slash escapes must not reach the YAML parser")
        XCTAssertFalse(yaml.contains("launchApp"))
    }
    func testADBInputQuotesShellCharactersAndPreservesLiteralPercentS() {
        XCTAssertEqual(AutomationDevice.inputCommands("a b"), ["input text 'a%sb'"])
        XCTAssertEqual(AutomationDevice.inputCommands("%s"), ["input text '%'", "input text 's'"])
        XCTAssertEqual(AutomationDevice.inputCommands("a'b;$HOME"), ["input text 'a'\"'\"'b;$HOME'"])
    }
    func testInputVerificationRejectsIMECompositionAndPlaceholder() throws {
        func element(text: String, hint: String = "", password: Bool = false) throws -> AutomationElement {
            try XCTUnwrap(AutomationDevice.parseHierarchy("<hierarchy><node resource-id=\"input\" text=\"\(text)\" hint=\"\(hint)\" password=\"\(password)\" focused=\"true\" bounds=\"[0,0][100,100]\" enabled=\"true\"/></hierarchy>").first)
        }
        let pending = try element(text: "输入测试名称", hint: "输入测试名称")
        XCTAssertEqual(pending.inputValue, "")
        XCTAssertFalse(AutomationDevice.inputMatches(pending, expected: "LogcatMini"))
        XCTAssertFalse(AutomationDevice.inputMatches(pending, expected: "输入测试名称"))
        XCTAssertFalse(AutomationDevice.inputMatches(try element(text: "Log Cat Mini"), expected: "LogcatMini"))
        XCTAssertTrue(AutomationDevice.inputMatches(try element(text: "LogcatMini", hint: "输入测试名称"), expected: "LogcatMini"))
        XCTAssertTrue(AutomationDevice.inputMatches(try element(text: "OldLogcatMini"), expected: "OldLogcatMini"))
        XCTAssertFalse(AutomationDevice.inputMatches(try element(text: "LogcatMini", password: true), expected: "LogcatMini"))
    }
    func testPartialResultAndInterruptedRecoveryKeepFailure() throws {
        var value = try result()
        value.cases[0].status = .failed; value.cases[1].status = .running
        value.cases[1].steps[0].status = .running
        value.recoverInterrupted()
        XCTAssertEqual(value.count(.failed), 1); XCTAssertEqual(value.count(.blocked), 1); XCTAssertEqual(value.count(.notRun), 1)
        XCTAssertEqual(value.cases[1].steps[0].status, .blocked)
        XCTAssertEqual(value.verdict, "发现失败，验收未完成")
        XCTAssertFalse(value.isComplete)
    }
    func testReportDenominatorIncludesBlockedAndEscapesBusinessText() throws {
        var value = try result(); value.endedAt = Date()
        value.cases[0].status = .passed; value.cases[1].status = .failed; value.cases[2].status = .blocked
        value.cases[1].reason = "<script>|[link]\nnext"
        let markdown = AutomationReport.render(value, directory: try temporary())
        XCTAssertTrue(markdown.contains("1 / 3（33.3%）"))
        XCTAssertTrue(markdown.contains("2 / 3（66.7%）"))
        XCTAssertTrue(markdown.contains("&lt;script&gt;\\|\\[link\\]<br>next"))
        XCTAssertFalse(markdown.contains("所选用例通过"))
    }
    func testExportCopiesEvidenceButNotAPKOrEscapingSymlinks() throws {
        let root = try temporary(), source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("evidence"), withIntermediateDirectories: true)
        try Data("log".utf8).write(to: source.appendingPathComponent("evidence/step.log"))
        try Data("private-apk".utf8).write(to: source.appendingPathComponent("app.apk"))
        let outside = root.appendingPathComponent("outside.txt"); try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("evidence/escape"), withDestinationURL: outside)
        var value = try result(1); value.endedAt = Date(); value.cases[0].status = .passed
        value.artifacts = ["evidence/step.log", "app.apk", "evidence/escape", "../outside.txt"]
        try AutomationStorage.export(value, from: source, to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("evidence/step.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("app.apk").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("evidence/escape").path))
        XCTAssertEqual(try AutomationStorage.load(destination).cases[0].status, .passed)
    }
    func testCommandCancellationAndTimeoutAreNotAssertionFailures() async throws {
        let token = AutomationCancellation()
        let task = Task { try await AutomationProcess.run("/bin/sleep", ["10"], cancellation: token) }
        try await Task.sleep(nanoseconds: 150_000_000); token.cancel()
        do { _ = try await task.value; XCTFail("should cancel") }
        catch { XCTAssertEqual((error as? AutomationError)?.status, .cancelled) }
        do { _ = try await AutomationProcess.run("/bin/sleep", ["10"], timeout: 0.1); XCTFail("should timeout") }
        catch { XCTAssertEqual((error as? AutomationError)?.status, .blocked) }
    }
    func testPublishedSyntheticExamplesPassStrictImportValidation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["demo-startup-logs.json", "demo-related-button.json"] {
            let data = try Data(contentsOf: root.appendingPathComponent("docs/examples/" + name))
            let suite = try AutomationJSON.decode(TestSuite.self, from: data).validated()
            XCTAssertEqual(suite.app.packageName, "com.example.demo")
            XCTAssertFalse(suite.cases.isEmpty)
        }
    }

}
