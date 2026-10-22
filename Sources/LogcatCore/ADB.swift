import Foundation

public enum ADBError: LocalizedError {
    case failed(String)
    public var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
}

public enum ADB {
    public static func locate(custom: String? = nil) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [custom ?? "", home + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        if let root = ProcessInfo.processInfo.environment["ANDROID_HOME"] { paths.append(root + "/platform-tools/adb") }
        if let root = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] { paths.append(root + "/platform-tools/adb") }
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/adb" }
        return paths.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs off the UI thread. Uses argument arrays, never a shell or interpolated commands.
    public static func run(path: String, arguments: [String], timeout: TimeInterval = 8) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = pipe; process.standardError = pipe
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); watchdog.cancel()
                let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 { continuation.resume(returning: result) }
                else { continuation.resume(throwing: ADBError.failed(result.isEmpty ? "ADB 请求失败或超时" : result)) }
            }
        }
    }
}

/// Owns exactly one adb client process. Stopping never kills the shared adb server.
public final class LogStream {
    private var process: Process?
    private let lock = NSLock()
    public init() {}
    public func start(path: String, serial: String, uid: String?, onLines: @escaping ([String]) -> Void, onExit: @escaping (String) -> Void) throws {
        stop()
        let child = Process(), output = Pipe(), errors = Pipe()
        child.executableURL = URL(fileURLWithPath: path)
        // The device clock avoids importing old phone-buffer entries on each new session.
        // Only this fixed command and a validated numeric UID reach the device shell.
        if let uid, uid.isEmpty || !uid.utf8.allSatisfy({ (48...57).contains($0) }) { throw NSError(domain: "LogcatMini", code: 1, userInfo: [NSLocalizedDescriptionKey: "应用 UID 无效"]) }
        var command = "exec logcat -v threadtime -v year -T \"$(date '+%m-%d %H:%M:%S.%3N')\" -b main -b system -b crash"
        if let uid { command += " --uid=" + uid }
        command += " '*:V'"
        let arguments = ["-s", serial, "shell", command]
        child.arguments = arguments; child.standardOutput = output; child.standardError = errors
        try child.run()
        lock.lock(); process = child; lock.unlock()
        let errorCollector = ErrorCollector()
        DispatchQueue.global(qos: .utility).async {
            errorCollector.set(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var framer = LineFramer()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                let lines = framer.append(data)
                if !lines.isEmpty { onLines(lines) }
            }
            if let remaining = framer.finish() { onLines([remaining]) }
            child.waitUntilExit()
            guard let self = self else { return }
            self.lock.lock()
            let active = self.process === child
            if active { self.process = nil }
            self.lock.unlock()
            if active {
                let reason = errorCollector.get().trimmingCharacters(in: .whitespacesAndNewlines)
                onExit(reason.isEmpty ? "日志连接已结束，请检查手机连接后重新开始。" : reason)
            }
        }
    }
    public func stop() {
        lock.lock(); let child = process; process = nil; lock.unlock()
        if let child = child, child.isRunning { child.terminate() }
    }
    deinit { stop() }
}

private final class ErrorCollector {
    private let lock = NSLock()
    private var value = ""
    func set(_ text: String) { lock.lock(); value = text; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}
