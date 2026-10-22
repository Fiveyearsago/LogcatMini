import XCTest
@testable import LogcatCore

final class AppMetadataTests: XCTestCase {
    private func output(_ apps: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "apps": apps])
        return "OEM diagnostic output\n" + AppMetadataDecoder.marker + String(decoding: data, as: UTF8.self) + "\n"
    }

    func testMixedOutputAndPerPackageFailureKeepSuccessfulNames() throws {
        let source = try output([
            ["packageName": "com.example.good", "label": "充电🔋", "lastUpdateTime": 1791793974174],
            ["packageName": "com.example.gone", "error": "NameNotFoundException"],
            ["packageName": "com.example.nameOnly", "label": "名称可用", "iconError": "ResourcesNotFoundException"],
            ["packageName": "com.example.unrequested", "label": "Ignore"]
        ])
        let apps = try AppMetadataDecoder.decode(source, requested: ["com.example.good", "com.example.gone", "com.example.nameOnly"])
        XCTAssertEqual(apps.map(\.label), ["充电🔋", "名称可用"])
        XCTAssertEqual(apps.first?.lastUpdateTime, 1791793974174)
        XCTAssertNil(apps.last?.iconPNG)
    }

    func testMalformedIconDoesNotLoseReadableAppName() throws {
        for icon in ["invalid base64", Data("not a png".utf8).base64EncodedString()] {
            let apps = try AppMetadataDecoder.decode(output([["packageName": "com.example.app", "label": "App", "iconPNG": icon]]), requested: ["com.example.app"])
            XCTAssertEqual(apps.first?.label, "App")
            XCTAssertNil(apps.first?.iconPNG)
        }
    }

    func testPNGSurvivesTransportAndCacheIsIsolatedByDevice() throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let apps = try AppMetadataDecoder.decode(output([["packageName": "com.example.app", "label": "手机 A", "iconPNG": png.base64EncodedString()]]), requested: ["com.example.app"])
        XCTAssertEqual(apps.first?.iconPNG, png)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppMetadataCache(directory: directory)
        try cache.save(["com.example.app": try XCTUnwrap(apps.first)], serial: "192.168.1.2:5555")
        let other = AppMetadata(packageName: "com.example.app", label: "手机 B", iconPNG: nil, lastUpdateTime: 2)
        try cache.save([other.packageName: other], serial: "usb-device")
        let reopened = AppMetadataCache(directory: directory)
        XCTAssertEqual(reopened.load(serial: "192.168.1.2:5555")["com.example.app"], apps.first)
        XCTAssertEqual(reopened.load(serial: "usb-device")["com.example.app"], other)
        XCTAssertTrue(reopened.load(serial: "another-device").isEmpty)
    }

    func testRejectsUnrecognizedResponseAndShellMetacharacters() {
        for source in ["plain error", AppMetadataDecoder.marker + "{}", AppMetadataDecoder.marker + "{\"schema\":2,\"apps\":[]}"] {
            XCTAssertThrowsError(try AppMetadataDecoder.decode(source, requested: []))
        }
        for package in ["", "com.app;reboot", "com.app$(id)", "com.app\n", "../app", "com.app extra", "-x"] {
            XCTAssertFalse(AppMetadataDecoder.validPackage(package), package)
        }
        for package in ["com.example.demo", "android", "com.example_app.debug2"] {
            XCTAssertTrue(AppMetadataDecoder.validPackage(package), package)
        }
    }
}
