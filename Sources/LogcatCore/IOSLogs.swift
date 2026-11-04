import Foundation

public struct IOSDevice: Identifiable, Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case usb, simulator }
    public let udid: String
    public let name: String
    public let kind: Kind
    public var id: String { kind.rawValue + ":" + udid }
    public var title: String { name + (kind == .simulator ? " · 模拟器" : " · USB") }
    public init(udid: String, name: String, kind: Kind) {
        self.udid = udid; self.name = name; self.kind = kind
    }
    public static func bootedSimulators(_ data: Data) throws -> [IOSDevice] {
        struct List: Decodable {
            struct Device: Decodable { let udid: String; let name: String; let state: String; let isAvailable: Bool? }
            let devices: [String: [Device]]
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        return list.devices.filter { $0.key.contains(".iOS-") }.flatMap(\.value)
            .filter { $0.state == "Booted" && $0.isAvailable != false }
            .map { IOSDevice(udid: $0.udid, name: $0.name, kind: .simulator) }
            .sorted { $0.id < $1.id }
    }
}

public struct IOSLogProcess: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    public let executable: String
    public let bundlePath: String?
    public let isSystem: Bool
    public init(id: String, name: String, executable: String, bundlePath: String? = nil, isSystem: Bool = false) {
        self.id = id; self.name = name; self.executable = executable; self.bundlePath = bundlePath; self.isSystem = isSystem
    }
    public static func simulatorApps(_ data: Data) throws -> [IOSLogProcess] {
        guard let apps = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else { return [] }
        return apps.compactMap { id, app in
            guard let executable = app["CFBundleExecutable"] as? String, !executable.isEmpty else { return nil }
            return IOSLogProcess(id: id, name: app["CFBundleDisplayName"] as? String ?? app["CFBundleName"] as? String ?? id, executable: executable,
                                 bundlePath: app["Path"] as? String, isSystem: app["ApplicationType"] as? String == "System")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func installedDeviceApps(_ data: Data) throws -> [IOSLogProcess] {
        struct Output: Decodable {
            struct Result: Decodable {
                struct App: Decodable { let bundleIdentifier: String; let name: String; let url: String?; let executableName: String?; let defaultApp: Bool? }
                let apps: [App]
            }
            let result: Result
        }
        return try JSONDecoder().decode(Output.self, from: data).result.apps.map { app in
            let bundle = app.url.flatMap(URL.init(string:))
            return IOSLogProcess(id: app.bundleIdentifier, name: app.name,
                executable: app.executableName ?? bundle?.deletingPathExtension().lastPathComponent ?? app.name,
                bundlePath: bundle?.path, isSystem: app.defaultApp ?? false)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func deviceProcesses(_ text: String) -> [IOSLogProcess] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, UInt64(fields[0]) != nil else { return nil }
            let executable = String(fields[1]).trimmingCharacters(in: .whitespaces)
            guard !executable.isEmpty, seen.insert(executable).inserted else { return nil }
            return IOSLogProcess(id: executable, name: executable, executable: executable)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum IOSLogParser {
    // os_trace_relay: Nov  3 10:11:12.123456 Runner(UIKitCore)[123] <Notice>: ...
    // syslog_relay:   Nov  3 10:11:12 iPhone Runner[123] <Warning>: ...
    private static let devicePattern = try! NSRegularExpression(pattern: #"^([A-Za-z]{3}\s+\d{1,2})\s+(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(.+?)\[(\d+)\]\s+<([^>]+)>:\s?(.*)$"#)
    public static func device(_ line: String, id: UInt64) -> LogEntry? {
        guard let match = devicePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func field(_ n: Int) -> String { Range(match.range(at: n), in: line).map { String(line[$0]) } ?? "" }
        return LogEntry(id: id, date: field(1), time: field(2), pid: field(4), tid: "—",
                        level: level(field(5)), tag: field(3), message: field(6), raw: line)
    }
    public static func simulator(_ line: String, id: UInt64) -> LogEntry? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = value["eventMessage"] as? String,
              let timestamp = value["timestamp"] as? String else { return nil }
        let parts = timestamp.split(separator: " ", maxSplits: 1).map(String.init)
        let date = parts.first ?? "", time = parts.count > 1 ? parts[1] : ""
        let process = (value["processImagePath"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "iOS"
        let subsystem = value["subsystem"] as? String ?? ""
        let category = value["category"] as? String ?? ""
        let tag = ([process] + [subsystem, category].filter { !$0.isEmpty }).joined(separator: " / ")
        let pid = (value["processID"] as? NSNumber)?.stringValue ?? "—"
        let tid = (value["threadID"] as? NSNumber)?.stringValue ?? "—"
        let priority = level(value["messageType"] as? String ?? "Default")
        let raw = "\(date) \(time) \(pid) \(tid) \(priority.rawValue) \(tag): \(message)"
        return LogEntry(id: id, date: date, time: time, pid: pid, tid: tid, level: priority, tag: tag, message: message, raw: raw)
    }
    private static func level(_ text: String) -> LogLevel {
        switch text.lowercased() {
        case "debug": return .debug
        case "warning", "warn": return .warning
        case "error": return .error
        case "fault", "fatal", "critical", "alert", "emergency": return .fatal
        default: return .info
        }
    }
}

public enum IOSTools {
    public static func locate(_ name: String) -> String? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func streamArguments(device: IOSDevice, process: String, processPath: String? = nil) -> [String] {
        let process = process.trimmingCharacters(in: .whitespacesAndNewlines)
        if device.kind == .simulator {
            let base = ["simctl", "spawn", device.udid, "log", "stream", "--style", "ndjson", "--level", "debug", "--color", "none"]
            if let processPath, !processPath.isEmpty {
                let literal = processPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return base + ["--predicate", "processImagePath == \"\(literal)\""]
            }
            return base + (process.isEmpty ? [] : ["--process", process])
        }
        return ["-u", device.udid, "--no-colors", "-x"] + (process.isEmpty ? [] : ["-p", process])
    }
    public static func screenshotArguments(device: IOSDevice, destination: String) -> [String] {
        device.kind == .simulator ? ["simctl", "io", device.udid, "screenshot", "--type=png", destination] :
            ["devicectl", "device", "capture", "screenshot", "--device", device.udid, "--destination", destination]
    }
    public static func recordingArguments(device: IOSDevice, destination: String) -> [String] {
        device.kind == .simulator ? ["simctl", "io", device.udid, "recordVideo", "--codec=h264", destination] :
            ["devicectl", "device", "capture", "screen-record", "--device", device.udid, "--destination", destination, "--codec", "h264"]
    }
}
