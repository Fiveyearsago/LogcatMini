import XCTest
@testable import LogcatCore
@testable import LogcatMini

final class MediaLibraryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaLibraryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor func testFoldersAndHistorySurviveRelaunchAndChangingFolderKeepsOldRecords() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog.json")
        let library = MediaLibrary(catalogURL: catalog)
        try library.setDirectory(root, for: .screenshot, shareIfUnset: true)
        XCTAssertEqual(library.recordingDirectory, root)
        let image = try XCTUnwrap(library.destination(for: .screenshot, serial: "serial-a"))
        try Data([1, 2, 3]).write(to: image)
        library.add(kind: .screenshot, url: image, deviceName: "Phone A", serial: "serial-a", createdAt: Date())
        let second = root.appendingPathComponent("new recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try library.setDirectory(second, for: .recording)
        let restored = MediaLibrary(catalogURL: catalog)
        XCTAssertEqual(restored.records, library.records)
        XCTAssertEqual(restored.screenshotDirectory, root)
        XCTAssertEqual(restored.recordingDirectory, second)
        XCTAssertTrue(restored.records[0].exists)
        XCTAssertEqual(try restored.destination(for: .recording, serial: "b")?.deletingLastPathComponent(), second)
        try FileManager.default.removeItem(at: image)
        XCTAssertFalse(restored.records[0].exists)
        XCTAssertEqual(MediaLibrary(catalogURL: catalog).records.count, 1)
    }
    @MainActor func testRapidCapturesHaveDistinctSafeNamesAndMissingDirectoryNeverFallsBackSilently() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let library = MediaLibrary(catalogURL: root.appendingPathComponent("catalog.json"))
        try library.setDirectory(folder, for: .screenshot)
        let time = Date()
        let first = try XCTUnwrap(library.destination(for: .screenshot, serial: "a/b:123", now: time))
        let second = try XCTUnwrap(library.destination(for: .screenshot, serial: "a/b:123", now: time))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent(), folder)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("截图-a_b_123-"))
        try FileManager.default.removeItem(at: folder)
        XCTAssertThrowsError(try library.destination(for: .screenshot, serial: "a"))
        XCTAssertEqual(library.screenshotDirectory, folder)
        XCTAssertThrowsError(try library.setDirectory(root.appendingPathComponent("missing"), for: .screenshot))
    }
    @MainActor func testImportOlderCapturesOnlyAndRefreshDoesNotDuplicateOrReplaceMetadata() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog.json")
        let library = MediaLibrary(catalogURL: catalog)
        try library.setDirectory(root, for: .screenshot, shareIfUnset: true)
        for name in ["截图-device-20261013-140000.png", "录屏-device-20261013-140001.mp4", "personal.png", "other.mp4"] {
            try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
        }
        let image = root.appendingPathComponent("截图-device-20261013-140000.png")
        library.add(kind: .screenshot, url: image, deviceName: "Actual Phone", serial: "device", createdAt: Date())
        await library.refresh(); await library.refresh()
        XCTAssertEqual(library.records.count, 2)
        XCTAssertEqual(library.records.first { $0.kind == .screenshot }?.deviceName, "Actual Phone")
        XCTAssertEqual(MediaLibrary(catalogURL: catalog).records.count, 2)
    }
    @MainActor func testScreenshotSuccessRecordedAndFailureNotRecorded() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = MediaLibrary(catalogURL: root.appendingPathComponent("catalog.json"))
        try library.setDirectory(root, for: .screenshot)
        let adb = root.appendingPathComponent("fake-adb")
        let data = Data([137, 80, 78, 71, 13, 10, 26, 10] + Array(repeating: UInt8(0), count: 30))
        let png = root.appendingPathComponent("fixture.png"); try data.write(to: png)
        try "#!/bin/sh\ncat '\(png.path)'\n".write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let controller = DeviceMediaController(library: library)
        let device = AndroidDevice(id: "qa-device", name: "QA Phone", state: "device")
        controller.screenshot(path: adb.path, device: device)
        let finished = await controller.finishBeforeQuit()
        XCTAssertTrue(finished)
        XCTAssertEqual(library.records.count, 1)
        XCTAssertEqual(library.records[0].serial, "qa-device")
        XCTAssertEqual(library.records[0].url, controller.lastSaved)
        controller.screenshot(path: "/usr/bin/false", device: device)
        _ = await controller.finishBeforeQuit()
        XCTAssertEqual(library.records.count, 1); XCTAssertNotNil(controller.error)
    }
    @MainActor func testSystemAppsSettingSurvivesModelRelaunch() {
        let name = "MediaSettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LogViewModel(defaults: defaults)
        model.includeSystem = true; model.shutdown()
        XCTAssertTrue(LogViewModel(defaults: defaults).includeSystem)
    }
}
