import Foundation
import LogcatCore

/// Each invocation owns its supervisor and job group. Cancellation never stops shared ADB/Gradle services.
final class BuildProcessRunner: @unchecked Sendable {
    struct Command {
        var executable: String
        var arguments: [String]
        var directory: URL?
        var environment: [String: String] = [:]
        var timeout: TimeInterval = 180
    }
    struct Result { let status: Int32; let output: String }
    typealias Output = @Sendable (String) -> Void

    func run(_ command: Command, output: @escaping Output) async throws -> Result {
        let job = Job()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try job.execute(command, output: output)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { job.cancel() })
    }

    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var timedOut = false
        func cancel(timeout: Bool = false) {
            lock.lock(); cancelled = true; timedOut = timedOut || timeout
            if let process, process.isRunning { process.terminate() }
            lock.unlock()
        }
        func execute(_ command: Command, output: @escaping Output) throws -> Result {
            let child = Process(), pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Arguments remain positional parameters, including paths with spaces or shell metacharacters.
            let supervisor = "exec 3>&2; exec 2>/dev/null; set -m; \"$@\" 2>&3 & child=$!; trap 'kill -TERM -- -\"$child\" 2>/dev/null; sleep 1; kill -KILL -- -\"$child\" 2>/dev/null; exit 130' TERM INT; wait \"$child\"; result=$?; exit \"$result\""
            child.arguments = ["-c", supervisor, "logcat-mini-build", command.executable] + command.arguments
            child.currentDirectoryURL = command.directory
            child.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
            child.standardOutput = pipe; child.standardError = pipe
            child.standardInput = FileHandle.nullDevice
            lock.lock()
            if cancelled { lock.unlock(); throw CancellationError() }
            do { try child.run(); process = child; lock.unlock() }
            catch { lock.unlock(); throw error }
            let watchdog = DispatchWorkItem { [weak self] in self?.cancel(timeout: true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + command.timeout, execute: watchdog)
            var framer = LineFramer(), captured = ""
            while true {
                let bytes = pipe.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                let text = framer.append(bytes).joined(separator: "\n")
                if !text.isEmpty {
                    output(text + "\n"); captured += text + "\n"
                    if captured.utf8.count > 1_000_000 { captured = String(captured.suffix(500_000)) }
                }
            }
            if let tail = framer.finish() { output(tail); captured += tail }
            // This wait runs on a dedicated dispatch worker, never Swift's cooperative executor.
            child.waitUntilExit(); watchdog.cancel()
            lock.lock(); process = nil; let stopped = cancelled, expired = timedOut; lock.unlock()
            if expired { throw LocalBuildError.message("执行超时，已停止本次任务。") }
            if stopped { throw CancellationError() }
            return Result(status: child.terminationStatus, output: captured)
        }
    }
}
