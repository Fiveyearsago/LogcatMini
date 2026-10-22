import Foundation
import CryptoKit

public struct AppMetadata: Codable, Equatable {
    public let packageName: String
    public let label: String
    public var iconPNG: Data?
    public let lastUpdateTime: Int64

    public init(packageName: String, label: String, iconPNG: Data?, lastUpdateTime: Int64) {
        self.packageName = packageName; self.label = label
        self.iconPNG = iconPNG; self.lastUpdateTime = lastUpdateTime
    }
}

public enum AppMetadataDecoder {
    public static let marker = "LOGCAT_MINI_METADATA:"

    /// Package arguments pass through adb's remote shell, so allow only Android identifiers.
    public static func validPackage(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 &&
        value.range(of: #"\A[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*\z"#, options: .regularExpression) != nil
    }

    public static func decode(_ output: String, requested: Set<String>) throws -> [AppMetadata] {
        guard let line = output.components(separatedBy: .newlines).last(where: { $0.hasPrefix(marker) }),
              let data = line.dropFirst(marker.count).data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema"] as? Int == 1, let apps = root["apps"] as? [[String: Any]] else {
            throw ADBError.failed("未能读取应用名称和图标")
        }
        var result: [String: AppMetadata] = [:]
        for app in apps {
            guard let name = app["packageName"] as? String, validPackage(name), requested.contains(name),
                  app["error"] == nil, let label = app["label"] as? String,
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var icon: Data?
            if let base64 = app["iconPNG"] as? String, base64.utf8.count <= 700_000,
               let bytes = Data(base64Encoded: base64), bytes.count <= 512_000,
               bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { icon = bytes }
            result[name] = AppMetadata(packageName: name, label: String(label.prefix(256)), iconPNG: icon,
                                       lastUpdateTime: (app["lastUpdateTime"] as? NSNumber)?.int64Value ?? 0)
        }
        return result.values.sorted { $0.packageName < $1.packageName }
    }
}

/// Cached separately for each device: the same package may have different branding/versions.
public struct AppMetadataCache {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func file(for serial: String) -> URL {
        let key = SHA256.hash(data: Data(serial.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    public func load(serial: String) -> [String: AppMetadata] {
        guard let data = try? Data(contentsOf: file(for: serial)),
              let entries = try? JSONDecoder().decode([AppMetadata].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.packageName, $0) }, uniquingKeysWith: { _, new in new })
    }
    public func save(_ entries: [String: AppMetadata], serial: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries.values.sorted { $0.packageName < $1.packageName })
        try data.write(to: file(for: serial), options: .atomic)
    }
}

/// Runs a tiny bundled DEX under the already-authorized adb shell; no APK is installed.
public actor AppMetadataService {
    private let helperURL: URL
    private let cache: AppMetadataCache
    public init(helperURL: URL, cacheDirectory: URL) {
        self.helperURL = helperURL; cache = AppMetadataCache(directory: cacheDirectory)
    }
    public func cached(serial: String) -> [String: AppMetadata] { cache.load(serial: serial) }

    public func refresh(adbPath: String, serial: String, packageIDs: [String]) async throws -> [String: AppMetadata] {
        let ids = Array(Set(packageIDs.filter(AppMetadataDecoder.validPackage))).sorted()
        guard !ids.isEmpty else { return cache.load(serial: serial) }
        let remote = "/data/local/tmp/logcat-mini-metadata-" + UUID().uuidString.lowercased() + ".jar"
        func run(_ args: [String], timeout: TimeInterval = 15) async throws -> String {
            try await ADB.run(path: adbPath, arguments: ["-s", serial] + args, timeout: timeout)
        }
        var updates: [AppMetadata] = []
        do {
            try Task.checkCancellation()
            _ = try await run(["push", helperURL.path, remote])
            try Task.checkCancellation()
            // Android 14+ requires dynamically loaded code to be read-only.
            _ = try await run(["shell", "chmod", "444", remote])
            for offset in stride(from: 0, to: ids.count, by: 20) {
                try Task.checkCancellation()
                let batch = Array(ids[offset..<min(offset + 20, ids.count)])
                let output = try await run(["shell", "env", "CLASSPATH=" + remote, "app_process", "/",
                                            "com.songran.logcatmini.AppMetadata"] + batch, timeout: 25)
                updates += try AppMetadataDecoder.decode(output, requested: Set(batch))
            }
        } catch {
            _ = try? await run(["shell", "rm", "-f", remote], timeout: 5)
            throw error
        }
        _ = try? await run(["shell", "rm", "-f", remote], timeout: 5)
        try Task.checkCancellation()
        var merged = cache.load(serial: serial)
        for var item in updates {
            if item.iconPNG == nil, let previous = merged[item.packageName], previous.lastUpdateTime == item.lastUpdateTime {
                item.iconPNG = previous.iconPNG
            }
            merged[item.packageName] = item
        }
        // A disk-cache failure must not prevent the fresh metadata from appearing.
        try? cache.save(merged, serial: serial)
        return merged
    }
}
