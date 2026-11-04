import AppKit
import AVFoundation
import XCTest
import LogcatCore
@testable import LogcatMini

final class IOSParityTests: XCTestCase {
    private let simulator = IOSDevice(udid: "sim-qa", name: "QA Simulator", kind: .simulator)
    private let phone = IOSDevice(udid: "phone-qa", name: "QA Phone", kind: .usb)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IOSParity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func app(at root: URL, id: String = "com.example.qa", platform: String = "iPhoneSimulator") throws -> URL {
        let app = root.appendingPathComponent("Runner.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Runner", "CFBundleSupportedPlatforms": [platform]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let binary = app.appendingPathComponent("Runner")
        try Data("synthetic fixture".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return app
    }
    func testDeviceAppsUseBundleIdentityAndPreserveSystemFlag() throws {
        let json = #"{"result":{"apps":[{"bundleIdentifier":"com.example.qa","name":"开发版","url":"file:///private/Apps/Runner.app/","defaultApp":false},{"bundleIdentifier":"com.apple.sample","name":"系统","executableName":"Executable","defaultApp":true}]}}"#
        let apps = try IOSLogProcess.installedDeviceApps(Data(json.utf8))
        XCTAssertEqual(apps.first { $0.id == "com.example.qa" }?.executable, "Runner")
        XCTAssertTrue(try XCTUnwrap(apps.first { $0.id == "com.apple.sample" }).isSystem)
        let path = #"/Apps/a"quoted/Runner.app/Runner"#
        let predicate = IOSTools.streamArguments(device: simulator, process: "Runner", processPath: path)
        XCTAssertEqual(Array(predicate.suffix(2)), ["--predicate", #"processImagePath == "/Apps/a\"quoted/Runner.app/Runner""#])
    }
    @MainActor func testSameNamedFlutterAppsKeepSeparateSessionsAndPersistFavorites() throws {
        let suite = "IOSParity." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ios = IOSLogViewModel(defaults: defaults)
        let a = IOSLogProcess(id: "com.example.a", name: "App A", executable: "Runner")
        let b = IOSLogProcess(id: "com.example.b", name: "App B", executable: "Runner")
        ios.logs.activateDevice(simulator.id); ios.selectApp(a); ios.toggleFavorite(a)
        ios.logs.ingest([.init(id: 1, date: "", time: "", pid: "1", tid: "1", level: .info, tag: "Runner", message: "App A", raw: "App A")])
        ios.logs.query = "App A"; ios.logs.rememberFilter(); ios.logs.toggleFilterFavorite()
        ios.selectApp(b); XCTAssertEqual(ios.logs.totalCount, 0); XCTAssertEqual(ios.logs.query, "")
        ios.selectApp(a); XCTAssertEqual(ios.logs.visible.map(\.message), ["App A"]); XCTAssertEqual(ios.logs.query, "App A")
        let restored = IOSLogViewModel(defaults: defaults)
        XCTAssertTrue(restored.logs.favorites.contains(a.id)); XCTAssertEqual(restored.favoriteApps, [a])
        XCTAssertEqual(restored.logs.filterHistory.favorites.count, 1)
        ios.shutdown(); restored.shutdown()
    }
    func testBuildRejectsWrongBundlePlatformAndSimulatorRelease() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try app(at: root)
        XCTAssertNoThrow(try IOSBuildProject.verifyApp(artifact, bundleID: "com.example.qa", device: simulator))
        XCTAssertThrowsError(try IOSBuildProject.verifyApp(artifact, bundleID: "com.example.other", device: simulator))
        XCTAssertThrowsError(try IOSBuildProject.verifyApp(artifact, bundleID: "com.example.qa", device: phone))
        var project = IOSBuildProject(); project.mode = "release"
        XCTAssertThrowsError(try project.flutterArguments(device: simulator))
        project.mode = "debug"; project.defines = "NAME=中文 $(echo ignored)\nMODE=qa"; project.flavor = "dev"
        let args = try project.flutterArguments(device: simulator)
        XCTAssertTrue(args.contains("--simulator")); XCTAssertTrue(args.contains("NAME=中文 $(echo ignored)"))
        XCTAssertEqual(args.filter { $0 == "--dart-define" }.count, 2)
    }
    func testXcodeProductSkipsDiagnosticBracketsAndRejectsAmbiguousTargets() throws {
        let target: [String: Any] = ["buildSettings": ["PRODUCT_BUNDLE_IDENTIFIER": "com.example.qa", "WRAPPER_EXTENSION": "app", "TARGET_BUILD_DIR": "/tmp/QA build", "FULL_PRODUCT_NAME": "Probe.app"]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [target]), as: UTF8.self)
        XCTAssertEqual(try IOSBuildProject.xcodeProduct("2026-11-04 xcodebuild[123] [MT] warning\n" + json, bundleID: "com.example.qa").path, "/tmp/QA build/Probe.app")
        let ambiguous = String(decoding: try JSONSerialization.data(withJSONObject: [target, target]), as: UTF8.self)
        XCTAssertThrowsError(try IOSBuildProject.xcodeProduct(ambiguous, bundleID: "com.example.qa"))
    }
    @MainActor func testCancellationBeforeBuildReturnsDoesNotInstall() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("name: synthetic".utf8).write(to: root.appendingPathComponent("pubspec.yaml"))
        let suite = "IOSCancel." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let builds = IOSBuildController(defaults: defaults) { _, _ in calls += 1; try await Task.sleep(nanoseconds: 3_000_000_000); return .init(status: 0, output: "") }
        XCTAssertTrue(builds.start(.init(bundleID: "com.example.qa", directory: root.path, flutterPath: "/usr/bin/true"), device: simulator))
        while calls == 0 { await Task.yield() }
        builds.cancel(); await builds.waitUntilFinished()
        XCTAssertEqual(calls, 1); XCTAssertEqual(builds.status, "已取消"); XCTAssertFalse(builds.busy)
    }
    @MainActor func testInstallSnapshotsArtifactAndPinsTargetThroughCallbacks() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try app(at: root), suite = "IOSBuild." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        var calls: [[String]] = []; var installed = false
        let target = simulator
        let builds = IOSBuildController(defaults: defaults) { command, _ in
            calls.append(command.arguments)
            if command.arguments.contains("install") {
                let snapshot = URL(fileURLWithPath: try XCTUnwrap(command.arguments.last))
                XCTAssertNotEqual(snapshot, artifact)
                try IOSBuildProject.verifyApp(snapshot, bundleID: "com.example.qa", device: target)
            }
            if command.arguments.contains("launch") { XCTAssertTrue(installed) }
            return .init(status: 0, output: "OK")
        }
        builds.onInstalled = { device, id in
            XCTAssertEqual(device, target); XCTAssertEqual(id, "com.example.qa"); installed = true
            builds.draft.bundleID = "com.example.changed"
        }
        XCTAssertTrue(builds.installExisting(artifact, device: target)); XCTAssertFalse(builds.installExisting(artifact, device: phone))
        await builds.waitUntilFinished()
        XCTAssertEqual(builds.status, "已运行"); XCTAssertNil(builds.error)
        XCTAssertEqual(Array(calls.last!.suffix(2)), [target.udid, "com.example.qa"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.first!.last!))
    }
    @MainActor func testFailedInstallNeverLaunchesAndWrongPlatformNeverRuns() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try app(at: root), suite = "IOSBuild." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        var calls: [[String]] = []
        let builds = IOSBuildController(defaults: defaults) { command, _ in calls.append(command.arguments); return .init(status: 1, output: "synthetic install failure") }
        XCTAssertFalse(builds.installExisting(artifact, device: phone)); XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(builds.installExisting(artifact, device: simulator)); await builds.waitUntilFinished()
        XCTAssertEqual(calls.count, 1); XCTAssertFalse(calls[0].contains("launch")); XCTAssertEqual(builds.status, "失败")
    }
    @MainActor func testFlutterBuildFailureDoesNotInstallStaleArtifact() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("name: synthetic\n".utf8).write(to: root.appendingPathComponent("pubspec.yaml"))
        _ = try app(at: root.appendingPathComponent("build/ios/iphonesimulator"))
        let suite = "IOSBuild." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls: [[String]] = []
        let builds = IOSBuildController(defaults: defaults) { command, _ in calls.append(command.arguments); return .init(status: 1, output: "synthetic compiler failure") }
        let project = IOSBuildProject(bundleID: "com.example.qa", directory: root.path, flutterPath: "/usr/bin/true")
        XCTAssertTrue(builds.start(project, device: simulator)); await builds.waitUntilFinished()
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(builds.status, "失败")
    }
    @MainActor func testOptInFlutterBuildInstallAndLaunch() async throws {
        guard let udid = ProcessInfo.processInfo.environment["LOGCAT_MINI_IOS_SIMULATOR_QA"],
              let flutter = ProcessInfo.processInfo.environment["LOGCAT_MINI_FLUTTER_QA"] else { throw XCTSkip("Requires booted simulator and Flutter SDK") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("flutter"), id = "com.logcatmini.qa.iosprobe"
        let runner = BuildProcessRunner()
        let created = try await runner.run(.init(executable: flutter, arguments: ["create", "--platforms=ios", "--org", "com.logcatmini.qa", "--project-name", "iosprobe", "--no-pub", "--empty", source.path], environment: IOSBuildProject.toolEnvironment, timeout: 120), output: { _ in })
        XCTAssertEqual(created.status, 0, created.output)
        let resolved = try await runner.run(.init(executable: flutter, arguments: ["pub", "get", "--offline"], directory: source, environment: IOSBuildProject.toolEnvironment, timeout: 120), output: { _ in })
        XCTAssertEqual(resolved.status, 0, resolved.output)
        let suite = "IOSFlutterBuild." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let builds = IOSBuildController(defaults: defaults)
        let device = IOSDevice(udid: udid, name: "QA Simulator", kind: .simulator)
        let project = IOSBuildProject(bundleID: id, directory: source.path, flutterPath: flutter)
        XCTAssertTrue(builds.start(project, device: device)); await builds.waitUntilFinished()
        XCTAssertEqual(builds.status, "已运行", "\(builds.error ?? "")\n\(builds.output.suffix(6000))")
        let apps = try await IOSDeviceService.xcrun(["simctl", "listapps", udid])
        XCTAssertTrue(try IOSLogProcess.simulatorApps(Data(apps.utf8)).contains { $0.id == id && $0.executable == "Runner" })
        _ = try? await IOSDeviceService.xcrun(["simctl", "uninstall", udid, id])
    }
    @MainActor func testOptInXcodeBuildInstallLaunchAndAppScopedCapture() async throws {
        guard let udid = ProcessInfo.processInfo.environment["LOGCAT_MINI_IOS_SIMULATOR_QA"] else { throw XCTSkip("Requires a booted simulator") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/IOSBuildProbe")
        let source = root.appendingPathComponent("Probe")
        try FileManager.default.copyItem(at: fixture, to: source)
        let suite = "IOSLiveBuild." + UUID().uuidString, id = "com.logcatmini.qa.buildprobe"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ios = IOSLogViewModel(defaults: defaults); defer { ios.shutdown() }
        await ios.refreshDevices(); await ios.selectDevice("simulator:" + udid); ios.begin()
        let device = try XCTUnwrap(ios.device)
        var project = IOSBuildProject(bundleID: id, directory: source.path, kind: .xcode)
        project.container = source.appendingPathComponent("Probe.xcodeproj").path; project.scheme = "Probe"
        let builds = ios.builds
        XCTAssertTrue(builds.start(project, device: device)); await builds.waitUntilFinished()
        XCTAssertEqual(builds.status, "已运行", "\(builds.error ?? "")\n\(builds.output.suffix(6000))")
        if builds.status == "已运行" {
            for _ in 0..<30 {
                if ios.logs.visible.contains(where: { $0.message.contains("LOGCAT_MINI_APP_PATH_QA") }) { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            XCTAssertEqual(ios.logs.selectedPackage, id)
            XCTAssertTrue(ios.logs.visible.contains { $0.message.contains("LOGCAT_MINI_APP_PATH_QA") }, "App-path predicate did not capture the fixture's launch log")
        }
        ios.stop()
        _ = try? await IOSDeviceService.xcrun(["simctl", "uninstall", udid, id])
    }
    @MainActor func testOptInSimulatorScreenshotPreviewRecordingAndClipboard() async throws {
        guard let udid = ProcessInfo.processInfo.environment["LOGCAT_MINI_IOS_SIMULATOR_QA"] else { throw XCTSkip("Requires a booted simulator") }
        let device = IOSDevice(udid: udid, name: "QA Simulator", kind: .simulator)
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let screenshot = root.appendingPathComponent("capture.png")
        try await IOSDeviceService.screenshot(device, to: screenshot)
        XCTAssertGreaterThan(try XCTUnwrap(NSImage(contentsOf: screenshot)).size.height, 100)
        let preview = IOSPreviewController(); preview.connect(device)
        for _ in 0..<40 { if preview.image != nil || preview.error != nil { break }; try await Task.sleep(nanoseconds: 250_000_000) }
        XCTAssertNotNil(preview.image, preview.error ?? "No preview image")
        preview.stop(); XCTAssertNil(preview.image); XCTAssertNil(preview.target)
        try await Task.sleep(nanoseconds: 300_000_000); XCTAssertNil(preview.image)
        let library = MediaLibrary(catalogURL: root.appendingPathComponent("history.json"))
        try library.setDirectory(root, for: .recording)
        let media = IOSMediaController(library: library)
        media.startRecording(device); XCTAssertTrue(media.recording)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        media.stopRecording(); let saved = await media.finishBeforeQuit()
        XCTAssertTrue(saved, media.error ?? "Save failed"); XCTAssertFalse(media.recording); XCTAssertFalse(media.saving)
        let record = try XCTUnwrap(library.records.first)
        XCTAssertEqual(record.serial, device.id); XCTAssertEqual(record.kind, .recording)
        let asset = AVURLAsset(url: record.url), duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        // Dedicated named boards avoid touching the user's general clipboard on either side.
        let name = "LogcatMiniQA-" + UUID().uuidString
        let board = NSPasteboard(name: .init(name)); defer { board.releaseGlobally() }
        board.setString("中文\nclipboard QA", forType: .string)
        _ = try await IOSDeviceService.xcrun(["devicectl", "device", "pasteboard", "transfer", "to", "--device", udid, "--host-pasteboard", name, "--device-pasteboard", name, "--data-policy", "all-resolved", "--quiet"])
        board.clearContents()
        _ = try await IOSDeviceService.xcrun(["devicectl", "device", "pasteboard", "transfer", "from", "--device", udid, "--host-pasteboard", name, "--device-pasteboard", name, "--data-policy", "all-resolved", "--quiet"])
        XCTAssertEqual(board.string(forType: .string), "中文\nclipboard QA")
    }
}
