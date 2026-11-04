import AppKit
import LogcatCore

enum IOSDeviceService {
    static func xcrun(_ arguments: [String], timeout: TimeInterval = 20) async throws -> String {
        let result = try await BuildProcessRunner().run(.init(executable: "/usr/bin/xcrun", arguments: arguments, timeout: timeout), output: { _ in })
        guard result.status == 0 else { throw LocalBuildError.message(result.output.isEmpty ? "Xcode 设备操作失败。请确认设备已解锁、信任 Mac，且已安装完整 Xcode。" : result.output) }
        return result.output
    }
    static func json(_ arguments: [String]) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-ios-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await xcrun(["devicectl"] + arguments + ["--json-output", file.path, "--quiet", "--timeout", "15"])
        return try Data(contentsOf: file)
    }
    static func screenshot(_ device: IOSDevice, to url: URL) async throws {
        do { _ = try await xcrun(IOSTools.screenshotArguments(device: device, destination: url.path)) }
        catch {
            guard device.kind == .usb, let tool = IOSTools.locate("idevicescreenshot"), !Task.isCancelled else { throw error }
            _ = try await ADB.run(path: tool, arguments: ["-u", device.udid, url.path], timeout: 15)
        }
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { throw LocalBuildError.message("设备未返回有效截图。请检查 Xcode 与设备支持状态。") }
    }
    static func icon(_ app: IOSLogProcess, device: IOSDevice) async -> Data? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await xcrun(["devicectl", "device", "info", "appIcon", "--device", device.udid, "--app-bundle-id", app.id,
                                "--width", "64", "--height", "64", "--destination", file.path, "--quiet"], timeout: 8)
            return try Data(contentsOf: file)
        } catch { return nil }
    }
    static func deviceInfo(_ device: IOSDevice) async throws -> String {
        if device.kind == .usb, let path = IOSTools.locate("ideviceinfo") {
            // IDs are only read on explicit request and remain local.
            return try await ADB.run(path: path, arguments: ["-u", device.udid], timeout: 10)
        }
        let data = try await json(["device", "info", "details", "--device", device.udid])
        let object = try JSONSerialization.jsonObject(with: data)
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    static func transferClipboard(device: IOSDevice, toDevice: Bool) async throws {
        _ = try await xcrun(["devicectl", "device", "pasteboard", "transfer", toDevice ? "to" : "from",
                            "--device", device.udid, "--data-policy", "all-resolved", "--quiet", "--timeout", "15"])
    }
}
