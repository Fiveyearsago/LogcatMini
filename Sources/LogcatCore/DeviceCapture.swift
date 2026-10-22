import Foundation

public enum DeviceCapture {
    /// exec-out keeps PNG bytes intact; stderr must never be mixed into the image.
    public static func screenshot(path: String, serial: String, to destination: URL) async throws {
        try await screenshotData(path: path, serial: serial).write(to: destination, options: .atomic)
    }
    public static func screenshotData(path: String, serial: String) async throws -> Data {
        let data = try await binary(path: path, arguments: ["-s", serial, "exec-out", "screencap", "-p"])
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), data.count > 24 else {
            throw ADBError.failed("手机未返回有效的 PNG 截图。")
        }
        return data
    }

    private static func binary(path: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
                process.standardOutput = output; process.standardError = errors
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                let errorData = CaptureOutput(), group = DispatchGroup(); group.enter()
                DispatchQueue.global().async { errorData.set(errors.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); group.wait(); timeout.cancel()
                if process.terminationStatus == 0 { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ADBError.failed(errorData.text.isEmpty ? "截图失败或超时，请检查设备连接。" : errorData.text)) }
            }
        }
    }
}

/// Owns a headless recorder bound to one serial. Video is muxed on the Mac, so
/// OEM restrictions on Android's screenrecord file access do not apply.
public final class AndroidScreenRecording: @unchecked Sendable {
    public let serial: String
    public let temporaryMovie: URL
    private let completion: Task<String, Never>
    private let child: Process
    public var isRunning: Bool { child.isRunning }

    public init(path: String, serial: String, runtime: URL) throws {
        self.serial = serial
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-recording-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryMovie = root.appendingPathComponent("recording.mp4")
        let process = Process(), pipe = Pipe()
        process.executableURL = runtime.appendingPathComponent("scrcpy")
        process.arguments = ["--serial", serial, "--no-audio", "--no-control", "--no-playback", "--no-window",
                             "--record=" + temporaryMovie.path, "--time-limit=180", "--max-size=1920", "--video-bit-rate=8M"]
        var environment = ProcessInfo.processInfo.environment
        environment["ADB"] = path
        environment["SCRCPY_SERVER_PATH"] = runtime.appendingPathComponent("scrcpy-server").path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { try? FileManager.default.removeItem(at: root); throw error }
        child = process
        completion = Task.detached {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func stop() async throws {
        // SIGINT finalizes the recording; signal this owned child only, never adb server.
        if child.isRunning { child.interrupt() }
    }

    public func saveWhenFinished(to destination: URL) async throws {
        let diagnostic = await completion.value
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".logcat-mini-" + UUID().uuidString + ".mp4")
        defer { if FileManager.default.fileExists(atPath: temporary.path) { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let file = try FileHandle(forReadingFrom: temporaryMovie)
            let header = try file.read(upToCount: 32) ?? Data(); try file.close()
            guard header.count >= 16, String(data: header[4..<8], encoding: .ascii) == "ftyp" else {
                throw ADBError.failed("未生成有效视频，请稍后重新录制。")
            }
            try FileManager.default.copyItem(at: temporaryMovie, to: temporary)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        } catch {
            let reason = diagnostic.isEmpty ? error.localizedDescription : diagnostic + "\n" + error.localizedDescription
            // Retain the completed local recording for retry if the chosen destination fails.
            throw ADBError.failed("视频尚未保存：\(reason)\n设备：\(serial)\n临时文件：\(temporaryMovie.path)")
        }
        try? FileManager.default.removeItem(at: temporaryMovie.deletingLastPathComponent())
    }
}

private final class CaptureOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}
