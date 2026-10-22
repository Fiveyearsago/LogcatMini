import XCTest
@testable import LogcatCore

final class DisplayAndFavoritesTests: XCTestCase {
    func testLoggerPrefixIsHiddenOnlyInDisplayMessage() throws {
        let raw = "2026-10-12 17:37:18.416 29440 13391 D MD.Network: 17:37:18.415[11188] 请求完成🔋 code=200"
        let entry = try XCTUnwrap(LogParser.parse(raw, id: 1))
        XCTAssertEqual(entry.displayMessage, "请求完成🔋 code=200")
        XCTAssertEqual(entry.message, "17:37:18.415[11188] 请求完成🔋 code=200")
        XCTAssertEqual(entry.raw, raw)
        XCTAssertEqual(try LogFilter(query: "11188").apply(to: [entry]), [entry])
    }

    func testBusinessTimestampsAndUnrecognizedPrefixesArePreserved() {
        let messages = [
            "Task scheduled for 17:37:18.413[11188] tomorrow",
            "17:37:18.413 event time", "17:37:18.413[11188]", "25:37:18.413[11188] invalid",
            #"{"timestamp":1791797838301,"message":"17:37:18.413[11188] scheduled"}"#,
            "  ordinary message", "[11188] thread info", ""
        ]
        for message in messages { XCTAssertEqual(LogMessageDisplay.clean(message), message) }
        XCTAssertEqual(LogMessageDisplay.clean(" 17:37:18.413123[2]\tJSON: {}"), "JSON: {}")
    }

    func testFavoritesPersistByPackageNameAndCanBeRemovedAfterReload() throws {
        let suite = "LogcatMini.FavoritesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var favorites = PackageFavorites(defaults: defaults)
        favorites.toggle("com.example.second")
        favorites.toggle("com.example.first")
        favorites.toggle("")
        var reopened = PackageFavorites(defaults: defaults)
        XCTAssertEqual(reopened.packageIDs, ["com.example.first", "com.example.second"])
        reopened.toggle("com.example.first")
        XCTAssertFalse(PackageFavorites(defaults: defaults).contains("com.example.first"))
        XCTAssertTrue(PackageFavorites(defaults: defaults).contains("com.example.second"))
    }

    func testSavedFavoritesAreDeduplicatedWithoutDependingOnConnectedDevice() throws {
        let suite = "LogcatMini.FavoritesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["com.example.uninstalled", "", "com.example.uninstalled"], forKey: "favoritePackages")
        XCTAssertEqual(PackageFavorites(defaults: defaults).packageIDs, ["com.example.uninstalled"])
    }
}
