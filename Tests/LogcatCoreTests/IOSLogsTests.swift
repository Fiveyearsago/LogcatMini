import XCTest
@testable import LogcatCore

final class IOSLogsTests: XCTestCase {
    func testDiscoveryIncludesOnlyBootedAvailableIOSSimulatorsAndNamespacesIDs() throws {
        let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"A","name":"iPhone","state":"Booted","isAvailable":true},{"udid":"B","name":"iPad","state":"Shutdown","isAvailable":true},{"udid":"C","name":"Old","state":"Booted","isAvailable":false}],"com.apple.CoreSimulator.SimRuntime.tvOS-27-0":[{"udid":"D","name":"TV","state":"Booted"}]}}"#
        let devices = try IOSDevice.bootedSimulators(Data(json.utf8))
        XCTAssertEqual(devices.map(\.id), ["simulator:A"])
        XCTAssertNotEqual(devices[0].id, IOSDevice(udid: "A", name: "iPhone", kind: .usb).id)
        XCTAssertThrowsError(try IOSDevice.bootedSimulators(Data("invalid".utf8)))
    }
    func testSimulatorAppUsesExecutableRatherThanDisplayNameOrBundleID() throws {
        let plist: [String: Any] = ["com.example.dev": ["CFBundleDisplayName": "开发版 App", "CFBundleExecutable": "Runner"], "missing": ["CFBundleName": "Missing"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(try IOSLogProcess.simulatorApps(data), [.init(id: "com.example.dev", name: "开发版 App", executable: "Runner")])
    }
    func testPhysicalProcessListSkipsDiagnosticsAndKeepsFullName() {
        let processes = IOSLogProcess.deviceProcesses("[connected:abc]\n42 Runner\ninvalid message\n43 Runner\n100 My App\n")
        XCTAssertEqual(processes.map(\.executable), ["My App", "Runner"])
    }
    func testUnifiedLogPreservesUnicodeMultilineJSONAndMetadata() throws {
        let message = "请求成功\n{\"ok\":true,\"value\":\"<private>\"}"
        let value: [String: Any] = ["timestamp": "2026-11-03 12:34:56.123456+0800", "eventMessage": message,
                                  "processID": 123, "threadID": 456, "processImagePath": "/Apps/Runner.app/Runner",
                                  "subsystem": "com.example", "category": "network", "messageType": "Error"]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        let log = try XCTUnwrap(IOSLogParser.simulator(line, id: 1))
        XCTAssertEqual(log.message, message); XCTAssertEqual(log.pid, "123"); XCTAssertEqual(log.tid, "456")
        XCTAssertEqual(log.level, .error); XCTAssertEqual(log.tag, "Runner / com.example / network")
        XCTAssertTrue(log.fullText.contains(message)); XCTAssertFalse(log.fullText.contains("eventMessage"))
        XCTAssertEqual(try LogFilter(query: "请求成功", tag: "network").apply(to: [log]).count, 1)
        XCTAssertNil(IOSLogParser.simulator("Filtering the log data using process", id: 2))
        XCTAssertNil(IOSLogParser.simulator(#"{"eventType":"activityCreateEvent"}"#, id: 3))
    }
    func testPhysicalOldAndNewLogFormatsAndLevels() throws {
        let newer = try XCTUnwrap(IOSLogParser.device("Nov  3 12:34:56.123456 Runner(UIKitCore)[123] <Fault>: 中文 {\"ok\":false}", id: 2))
        XCTAssertEqual(newer.pid, "123"); XCTAssertEqual(newer.tag, "Runner(UIKitCore)"); XCTAssertEqual(newer.level, .fatal)
        let older = try XCTUnwrap(IOSLogParser.device("Nov 13 12:34:56 My-iPhone Runner[123] <Warning>: test", id: 3))
        XCTAssertEqual(older.level, .warning); XCTAssertEqual(older.message, "test")
        XCTAssertNil(IOSLogParser.device("[connected:abc]", id: 4))
    }
    func testCommandsKeepIdentifiersAndProcessNamesAsLiteralArguments() {
        let device = IOSDevice(udid: "an-id", name: "iPhone", kind: .simulator)
        let args = IOSTools.streamArguments(device: device, process: " My App $(touch /tmp/never) ")
        XCTAssertEqual(Array(args.suffix(2)), ["--process", "My App $(touch /tmp/never)"])
        XCTAssertEqual(args[2], "an-id"); XCTAssertTrue(args.contains("ndjson"))
        let usb = IOSDevice(udid: "usb-id", name: "iPhone", kind: .usb)
        XCTAssertEqual(IOSTools.streamArguments(device: usb, process: "Runner"), ["-u", "usb-id", "--no-colors", "-x", "-p", "Runner"])
    }
}
