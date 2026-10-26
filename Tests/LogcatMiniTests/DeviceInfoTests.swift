import XCTest
import LogcatCore
@testable import LogcatMini

final class DeviceInfoTests: XCTestCase {
    func testPropertiesAndShellAndroidIDValidation() async throws {
        let service = DeviceInfoService { arguments, _ in
            if arguments == ["shell", "getprop"] {
                return "[ro.product.model]: [Phone [Test]]\nnoise\n[ro.build.version.sdk]: [35]"
            }
            XCTAssertEqual(arguments, ["shell", "settings", "--user", "current", "get", "secure", "android_id"])
            return "Permission denial: shell"
        }
        let result = try await service.readBasics()
        XCTAssertEqual(result.properties["ro.product.model"], "Phone [Test]")
        XCTAssertEqual(result.properties["ro.build.version.sdk"], "35")
        XCTAssertNil(result.androidID)
    }

    func testGAIDParsingDistinguishesDeletedMissingServicesAndInvalidResult() throws {
        let prefix = "INSTRUMENTATION_RESULT: logcatMiniInfo="
        let valid = try AdvertisingIDResult.parse(prefix + #"{"schema":1,"status":"available","gaid":"12345678-1234-1234-1234-123456789abc","permissionGranted":true,"limitAdTracking":false}"#)
        XCTAssertEqual(valid.status, "available")
        let zero = try AdvertisingIDResult.parse(prefix + #"{"schema":1,"status":"zero","gaid":"00000000-0000-0000-0000-000000000000","permissionGranted":true,"limitAdTracking":true}"#)
        XCTAssertTrue(zero.explanation.contains("全零"))
        let missing = try AdvertisingIDResult.parse(prefix + #"{"schema":1,"status":"missing_play_services"}"#)
        XCTAssertNil(missing.gaid)
        XCTAssertTrue(missing.explanation.contains("Google Play"))
        for output in ["INSTRUMENTATION_FAILED: denied", prefix + "{}",
                       prefix + #"{"schema":1,"status":"available","gaid":"bad","permissionGranted":true}"#,
                       prefix + #"{"schema":1,"status":"available","gaid":"00000000-0000-0000-0000-000000000000","permissionGranted":true}"#] {
            XCTAssertThrowsError(try AdvertisingIDResult.parse(output))
        }
    }

    func testFirstReadInstallsForCurrentUserBeforeInstrumentation() async throws {
        var calls: [[String]] = []
        let service = DeviceInfoService { arguments, _ in
            calls.append(arguments)
            switch calls.count {
            case 1: return "10"
            case 2: return ""
            case 3: return "Performing Streamed Install\nSuccess"
            default: return #"INSTRUMENTATION_RESULT: logcatMiniInfo={"schema":1,"status":"missing_play_services"}"#
            }
        }
        _ = try await service.readAdvertisingID(helper: URL(fileURLWithPath: "/helper with spaces.apk"))
        XCTAssertEqual(calls[2], ["install", "-r", "--user", "10", "/helper with spaces.apk"])
        XCTAssertEqual(calls[3], ["shell", "am", "instrument", "--user", "10", "-w", "-r",
                                 "com.songran.logcatmini.deviceinfo/.DeviceInfoReader"])
        XCTAssertEqual(calls.count, 4)
    }

    func testExistingHelperSkipsInstallAndInstallFailureNeverReadsStaleGAID() async throws {
        var calls: [[String]] = []
        let service = DeviceInfoService { arguments, _ in
            calls.append(arguments)
            if arguments.contains("get-current-user") { return "0" }
            if arguments.contains("packages") { return "package:com.songran.logcatmini.deviceinfo versionCode:1" }
            return #"INSTRUMENTATION_RESULT: logcatMiniInfo={"schema":1,"status":"zero","gaid":"00000000-0000-0000-0000-000000000000"}"#
        }
        _ = try await service.readAdvertisingID(helper: URL(fileURLWithPath: "/helper.apk"))
        XCTAssertFalse(calls.contains { $0.first == "install" })
        var failedCalls = 0
        let failing = DeviceInfoService { _, _ in
            failedCalls += 1
            return failedCalls == 1 ? "0" : failedCalls == 2 ? "" : "Failure [INSTALL_FAILED_USER_RESTRICTED]"
        }
        do { _ = try await failing.readAdvertisingID(helper: URL(fileURLWithPath: "/helper.apk")); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("安装未完成")) }
        XCTAssertEqual(failedCalls, 3)
    }

    func testResetEntryOnlyOpensResolvedGoogleSettingsAndDoesNotMutateIDs() async throws {
        var calls: [[String]] = []
        let service = DeviceInfoService { arguments, _ in
            calls.append(arguments)
            return calls.count == 1 ? "com.google.android.gms/.adid.settings.AdsSettingsActivity" : "Starting: Intent"
        }
        try await service.openAdvertisingSettings()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last, ["shell", "am", "start", "--user", "current", "-a",
                                   "com.google.android.gms.settings.ADS_PRIVACY", "-p", "com.google.android.gms"])
        var unavailableCalls = 0
        let unavailable = DeviceInfoService { _, _ in unavailableCalls += 1; return "No activity found" }
        do { try await unavailable.openAdvertisingSettings(); XCTFail("Expected missing settings") } catch { }
        XCTAssertEqual(unavailableCalls, 1)
    }

    func testCancelledReadDoesNotInstallOrLaunchHelper() async throws {
        var calls = 0
        let service = DeviceInfoService { _, _ in calls += 1; return "0" }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.readAdvertisingID(helper: URL(fileURLWithPath: "/helper.apk"))
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertLessThanOrEqual(calls, 1)
    }

    func testOptInPhysicalDeviceGAIDRead() async throws {
        guard let serial = ProcessInfo.processInfo.environment["LOGCAT_MINI_DEVICE_INFO_QA"], let path = ADB.locate() else {
            throw XCTSkip("Set LOGCAT_MINI_DEVICE_INFO_QA to enable authorized device helper installation and read")
        }
        let service = DeviceInfoService(target: DeviceInfoTarget(path: path, serial: serial, name: "QA"))
        let basics = try await service.readBasics()
        XCTAssertNotNil(basics.properties["ro.product.model"])
        let helper = try XCTUnwrap(Bundle.module.url(forResource: "DeviceInfo", withExtension: "apk"))
        let result = try await service.readAdvertisingID(helper: helper)
        XCTAssertTrue(["available", "zero"].contains(result.status), result.explanation)
        XCTAssertEqual(result.permissionGranted, true)
    }
}
