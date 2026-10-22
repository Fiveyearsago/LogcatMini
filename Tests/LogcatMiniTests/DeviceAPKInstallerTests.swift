import XCTest
import LogcatCore
@testable import LogcatMini

final class DeviceAPKInstallerTests: XCTestCase {
    @MainActor func testRealDeviceInstallWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serial = environment["LOGCAT_MINI_MIRROR_DEVICE"],
              let apk = environment["LOGCAT_MINI_INSTALL_APK"], let path = ADB.locate() else {
            throw XCTSkip("Set LOGCAT_MINI_MIRROR_DEVICE and LOGCAT_MINI_INSTALL_APK to enable physical APK installation QA")
        }
        let installer = DeviceAPKInstaller()
        XCTAssertTrue(installer.install(URL(fileURLWithPath: apk), on: APKInstallTarget(path: path, serial: serial, name: "Pixel QA")))
        await installer.waitUntilFinished()
        XCTAssertFalse(installer.failed, installer.message ?? "No install result")
        XCTAssertFalse(installer.isInstalling)
        XCTAssertTrue(installer.message?.hasPrefix("已安装") == true)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apk-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("测试 app $(literal).APK")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: file)
        return file
    }

    func testAcceptsOnlyOneLocalAPK() {
        let apk = URL(fileURLWithPath: "/tmp/test.APK")
        XCTAssertTrue(DeviceAPKInstaller.accepts([apk]))
        XCTAssertFalse(DeviceAPKInstaller.accepts([]))
        XCTAssertFalse(DeviceAPKInstaller.accepts([apk, apk]))
        XCTAssertFalse(DeviceAPKInstaller.accepts([URL(string: "https://example.com/test.apk")!]))
        XCTAssertFalse(DeviceAPKInstaller.accepts([URL(fileURLWithPath: "/tmp/test.apks")]))
    }

    @MainActor func testInstallationKeepsCapturedDeviceAndExactFileArgumentAndRejectsConcurrentDrop() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var calls = 0, refreshed: String?
        let installer = DeviceAPKInstaller { path, arguments, timeout in
            calls += 1
            XCTAssertEqual(path, "/adb path")
            XCTAssertEqual(arguments, ["-s", "pixel", "install", "-r", file.path])
            XCTAssertEqual(timeout, 180)
            try await Task.sleep(nanoseconds: 30_000_000)
            return "Performing Streamed Install\nSuccess\n"
        }
        installer.onInstalled = { refreshed = $0 }
        let target = APKInstallTarget(path: "/adb path", serial: "pixel", name: "Pixel 6")
        XCTAssertTrue(installer.install(file, on: target))
        XCTAssertTrue(installer.isInstalling)
        XCTAssertFalse(installer.install(file, on: APKInstallTarget(path: "/other", serial: "other", name: "Other")))
        await installer.waitUntilFinished()
        XCTAssertEqual(calls, 1); XCTAssertEqual(refreshed, "pixel")
        XCTAssertFalse(installer.isInstalling); XCTAssertFalse(installer.failed)
        XCTAssertTrue(installer.message?.contains("Pixel 6 · pixel") == true)
        XCTAssertTrue(installer.message?.hasPrefix("已安装") == true)
    }

    @MainActor func testFailedInstallDoesNotReportSuccessOrRefreshApps() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for output in ["Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]", "", "not Success"] {
            let installer = DeviceAPKInstaller { _, _, _ in output }
            installer.onInstalled = { _ in XCTFail("A failed install must not report an installed app") }
            XCTAssertTrue(installer.install(file, on: APKInstallTarget(path: "/adb", serial: "pixel", name: "Pixel")))
            await installer.waitUntilFinished()
            XCTAssertTrue(installer.failed); XCTAssertFalse(installer.isInstalling)
            XCTAssertTrue(installer.message?.hasPrefix("安装失败") == true)
        }
        let disconnected = DeviceAPKInstaller { _, _, _ in throw ADBError.failed("device offline") }
        XCTAssertTrue(disconnected.install(file, on: APKInstallTarget(path: "/adb", serial: "pixel", name: "Pixel")))
        await disconnected.waitUntilFinished()
        XCTAssertTrue(disconnected.message?.contains("device offline") == true)
        XCTAssertTrue(disconnected.failed)
    }

    @MainActor func testMissingFilesAndStaleDropTargetsCannotInstall() {
        let installer = DeviceAPKInstaller { _, _, _ in XCTFail("Invalid file must not run ADB"); return "Success" }
        let target = APKInstallTarget(path: "/adb", serial: "pixel", name: "Pixel")
        XCTAssertFalse(installer.install(URL(fileURLWithPath: "/missing/" + UUID().uuidString + ".apk"), on: target))
        XCTAssertTrue(installer.failed)
        let mirror = DeviceMirrorController()
        XCTAssertFalse(mirror.installAPK(URL(fileURLWithPath: "/tmp/test.apk"), target: target))
        XCTAssertTrue(mirror.installer.failed)
        XCTAssertFalse(mirror.installer.isInstalling)
    }
}
