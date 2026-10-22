import XCTest
@testable import LogcatMini

final class LocalBuildTests: XCTestCase {
    @MainActor func testBranchRefreshOnlyReadsGitAndHandlesDetachedOrNonGit() async {
        var reply = BuildProcessRunner.Result(status: 0, output: "feature/example\n")
        let controller = LocalBuildController { command, _ in
            XCTAssertEqual(command.executable, "/usr/bin/git")
            XCTAssertEqual(command.arguments, ["-C", "/tmp/example", "branch", "--show-current"])
            return reply
        }
        controller.draft.directory = "/tmp/example"
        await controller.refreshBranch(); XCTAssertEqual(controller.branch, "feature/example")
        reply = .init(status: 0, output: "\n")
        await controller.refreshBranch(); XCTAssertEqual(controller.branch, "detached HEAD")
        reply = .init(status: 128, output: "not a git repository")
        await controller.refreshBranch(); XCTAssertEqual(controller.branch, "非 Git 项目")
        controller.draft.directory = ""
        await controller.refreshBranch(); XCTAssertEqual(controller.branch, "")
    }
    @MainActor func testLateBranchResultCannotOverwriteAnotherProject() async {
        var resume: CheckedContinuation<BuildProcessRunner.Result, Never>?
        let controller = LocalBuildController { _, _ in await withCheckedContinuation { resume = $0 } }
        controller.draft.directory = "/tmp/old-project"
        let refresh = Task { await controller.refreshBranch() }
        while resume == nil { await Task.yield() }
        controller.edit("com.example.other")
        resume?.resume(returning: .init(status: 0, output: "old-branch"))
        await refresh.value
        XCTAssertEqual(controller.branch, "")
    }
    private func fixture(package: String = "com.example.build") throws -> (URL, LocalBuildProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("build QA $(literal)-" + UUID().uuidString)
        for path in ["app/build/outputs/apk/debug", "jdk/bin", "sdk/platform-tools", "sdk/build-tools/36.0"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: root.appendingPathComponent("gradlew"))
        for path in ["jdk/bin/java", "sdk/platform-tools/adb", "sdk/build-tools/36.0/aapt2"] {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(path), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        }
        let metadata = "{\"applicationId\":\"\(package)\",\"variantName\":\"debug\",\"elements\":[{\"outputFile\":\"App space.apk\",\"filters\":[]}]}"
        try Data(metadata.utf8).write(to: root.appendingPathComponent("app/build/outputs/apk/debug/output-metadata.json"))
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: root.appendingPathComponent("app/build/outputs/apk/debug/App space.apk"))
        return (root, LocalBuildProject(packageID: "com.example.build", directory: root.path, javaHome: root.appendingPathComponent("jdk").path, sdkRoot: root.appendingPathComponent("sdk").path))
    }
    func testArtifactRejectsWrongPackageSplitAndEscapingPaths() throws {
        let (root, project) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try project.artifact().lastPathComponent, "App space.apk")
        let metadata = root.appendingPathComponent("app/build/outputs/apk/debug/output-metadata.json")
        for text in [
            #"{"applicationId":"com.other.app","variantName":"debug","elements":[{"outputFile":"App space.apk","filters":[]}]}"#,
            #"{"applicationId":"com.example.build","variantName":"debug","elements":[{"outputFile":"App space.apk","filters":[{}]}]}"#,
            #"{"applicationId":"com.example.build","variantName":"debug","elements":[{"outputFile":"../../../../../../../outside.apk","filters":[]}]}"#,
            #"{"applicationId":"com.example.build","variantName":"release","elements":[{"outputFile":"App space.apk","filters":[]}]}"#
        ] {
            try Data(text.utf8).write(to: metadata)
            XCTAssertThrowsError(try project.artifact())
        }
    }
    func testMemoryModePreservesRequiredJVMFlagsAndExactPathArguments() throws {
        let (root, project) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "org.gradle.jvmargs=-Xmx8192M --add-opens=java.base/java.lang=ALL-UNNAMED\n".write(to: root.appendingPathComponent("gradle.properties"), atomically: true, encoding: .utf8)
        XCTAssertEqual(project.buildArguments.first, root.appendingPathComponent("gradlew").path)
        XCTAssertTrue(project.buildArguments.contains(":app:assembleDebug"))
        XCTAssertTrue(project.buildArguments.contains("--no-daemon"))
        let jvm = try XCTUnwrap(project.buildArguments.first { $0.hasPrefix("-Dorg.gradle.jvmargs=") })
        XCTAssertTrue(jvm.contains("-Xmx3g")); XCTAssertFalse(jvm.contains("-Xmx8192M"))
        // User Gradle properties have precedence; only assert project flags when no user override exists.
        if LocalBuildProject.properties(at: URL(fileURLWithPath: NSHomeDirectory() + "/.gradle/gradle.properties"))["org.gradle.jvmargs"] == nil {
            XCTAssertTrue(jvm.contains("--add-opens=java.base/java.lang=ALL-UNNAMED"))
        }
        var invalid = project; invalid.module = "app;touch /tmp/no"
        XCTAssertThrowsError(try invalid.validate())
    }
    @MainActor func testAssociationPersistsAndCanBeRemoved() throws {
        let (root, project) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "BuildTests-" + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let controller = LocalBuildController(defaults: isolated)
        XCTAssertTrue(controller.save(project))
        XCTAssertEqual(LocalBuildController(defaults: isolated).project(for: project.packageID), project)
        controller.remove(project.packageID)
        XCTAssertTrue(LocalBuildController(defaults: isolated).projects.isEmpty)
    }
    @MainActor func testPipelineCapturesDeviceAndStartsOnlyAfterInstallCallback() async throws {
        let (root, project) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var calls: [[String]] = [], logsReady = false
        let controller = LocalBuildController { command, output in
            calls.append(command.arguments)
            output("test output\n")
            if command.arguments.contains("get-state") { return .init(status: 0, output: "device\n") }
            if command.executable == "/usr/bin/git" { return .init(status: 0, output: "test-branch\n") }
            if command.arguments.contains("badging") { return .init(status: 0, output: "package: name='com.example.build' versionCode='1'\n") }
            if command.arguments.contains("install") { return .init(status: 0, output: "Success\n") }
            if command.arguments.contains("resolve-activity") { return .init(status: 0, output: "com.example.build/.MainActivity\n") }
            if command.arguments.contains("start") { XCTAssertTrue(logsReady); return .init(status: 0, output: "Status: ok\n") }
            if command.arguments.contains("pidof") { return .init(status: 0, output: "1234\n") }
            return .init(status: 0, output: "BUILD SUCCESSFUL\n")
        }
        controller.onInstalled = { target, package in
            XCTAssertEqual(target.serial, "phone-A"); XCTAssertEqual(package, project.packageID); logsReady = true
        }
        let target = LocalBuildController.Target(adb: project.sdkRoot + "/platform-tools/adb", serial: "phone-A", name: "Test phone")
        XCTAssertTrue(controller.start(project, target: target))
        XCTAssertFalse(controller.start(project, target: .init(adb: target.adb, serial: "phone-B", name: "Other")))
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.stage, .succeeded, controller.message)
        XCTAssertTrue(controller.installed)
        for args in calls where args.first == "-s" { XCTAssertEqual(args[1], "phone-A") }
        XCTAssertTrue(calls.contains { $0.starts(with: ["-s", "phone-A", "install", "-r"]) })
        XCTAssertFalse(calls.contains { $0.contains("uninstall") || $0.contains("clear") })
    }
    @MainActor func testBuildFailureCannotInstallOldArtifact() async throws {
        let (root, project) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = LocalBuildController { command, _ in
            if command.arguments.contains("install") { XCTFail("Must not install a stale APK after failure") }
            if command.arguments.contains(project.task) { return .init(status: 1, output: "Compilation error") }
            return .init(status: 0, output: command.arguments.contains("get-state") ? "device\n" : "test\n")
        }
        XCTAssertTrue(controller.start(project, target: .init(adb: project.sdkRoot + "/platform-tools/adb", serial: "A", name: "A")))
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.stage, .failed); XCTAssertFalse(controller.installed)
        XCTAssertTrue(controller.message.contains("Compilation error"))
        XCTAssertEqual(controller.failedStage, .building)
    }
    @MainActor func testInstallFailureNeverLaunchesOrUninstalls() async throws {
        let (root, project) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = LocalBuildController { command, _ in
            XCTAssertFalse(command.arguments.contains("uninstall")); XCTAssertFalse(command.arguments.contains("start"))
            if command.arguments.contains("get-state") { return .init(status: 0, output: "device\n") }
            if command.arguments.contains("badging") { return .init(status: 0, output: "package: name='com.example.build' versionCode='1'\n") }
            if command.arguments.contains("install") { return .init(status: 0, output: "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]\n") }
            return .init(status: 0, output: "ok\n")
        }
        controller.onInstalled = { _, _ in XCTFail("Install failure must not switch capture") }
        XCTAssertTrue(controller.start(project, target: .init(adb: project.sdkRoot + "/platform-tools/adb", serial: "A", name: "A")))
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.stage, .failed); XCTAssertFalse(controller.installed)
        XCTAssertTrue(controller.message.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE"))
        XCTAssertEqual(controller.failedStage, .installing)
    }
    func testProcessArgumentsAreLiteralAndOutputIsStreamed() async throws {
        let runner = BuildProcessRunner()
        let literal = "space $(touch /tmp/should-not-run) `literal` 中文"
        let result = try await runner.run(.init(executable: "/usr/bin/printf", arguments: ["%s\\n", literal], timeout: 5), output: { _ in })
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), literal)
        let failed = try await runner.run(.init(executable: "/bin/bash", arguments: ["-c", "echo compile-error >&2; exit 7"], timeout: 5), output: { _ in })
        XCTAssertEqual(failed.status, 7); XCTAssertTrue(failed.output.contains("compile-error"))
    }
    @MainActor func testLaunchFailureIsDistinctFromSuccessfulInstallation() async throws {
        let (root, project) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = LocalBuildController { command, _ in
            if command.arguments.contains("get-state") { return .init(status: 0, output: "device\n") }
            if command.arguments.contains("badging") { return .init(status: 0, output: "package: name='com.example.build' versionCode='1'\n") }
            if command.arguments.contains("install") { return .init(status: 0, output: "Success\n") }
            if command.arguments.contains("resolve-activity") { return .init(status: 0, output: "com.example.build/.MainActivity\n") }
            if command.arguments.contains("start") { return .init(status: 0, output: "Error: Activity class does not exist.\n") }
            if command.arguments.contains("pidof") { XCTFail("Must not claim a running process after launch error") }
            return .init(status: 0, output: "ok\n")
        }
        XCTAssertTrue(controller.start(project, target: .init(adb: project.sdkRoot + "/platform-tools/adb", serial: "A", name: "A")))
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.stage, .failed); XCTAssertTrue(controller.installed)
        XCTAssertTrue(controller.message.contains("APK 已安装"))
    }
    @MainActor func testCancelDuringBuildCannotInstallAndProjectLockRejectsAnotherRun() async throws {
        let (root, project) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "build started")
        let controller = LocalBuildController { command, _ in
            if command.arguments.contains("install") { XCTFail("Cancelled build must never install") }
            if command.arguments.contains("get-state") { return .init(status: 0, output: "device\n") }
            if command.arguments.contains(project.task) { started.fulfill(); try await Task.sleep(nanoseconds: 30_000_000_000) }
            return .init(status: 0, output: "ok\n")
        }
        let target = LocalBuildController.Target(adb: project.sdkRoot + "/platform-tools/adb", serial: "A", name: "A")
        XCTAssertTrue(controller.start(project, target: target))
        await fulfillment(of: [started], timeout: 3)
        let another = LocalBuildController { _, _ in XCTFail("Project lock must be acquired before running any commands"); return .init(status: 0, output: "") }
        XCTAssertTrue(another.start(project, target: target)); await another.waitUntilFinished()
        XCTAssertEqual(another.stage, .failed); XCTAssertTrue(another.message.contains("另一个"))
        controller.cancel(); await controller.waitUntilFinished()
        XCTAssertEqual(controller.stage, .cancelled); XCTAssertFalse(controller.installed)
    }
    @MainActor func testInstallerConflictStopsBeforeBuild() throws {
        let (root, project) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = LocalBuildController { _, _ in XCTFail("Must not run while another installer owns the device"); return .init(status: 0, output: "") }
        controller.installationAllowed = { false }
        XCTAssertFalse(controller.start(project, target: .init(adb: project.sdkRoot + "/platform-tools/adb", serial: "A", name: "A")))
        XCTAssertNotNil(controller.configurationError)
    }
    func testProcessCancellationAndTimeoutStopChildren() async throws {
        let runner = BuildProcessRunner()
        let task = Task { try await runner.run(.init(executable: "/bin/bash", arguments: ["-c", "sleep 60 & wait"], timeout: 10), output: { _ in }) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        do {
            _ = try await runner.run(.init(executable: "/bin/sleep", arguments: ["60"], timeout: 0.15), output: { _ in })
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
    }
    private var discoveryOutput: String {
        "Gradle configuration output\n" + [
            #"{"name":"demoFreeDebug","applicationId":"com.example.build","buildType":"debug","flavors":[{"dimension":"product","name":"demo"},{"dimension":"tier","name":"free"}]}"#,
            #"{"name":"demoFreeRelease","applicationId":"com.example.release","buildType":"release","flavors":[{"dimension":"product","name":"demo"},{"dimension":"tier","name":"free"}]}"#,
            #"{"name":"otherFreeDebug","applicationId":"com.other.app.debug","buildType":"debug","flavors":[{"dimension":"product","name":"other"},{"dimension":"tier","name":"free"}]}"#
        ].map { LocalBuildVariant.marker + $0 }.joined(separator: "\n") + "\nBUILD SUCCESSFUL\n"
    }
    func testVariantDiscoveryRejectsInvalidOrAmbiguousOutput() throws {
        let variants = try LocalBuildVariant.parse(discoveryOutput)
        XCTAssertEqual(variants.count, 3)
        XCTAssertEqual(variants[0].flavorLabel, "demo / free")
        XCTAssertEqual(variants[1].applicationId, "com.example.release")
        for output in ["BUILD SUCCESSFUL", discoveryOutput + discoveryOutput,
                       discoveryOutput.replacingOccurrences(of: "demoFreeDebug", with: "demo;exit"),
                       discoveryOutput.replacingOccurrences(of: "com.example.build", with: "bad/package")] {
            XCTAssertThrowsError(try LocalBuildVariant.parse(output))
        }
        let plain = try LocalBuildVariant.parse(LocalBuildVariant.marker + #"{"name":"debug","applicationId":"com.plain.app","buildType":"debug","flavors":[]}"#)
        XCTAssertEqual(plain.first?.flavorLabel, "无 Flavor")
    }
    @MainActor func testDiscoverySelectsExactFlavorIdentityAndPersistsWithoutChangingOtherAssociations() async throws {
        let (root, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "FlavorTests-" + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var scriptURL: URL?; let output = discoveryOutput
        let controller = LocalBuildController(defaults: defaults) { command, _ in
            if command.executable == "/usr/bin/git" { return .init(status: 0, output: "flavor-branch\n") }
            XCTAssertTrue(command.arguments.contains(":nested:app:" + LocalBuildVariant.taskName))
            XCTAssertTrue(command.arguments.contains("--no-configuration-cache"))
            XCTAssertFalse(command.arguments.contains("install"))
            scriptURL = URL(fileURLWithPath: command.arguments[command.arguments.firstIndex(of: "--init-script")! + 1])
            XCTAssertTrue(try String(contentsOf: scriptURL!, encoding: .utf8).contains("components.onVariants"))
            return .init(status: 0, output: output)
        }
        XCTAssertTrue(controller.save(original))
        controller.draft.module = "nested:app"
        controller.refreshVariants(); await controller.waitForDetection()
        XCTAssertNil(controller.configurationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(scriptURL).path))
        XCTAssertEqual(controller.branch, "flavor-branch")
        XCTAssertEqual(controller.draft.variant, "demoFreeDebug")
        controller.selectVariant("demoFreeRelease")
        XCTAssertEqual(controller.draft.packageID, "com.example.release")
        // The other flavor has no release variant; choose an enabled combination instead of inventing one.
        controller.selectFlavor("product=other|tier=free")
        XCTAssertEqual(controller.draft.task, ":nested:app:assembleOtherFreeDebug")
        XCTAssertEqual(controller.draft.packageID, "com.other.app.debug")
        XCTAssertTrue(controller.save(controller.draft))
        let restored = LocalBuildController(defaults: defaults)
        XCTAssertEqual(restored.projects.count, 2)
        XCTAssertEqual(restored.project(for: original.packageID), original)
        XCTAssertEqual(restored.project(for: "com.other.app.debug")?.selectedVariant?.name, "otherFreeDebug")
        var moved = controller.draft; moved.module = "other"
        XCTAssertTrue(moved.availableVariants.isEmpty)
    }
    @MainActor func testDiscoveryFailureClearsCatalogButKeepsCurrentConfiguration() async throws {
        let (root, project) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = LocalBuildController { _, _ in .init(status: 1, output: "dependency unavailable") }
        controller.draft = project
        controller.draft.variantCatalog = try LocalBuildVariant.parse(discoveryOutput)
        controller.draft.variantCatalogScope = project.catalogScope
        controller.refreshVariants(); await controller.waitForDetection()
        XCTAssertTrue(controller.draft.availableVariants.isEmpty)
        XCTAssertEqual(controller.draft.packageID, project.packageID)
        XCTAssertEqual(controller.draft.variant, "debug")
        XCTAssertTrue(controller.configurationError?.contains("dependency unavailable") == true)
    }
    @MainActor func testCancelledDiscoveryCannotOverwriteNewDraft() async throws {
        let (root, project) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "discovery started")
        var resume: CheckedContinuation<BuildProcessRunner.Result, Never>?
        let controller = LocalBuildController { command, _ in
            if command.executable == "/usr/bin/git" { return .init(status: 0, output: "test\n") }
            return await withCheckedContinuation { resume = $0; started.fulfill() }
        }
        controller.draft = project; controller.refreshVariants()
        await fulfillment(of: [started], timeout: 3)
        controller.edit("com.new.app")
        resume?.resume(returning: .init(status: 0, output: discoveryOutput))
        await controller.waitForDetection()
        XCTAssertEqual(controller.draft.packageID, "com.new.app")
        XCTAssertTrue(controller.draft.directory.isEmpty)
        XCTAssertTrue(controller.draft.availableVariants.isEmpty)
        XCTAssertNil(controller.configurationError)
    }
    func testOldAssociationsStillDecodeWithoutCatalog() throws {
        let project = try JSONDecoder().decode(LocalBuildProject.self, from: Data(#"{"packageID":"com.example.build","directory":"/tmp/project","module":"app","variant":"debug","javaHome":"/tmp/jdk","sdkRoot":"/tmp/sdk","lowMemory":true}"#.utf8))
        XCTAssertTrue(project.availableVariants.isEmpty)
        XCTAssertEqual(project.task, ":app:assembleDebug")
    }
}
