import Foundation
import CryptoKit
import Darwin

/// Cancellation is scoped to processes owned by one run; never kills the shared adb server.
public final class AutomationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public func check() throws { if isCancelled || Task.isCancelled { throw AutomationError.cancelled } }
}

public struct CommandOutput {
    public let code: Int32
    public let text: String
}

public enum AutomationProcess {
    /// File-backed output prevents pipe deadlocks and bounds in-memory diagnostics.
    public static func run(_ path: String, _ arguments: [String], timeout: Double = 15,
                           cancellation: AutomationCancellation = AutomationCancellation(),
                           environment: [String: String] = [:], output: URL? = nil) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let temporary = output == nil
                let destination = output ?? FileManager.default.temporaryDirectory.appendingPathComponent("lcm-command-" + UUID().uuidString)
                do {
                    try cancellation.check()
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw AutomationError.infrastructure("无法创建执行输出文件") }
                    let file = try FileHandle(forWritingTo: destination)
                    defer { try? file.close(); if temporary { try? FileManager.default.removeItem(at: destination) } }
                    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
                    process.standardOutput = file; process.standardError = file; process.standardInput = FileHandle.nullDevice
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                    try process.run()
                    let start = ProcessInfo.processInfo.systemUptime
                    var termination: Error?
                    while process.isRunning {
                        if cancellation.isCancelled { termination = AutomationError.cancelled; break }
                        if ProcessInfo.processInfo.systemUptime - start > timeout { termination = AutomationError.infrastructure("执行超时（\(Int(timeout)) 秒）：\(URL(fileURLWithPath: path).lastPathComponent)"); break }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if termination != nil && process.isRunning {
                        process.terminate()
                        let deadline = ProcessInfo.processInfo.systemUptime + 2
                        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
                        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                    }
                    process.waitUntilExit(); try file.synchronize()
                    if let termination { throw termination }
                    try cancellation.check()
                    let reader = try FileHandle(forReadingFrom: destination)
                    defer { try? reader.close() }
                    let size = try reader.seekToEnd()
                    try reader.seek(toOffset: size > 262144 ? size - 262144 : 0)
                    let data = try reader.readToEnd() ?? Data()
                    continuation.resume(returning: CommandOutput(code: process.terminationStatus, text: String(decoding: data, as: UTF8.self)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public static func checked(_ path: String, _ arguments: [String], timeout: Double = 15,
                               cancellation: AutomationCancellation = AutomationCancellation(),
                               environment: [String: String] = [:], output: URL? = nil) async throws -> String {
        let result = try await run(path, arguments, timeout: timeout, cancellation: cancellation, environment: environment, output: output)
        guard result.code == 0 else { throw AutomationError.infrastructure(String(result.text.suffix(4000))) }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct AutomationTools: Codable, Equatable {
    public var adb: String
    public var aapt2: String
    public var maestro: String
    public var javaHome: String
    public init(adb: String = "", aapt2: String = "", maestro: String = "", javaHome: String = "") {
        self.adb = adb; self.aapt2 = aapt2; self.maestro = maestro; self.javaHome = javaHome
    }
    public static func discover(adb: String? = nil) -> AutomationTools {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sdk = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] ?? home + "/Library/Android/sdk"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: sdk + "/build-tools")) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        func existing(_ paths: [String]) -> String { paths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "" }
        let javaCandidates = ((try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/Java/JavaVirtualMachines")) ?? [])
            .filter { $0.contains("17") || $0.contains("21") }.sorted().reversed()
            .map { home + "/Library/Java/JavaVirtualMachines/" + $0 + "/Contents/Home" }
        let java = ProcessInfo.processInfo.environment["JAVA_HOME"] ?? javaCandidates.first ?? ""
        return AutomationTools(adb: adb ?? ADB.locate() ?? "",
            aapt2: existing(versions.map { sdk + "/build-tools/" + $0 + "/aapt2" }),
            maestro: existing([home + "/.maestro/bin/maestro", "/opt/homebrew/bin/maestro", "/usr/local/bin/maestro",
                              home + "/Library/Caches/LogcatMini/Maestro/maestro/bin/maestro"]),
            javaHome: java)
    }
    public var engineEnvironment: [String: String] {
        var env = ["MAESTRO_CLI_NO_ANALYTICS": "1", "MAESTRO_CLI_NO_TRACKING": "1",
                   "MAESTRO_DRIVER_STARTUP_TIMEOUT": "30000", "CI": "true",
                   "ANDROID_HOME": URL(fileURLWithPath: adb).deletingLastPathComponent().deletingLastPathComponent().path]
        if !javaHome.isEmpty { env["JAVA_HOME"] = javaHome }
        env["PATH"] = URL(fileURLWithPath: adb).deletingLastPathComponent().path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        return env
    }
    public func validate(needsMaestro: Bool = true) throws {
        for (name, path) in [("ADB", adb), ("aapt2", aapt2)] + (needsMaestro ? [("Maestro", maestro), ("Java", javaHome + "/bin/java")] : []) {
            guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { throw AutomationError.configuration("请配置可执行的 \(name) 路径") }
        }
    }
}

public enum APKInspector {
    public static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func inspect(_ url: URL, aapt2: String) async throws -> APKInfo {
        guard url.pathExtension.lowercased() == "apk" else { throw AutomationError.configuration("请选择可独立安装的 APK 文件") }
        let text = try await AutomationProcess.checked(aapt2, ["dump", "badging", url.path], timeout: 30)
        return try parse(text, sha256: sha256(url))
    }
    public static func parse(_ text: String, sha256: String) throws -> APKInfo {
        func match(_ pattern: String) -> String {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines),
                  let result = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(result.range(at: 1), in: text) else { return "" }
            return String(text[range])
        }
        let package = match("^package: name='([^']+)'")
        guard TestSuite.validPackage(package), !match("versionCode='([^']+)'").isEmpty else { throw AutomationError.configuration("APK 元数据读取失败：未识别到有效包名和版本") }
        guard !text.contains(" split='") else { throw AutomationError.configuration("首版不支持拆分 APK，请选择完整 APK") }
        return APKInfo(name: match("^application-label:'(.*)'").isEmpty ? package : match("^application-label:'(.*)'"),
            packageName: package, versionName: match("versionName='([^']*)'"), versionCode: match("versionCode='([^']+)'"),
            minimumSDK: Int(match("^(?:minSdkVersion|sdkVersion):'(\\d+)'")) ?? 1, abi: match("^native-code: (.*)"),
            debuggable: text.contains("application-debuggable"), sha256: sha256)
    }
}
