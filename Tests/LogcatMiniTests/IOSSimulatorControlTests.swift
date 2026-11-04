import XCTest
import AppKit
import LogcatCore
@testable import LogcatMini

final class IOSSimulatorControlTests: XCTestCase {
    func testLetterboxAndClampedDragCoordinates() {
        let size = CGSize(width: 402, height: 874), bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        XCTAssertNil(IOSSimulatorGeometry.point(CGPoint(x: 0, y: 300), image: size, bounds: bounds))
        let middle = IOSSimulatorGeometry.point(CGPoint(x: 300, y: 300), image: size, bounds: bounds)
        XCTAssertEqual(middle, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(IOSSimulatorGeometry.point(CGPoint(x: -10, y: 1000), image: size, bounds: bounds, clamp: true), CGPoint(x: 0, y: 1))
        XCTAssertNil(IOSSimulatorGeometry.point(.zero, image: .zero, bounds: bounds))
        // Same target coordinates after resizing a tall, narrow panel or showing a landscape image.
        for image in [size, CGSize(width: 874, height: 402)] {
            for panel in [CGSize(width: 280, height: 900), CGSize(width: 760, height: 400)] {
                let bounds = CGRect(origin: .zero, size: panel), rect = IOSSimulatorGeometry.rect(image: image, bounds: CGRect(origin: .zero, size: panel))
                let result = IOSSimulatorGeometry.point(CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.75), image: image, bounds: bounds)!
                XCTAssertEqual(result.x, 0.25, accuracy: 0.00001); XCTAssertEqual(result.y, 0.75, accuracy: 0.00001)
            }
        }
    }
    @MainActor func testSelectedXcodeHostAppResolution() {
        let developer = URL(fileURLWithPath: "/Applications/Selected Xcode.app/Contents/Developer")
        let hub = "/Applications/Selected Xcode.app/Contents/Applications/DeviceHub.app"
        let old = developer.appendingPathComponent("Applications/Simulator.app").path
        XCTAssertEqual(IOSPreviewController.hostApp(developer: developer, exists: { $0 == hub })?.path, hub)
        XCTAssertEqual(IOSPreviewController.hostApp(developer: developer, exists: { $0 == old })?.path, old)
        XCTAssertNil(IOSPreviewController.hostApp(developer: developer, exists: { _ in false }))
    }
    @MainActor func testOptInUIKitReceivesTouchDragTextKeysScrollAndRelease() async throws {
        guard let udid = ProcessInfo.processInfo.environment["LOGCAT_MINI_IOS_CONTROL_QA"] else { throw XCTSkip("Requires an explicitly selected booted simulator and Xcode 27 DTUHID") }
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LogcatMiniControlQA-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = try await BuildProcessRunner().run(.init(executable: "/usr/bin/xcodebuild", arguments: ["-project", projectRoot.appendingPathComponent("Tests/Fixtures/IOSBuildProbe/Probe.xcodeproj").path, "-scheme", "Probe", "-sdk", "iphonesimulator", "-destination", "platform=iOS Simulator,id=\(udid)", "-derivedDataPath", temporary.path, "CODE_SIGNING_ALLOWED=NO", "build"], timeout: 90), output: { _ in })
        XCTAssertEqual(result.status, 0, String(result.output.suffix(2500)))
        let bundle = "com.logcatmini.qa.buildprobe"
        _ = try? await IOSDeviceService.xcrun(["simctl", "terminate", udid, bundle])
        _ = try await IOSDeviceService.xcrun(["simctl", "install", udid, temporary.appendingPathComponent("Build/Products/Debug-iphonesimulator/Probe.app").path])
        _ = try await IOSDeviceService.xcrun(["simctl", "launch", udid, bundle])
        let container = try await IOSDeviceService.xcrun(["simctl", "get_app_container", udid, bundle, "data"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let receiptURL = URL(fileURLWithPath: container).appendingPathComponent("Documents/control.json")
        func receipt() -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any]) ?? [:] }
        func waitFor(_ description: String, _ condition: () -> Bool) async throws {
            for _ in 0..<80 { if condition() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
            XCTFail(description + " receipt: \(receipt())")
        }
        try await waitFor("fixture appeared") { receipt()["ready"] as? Bool == true }
        let width = receipt()["width"] as! Double, height = receipt()["height"] as! Double
        let preview = IOSPreviewController(); defer { preview.stop() }
        preview.connect(IOSDevice(udid: udid, name: "Control QA", kind: .simulator))
        try await waitFor("interactive frame: \(preview.controlError ?? "")") { preview.controllable && preview.liveFrames && preview.image != nil }
        // Compare against the simulator's own screenshot, not a hard-coded model resolution.
        // This catches the previous 960px downscale even when the UI looks correct at small sizes.
        let reference = temporary.appendingPathComponent("native-screen.png")
        try await IOSDeviceService.screenshot(IOSDevice(udid: udid, name: "QA", kind: .simulator), to: reference)
        let native = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: reference)))
        let streamed = try XCTUnwrap(preview.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(streamed.width, native.pixelsWide)
        XCTAssertEqual(streamed.height, native.pixelsHigh)
        // viewDidAppear can precede SpringBoard's launch animation finishing. UIKit ignores
        // touches during that transition; exercise controls only after the screen settles.
        try await Task.sleep(nanoseconds: 500_000_000)
        func touch(_ phase: Int, _ x: Double, _ y: Double) { preview.touch(phase: phase, at: CGPoint(x: x / width, y: y / height)) }
        func tap(_ x: Double, _ y: Double) async throws { touch(0, x, y); try await Task.sleep(nanoseconds: 80_000_000); touch(2, x, y) }
        try await tap(160, 150); try await waitFor("button tap") { receipt()["taps"] as? Int == 1 }
        try await tap(160, 240)
        try await waitFor("editor focused") { receipt()["editing"] as? Bool == true }
        try await Task.sleep(nanoseconds: 300_000_000)
        let sample = "Abc123_+=!@# 中文🙂\n第二行"
        preview.sendText(sample)
        try await waitFor("exact Unicode / punctuation / multiline input") { receipt()["text"] as? String == sample }
        preview.key(42)
        try await waitFor("backspace") { receipt()["text"] as? String == String(sample.dropLast()) }
        preview.key(40)
        try await waitFor("one return inserts one newline") { receipt()["text"] as? String == String(sample.dropLast()) + "\n" }
        preview.key(4, modifiers: [227]); preview.sendText("全选替换")
        try await waitFor("command A") { receipt()["text"] as? String == "全选替换" }
        try await tap(160, 150); try await waitFor("dismiss keyboard") { receipt()["taps"] as? Int == 2 }
        touch(0, 80, 380)
        // Mouse/trackpad events can arrive as one burst. The bridge must preserve UIKit's down tick.
        for x in stride(from: 100.0, through: 260, by: 20) { touch(1, x, 380) }
        touch(2, 260, 380); try await waitFor("drag") { receipt()["drags"] as? Int == 1 }
        touch(0, 170, 660)
        for y in stride(from: 640.0, through: 480, by: -20) { touch(1, 170, y) }
        touch(2, 170, 480); try await waitFor("scroll") { (receipt()["scroll"] as? Double ?? 0) > 100 }
        // Closing with a held gesture must send a final release to this device, not the next one.
        touch(0, 80, 380); try await Task.sleep(nanoseconds: 80_000_000)
        touch(1, 140, 380); try await Task.sleep(nanoseconds: 80_000_000)
        touch(1, 210, 380); try await Task.sleep(nanoseconds: 150_000_000)
        preview.stop(); try await waitFor("release on close") { receipt()["drags"] as? Int == 2 }
        XCTAssertFalse(preview.controllable); XCTAssertNil(preview.image)
        preview.sendText("must not arrive"); try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(receipt()["text"] as? String, "全选替换")
        _ = try await IOSDeviceService.xcrun(["simctl", "uninstall", udid, bundle])
    }
}
