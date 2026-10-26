import Foundation
import LogcatCore

struct DeviceInfoTarget: Equatable {
    let path: String
    let serial: String
    let name: String
}

struct DeviceInfoSnapshot {
    let properties: [String: String]
    let androidID: String?

    static func parseProperties(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard line.hasPrefix("["), line.hasSuffix("]"), let split = line.range(of: "]: [") else { continue }
            values[String(line[line.index(after: line.startIndex)..<split.lowerBound])] =
                String(line[split.upperBound..<line.index(before: line.endIndex)])
        }
        return values
    }
}

struct AdvertisingIDResult: Codable, Equatable {
    let schema: Int
    let status: String
    let gaid: String?
    let limitAdTracking: Bool?
    let permissionGranted: Bool?
    let error: String?

    var isCacheable: Bool {
        guard schema == 1, permissionGranted == true, let gaid, UUID(uuidString: gaid) != nil else { return false }
        return status == "available" && gaid != "00000000-0000-0000-0000-000000000000"
            || status == "zero" && gaid == "00000000-0000-0000-0000-000000000000"
    }

    static func parse(_ output: String) throws -> Self {
        let prefix = "INSTRUMENTATION_RESULT: logcatMiniInfo="
        guard let line = output.components(separatedBy: .newlines).first(where: { $0.hasPrefix(prefix) }),
              let result = try? JSONDecoder().decode(Self.self, from: Data(line.dropFirst(prefix.count).utf8)),
              result.schema == 1 else {
            throw MirrorError.message("设备信息助手没有返回有效结果，请确认手机已授权，并重试读取。")
        }
        if result.status == "available" {
            guard let id = result.gaid, UUID(uuidString: id) != nil,
                  id != "00000000-0000-0000-0000-000000000000", result.permissionGranted == true else {
                throw MirrorError.message("手机返回的 GAID 无效，请检查 Google Play 服务后重试。")
            }
        }
        return result
    }

    var explanation: String {
        switch status {
        case "available": return limitAdTracking == true ? "已读取；手机已限制广告跟踪。" : "已通过 Google Play 服务读取。"
        case "zero": return permissionGranted == true ? "系统返回全零，广告 ID 可能已删除或不可用。可打开广告 ID 设置查看。" : "设备信息助手缺少广告 ID 读取权限。"
        case "missing_play_services": return "这台手机没有可用的 Google Play 服务，无法读取 GAID。"
        case "repair_play_services": return "请先在手机上启用或更新 Google Play 服务，然后重试。"
        default: return "暂时无法读取 GAID，请检查 Google Play 服务后重试。" + (error.map { "（\($0)）" } ?? "")
        }
    }
}

struct DeviceInfoService {
    typealias Runner = ([String], TimeInterval) async throws -> String
    private let run: Runner
    static let helperPackage = "com.songran.logcatmini.deviceinfo"

    init(target: DeviceInfoTarget) {
        run = { arguments, timeout in
            try await ADB.run(path: target.path, arguments: ["-s", target.serial] + arguments, timeout: timeout)
        }
    }
    init(run: @escaping Runner) { self.run = run }

    func readBasics() async throws -> DeviceInfoSnapshot {
        let properties = try await run(["shell", "getprop"], 8)
        try Task.checkCancellation()
        // This is the shell user's value, not the SSAID seen by an arbitrary installed app.
        let androidID = try? await run(["shell", "settings", "--user", "current", "get", "secure", "android_id"], 8)
        try Task.checkCancellation()
        let value = androidID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = value.map { $0.range(of: "^[0-9a-fA-F]{16}$", options: .regularExpression) != nil } ?? false
        return DeviceInfoSnapshot(properties: DeviceInfoSnapshot.parseProperties(properties), androidID: valid ? value : nil)
    }

    func readAdvertisingID(helper: URL) async throws -> AdvertisingIDResult {
        let user = try await run(["shell", "am", "get-current-user"], 8)
        guard !user.isEmpty, user.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw MirrorError.message("无法确认手机当前用户，请解锁手机后重试。")
        }
        try Task.checkCancellation()
        let installed = try await run(["shell", "pm", "list", "packages", "--show-versioncode", "--user", user, Self.helperPackage], 8)
        if !installed.components(separatedBy: .newlines).contains("package:\(Self.helperPackage) versionCode:1") {
            let result = try await run(["install", "-r", "--user", user, helper.path], 60)
            guard result.components(separatedBy: .newlines).contains("Success") else {
                throw MirrorError.message("设备信息助手安装未完成：\(result)")
            }
        }
        try Task.checkCancellation()
        let output = try await run(["shell", "am", "instrument", "--user", user, "-w", "-r",
                                    Self.helperPackage + "/.DeviceInfoReader"], 25)
        try Task.checkCancellation()
        return try AdvertisingIDResult.parse(output)
    }

    /// Opens the OS-controlled reset/delete UI. Never changes identifiers or clears Play services data.
    func openAdvertisingSettings() async throws {
        try Task.checkCancellation()
        let resolution = try await run(["shell", "cmd", "package", "resolve-activity", "--brief", "--user", "current",
                                        "-a", "com.google.android.gms.settings.ADS_PRIVACY", "-p", "com.google.android.gms"], 8)
        guard resolution.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("com.google.android.gms/") }) else {
            throw MirrorError.message("这台手机未提供 Google 广告 ID 设置入口。请在手机「设置 → Google → 所有服务 → 广告」中查看。")
        }
        try Task.checkCancellation()
        let output = try await run(["shell", "am", "start", "--user", "current", "-a", "com.google.android.gms.settings.ADS_PRIVACY",
                                    "-p", "com.google.android.gms"], 8)
        guard !output.localizedCaseInsensitiveContains("error"), !output.contains("Exception") else {
            throw MirrorError.message("无法打开广告 ID 设置：\(output)")
        }
    }
}
