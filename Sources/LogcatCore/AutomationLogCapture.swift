import Foundation

/// A test owns its own streams and disk evidence; viewer filters and Clear do not affect it.
final class AutomationLogCapture: @unchecked Sendable {
    private let app = LogStream(), system = LogStream()
    private let lock = NSLock()
    private var file: FileHandle?
    private var systemFile: FileHandle?
    private var issue: String?
    private var closed = false
    private var fatalEvents: [String] = []
    private let appURL: URL
    init(directory: URL) throws {
        appURL = directory.appendingPathComponent("app.log")
        let systemURL = directory.appendingPathComponent("system-events.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: appURL.path, contents: nil),
              FileManager.default.createFile(atPath: systemURL.path, contents: nil) else { throw AutomationError.infrastructure("不能创建测试日志文件") }
        file = try FileHandle(forWritingTo: appURL); systemFile = try FileHandle(forWritingTo: systemURL)
    }
    func start(path: String, serial: String, uid: String, package: String) throws {
        try app.start(path: path, serial: serial, uid: uid, onLines: { [weak self] lines in
            self?.append(lines, system: false, package: package)
        }, onExit: { [weak self] reason in self?.markIssue("应用日志采集中断：\(reason)") })
        do {
            try system.start(path: path, serial: serial, uid: nil, onLines: { [weak self] lines in
                self?.append(lines.filter { $0.contains(package) }, system: true, package: package)
            }, onExit: { [weak self] reason in self?.markIssue("系统事件采集中断：\(reason)") })
        } catch { app.stop(); throw error }
    }
    private func append(_ lines: [String], system: Bool, package: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !lines.isEmpty else { return }
        do {
            try (system ? systemFile : file)?.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            for line in lines {
                guard let entry = LogParser.parse(line, id: 0) else { continue }
                if (!system && ((entry.tag == "AndroidRuntime" && entry.message.contains("FATAL EXCEPTION:")) ||
                    (entry.tag == "libc" && entry.message.contains("Fatal signal ")))) ||
                    (system && entry.tag == "ActivityManager" && entry.message.contains("ANR in " + package)) {
                    fatalEvents.append(line)
                }
            }
        } catch { issue = "日志保存失败：\(error.localizedDescription)" }
    }
    private func markIssue(_ message: String) { lock.lock(); defer { lock.unlock() }; if !closed { issue = message } }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if let issue { throw AutomationError.infrastructure(issue) }
    }
    func cursor() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let issue { throw AutomationError.infrastructure(issue) }
        return try file?.offset() ?? 0
    }
    func lines(since offset: UInt64) throws -> [String] {
        try check()
        let reader = try FileHandle(forReadingFrom: appURL); defer { try? reader.close() }
        let end = try reader.seekToEnd()
        guard end >= offset, end - offset <= 16 * 1024 * 1024 else { throw AutomationError.infrastructure("日志窗口超过 16 MiB 或文件被修改，无法可靠判断") }
        try reader.seek(toOffset: offset)
        return String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
    func faults(since index: Int) -> [String] { lock.lock(); defer { lock.unlock() }; return Array(fatalEvents.dropFirst(index)) }
    var faultCount: Int { lock.lock(); defer { lock.unlock() }; return fatalEvents.count }
    func stop() {
        app.stop(); system.stop()
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        try? file?.synchronize(); try? systemFile?.synchronize()
        try? file?.close(); try? systemFile?.close(); file = nil; systemFile = nil
    }
    deinit { stop() }
}
