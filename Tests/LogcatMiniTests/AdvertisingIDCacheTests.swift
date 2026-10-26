import XCTest
@testable import LogcatMini

final class AdvertisingIDCacheTests: XCTestCase {
    private static let firstID = "12345678-1234-1234-1234-123456789abc"
    private static let nextID = "abcdefab-1234-1234-1234-123456789abc"
    private static func output(_ id: String = firstID) -> String {
        "INSTRUMENTATION_RESULT: logcatMiniInfo=" +
        "{\"schema\":1,\"status\":\"available\",\"gaid\":\"\(id)\",\"permissionGranted\":true,\"limitAdTracking\":false}"
    }
    private func target(_ serial: String = "phone-a") -> DeviceInfoTarget {
        DeviceInfoTarget(path: "/unused-adb", serial: serial, name: "Test phone")
    }
    private func defaults() -> (UserDefaults, String) {
        let suite = "LogcatMini.AdvertisingIDCacheTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @MainActor func testCacheSurvivesNewInstanceAndSeparatesDevices() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = AdvertisingIDCache(defaults: defaults)
        let result = try AdvertisingIDResult.parse(Self.output())
        let date = Date(timeIntervalSince1970: 1234567)
        cache.store(result, for: "phone-a", at: date)
        cache.markNeedsRefresh(for: "phone-a")
        let reopened = AdvertisingIDCache(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reopened.entry(for: "phone-a")?.result, result)
        XCTAssertEqual(reopened.entry(for: "phone-a")?.readAt, date)
        XCTAssertEqual(reopened.entry(for: "phone-a")?.needsRefresh, true)
        XCTAssertNil(reopened.entry(for: "phone-b"))
        let failure = try AdvertisingIDResult.parse(#"INSTRUMENTATION_RESULT: logcatMiniInfo={"schema":1,"status":"missing_play_services"}"#)
        XCTAssertNil(reopened.store(failure, for: "phone-a"))
        XCTAssertEqual(reopened.entry(for: "phone-a")?.result, result)
        let zero = try AdvertisingIDResult.parse(#"INSTRUMENTATION_RESULT: logcatMiniInfo={"schema":1,"status":"zero","gaid":"00000000-0000-0000-0000-000000000000","permissionGranted":true,"limitAdTracking":true}"#)
        reopened.store(zero, for: "phone-a")
        XCTAssertEqual(reopened.entry(for: "phone-a")?.result, zero)
        XCTAssertEqual(reopened.entry(for: "phone-a")?.needsRefresh, false)
    }

    @MainActor func testFirstReadIsExplicitAndReopeningUsesCacheWithoutReadingGAID() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = AdvertisingIDCache(defaults: defaults)
        var calls: [[String]] = []
        let service = DeviceInfoService { arguments, _ in
            calls.append(arguments)
            if arguments.contains("get-current-user") { return "0" }
            if arguments.contains("packages") { return "package:com.songran.logcatmini.deviceinfo versionCode:1" }
            if arguments.contains("instrument") { return Self.output() }
            if arguments.contains("getprop") { return "[ro.product.model]: [Test phone]" }
            return "0123456789abcdef"
        }
        let model = DeviceInfoModel(target: target(), cache: cache, service: service)
        model.load()
        await model.waitUntilFinished()
        model.refresh()
        await model.waitUntilFinished()
        XCTAssertNil(model.advertisingID)
        XCTAssertEqual(calls.count, 4)
        XCTAssertFalse(calls.contains { $0.contains("instrument") || $0.first == "install" })
        model.readGAID()
        await model.waitUntilFinished()
        XCTAssertEqual(model.advertisingID?.gaid, Self.firstID)
        XCTAssertNotNil(model.advertisingIDReadAt)
        XCTAssertNil(model.error)
        model.stop()

        calls.removeAll()
        let reopened = DeviceInfoModel(target: target(), cache: AdvertisingIDCache(defaults: defaults), service: service)
        XCTAssertEqual(reopened.advertisingID?.gaid, Self.firstID)
        reopened.load()
        await reopened.waitUntilFinished()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls.contains { $0.contains("instrument") || $0.first == "install" })
        let otherDevice = DeviceInfoModel(target: target("phone-b"), cache: cache, service: service)
        XCTAssertNil(otherDevice.advertisingID)
    }

    @MainActor func testFailedRefreshKeepsCachedValueAndSuccessfulRefreshReplacesIt() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = AdvertisingIDCache(defaults: defaults)
        let savedDate = Date(timeIntervalSince1970: 1234567)
        cache.store(try AdvertisingIDResult.parse(Self.output()), for: "phone-a", at: savedDate)
        var shouldFail = true
        var reads = 0
        let service = DeviceInfoService { arguments, _ in
            if arguments.contains("get-current-user") { return "0" }
            if arguments.contains("packages") { return "package:com.songran.logcatmini.deviceinfo versionCode:1" }
            if arguments.contains("instrument") {
                reads += 1
                if shouldFail { throw MirrorError.message("读取失败测试") }
                return Self.output(Self.nextID)
            }
            return ""
        }
        let model = DeviceInfoModel(target: target(), cache: cache, service: service)
        model.readGAID()
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.advertisingID?.gaid, Self.firstID)
        await model.waitUntilFinished()
        XCTAssertEqual(model.advertisingID?.gaid, Self.firstID)
        XCTAssertEqual(model.advertisingIDReadAt, savedDate)
        XCTAssertTrue(model.needsGAIDRefresh)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.busy)

        shouldFail = false
        model.refresh()
        await model.waitUntilFinished()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.advertisingID?.gaid, Self.nextID)
        XCTAssertNotEqual(model.advertisingIDReadAt, savedDate)
        XCTAssertFalse(model.needsGAIDRefresh)
        XCTAssertNil(model.error)
        XCTAssertEqual(cache.entry(for: "phone-a")?.result.gaid, Self.nextID)
    }

    @MainActor func testOpeningSettingsKeepsCacheAndMarksItForRefresh() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = AdvertisingIDCache(defaults: defaults)
        cache.store(try AdvertisingIDResult.parse(Self.output()), for: "phone-a")
        let service = DeviceInfoService { arguments, _ in
            arguments.contains("resolve-activity") ? "com.google.android.gms/.adid.settings.AdsSettingsActivity" : "Starting: Intent"
        }
        let model = DeviceInfoModel(target: target(), cache: cache, service: service)
        var opened = false
        model.openSettings { opened = true }
        await model.waitUntilFinished()
        XCTAssertTrue(opened)
        XCTAssertTrue(model.needsGAIDRefresh)
        XCTAssertEqual(model.advertisingID?.gaid, Self.firstID)
        XCTAssertEqual(DeviceInfoModel(target: target(), cache: cache).needsGAIDRefresh, true)
    }
}
