import Foundation
import Security
import LogcatCore

struct IOSIDFAResult: Codable, Equatable {
    let schemaVersion: Int
    let requestID: String
    let bundleID: String
    let idfa: String
    let authorization: String
    let isSimulator: Bool
    let generatedAt: Double
    static let zero = "00000000-0000-0000-0000-000000000000"
    var usableIDFA: String? {
        guard !isSimulator, authorization == "authorized", UUID(uuidString: idfa) != nil, idfa != Self.zero else { return nil }
        return idfa.uppercased()
    }
    var status: String {
        if isSimulator { return "模拟器不提供有效 IDFA" }
        switch authorization {
        case "authorized": return usableIDFA == nil ? "助手已授权，但系统返回全零 IDFA" : "助手已授权"
        case "denied": return "助手未获跟踪授权"
        case "restricted": return "跟踪授权受系统限制"
        case "notDetermined": return "等待在手机助手中授权"
        default: return "未知授权状态"
        }
    }
    static func decode(_ data: Data, requestID: String, bundleID: String, simulator: Bool, since: Date, now: Date = Date()) throws -> Self {
        guard data.count <= 16_384 else { throw LocalBuildError.message("助手返回结果过大。") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.requestID == requestID, value.bundleID == bundleID,
              value.isSimulator == simulator, UUID(uuidString: value.idfa) != nil,
              ["authorized", "denied", "restricted", "notDetermined", "unknown"].contains(value.authorization),
              value.generatedAt.isFinite, value.generatedAt >= since.timeIntervalSince1970 - 300,
              value.generatedAt <= now.timeIntervalSince1970 + 300,
              (value.authorization == "authorized" && !simulator) || value.idfa == zero else {
            throw LocalBuildError.message("助手结果与本次读取不匹配，或设备时间相差超过 5 分钟。请检查设备时间后重试。")
        }
        return value
    }
}

struct IOSSigningTeam: Identifiable, Hashable {
    let id: String
    let name: String
    static func available() -> [Self] {
        var result: CFTypeRef?
        guard SecItemCopyMatching([kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll] as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return [] }
        var found: [String: Self] = [:]
        for identity in identities {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  let summary = SecCertificateCopySubjectSummary(certificate) as String?, summary.hasPrefix("Apple Development:") || summary.hasPrefix("iPhone Developer:"),
                  let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
                  let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
                  let attributes = subject[kSecPropertyKeyValue as String] as? [[String: Any]],
                  let team = attributes.first(where: { ($0[kSecPropertyKeyLabel as String] as? String) == "2.5.4.11" })?[kSecPropertyKeyValue as String] as? String,
                  team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { continue }
            found[team] = Self(id: team, name: summary)
        }
        return found.values.sorted { $0.id < $1.id }
    }
}

struct IOSIDFAService {
    typealias Runner = LocalBuildController.Runner
    var run: Runner = { command, output in try await BuildProcessRunner().run(command, output: output) }
    var source: URL = Bundle.module.url(forResource: "IOSDeviceInfoHelper", withExtension: nil)!
    var cache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.songran.LogcatMini/IDFAHelper", isDirectory: true)
    static func bundleID(team: String, simulator: Bool) throws -> String {
        if simulator { return "com.logcatmini.idfahelper.simulator" }
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw LocalBuildError.message("请选择签名团队，或输入 10 位 Apple Team ID。需要在 Xcode 中登录该开发者账号。") }
        return "com.logcatmini.idfahelper.t" + team.lowercased()
    }
    func read(device: IOSDevice, team: String, progress: @escaping @MainActor @Sendable (String) -> Void) async throws -> IOSIDFAResult {
        let simulator = device.kind == .simulator
        let bundle = try Self.bundleID(team: team, simulator: simulator)
        let root = cache.appendingPathComponent(bundle)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep the signed Mac app bundle read-only; Xcode may create project metadata.
        let project = root.appendingPathComponent("Source")
        for path in ["Helper.swift", "Info.plist", "Helper.xcodeproj/project.pbxproj"] {
            let destination = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: source.appendingPathComponent(path))
            if (try? Data(contentsOf: destination)) != data { try data.write(to: destination, options: .atomic) }
        }
        let request = UUID().uuidString
        let transfer = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-idfa-" + request)
        try FileManager.default.createDirectory(at: transfer, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: transfer) }
        await progress("正在构建 IDFA 助手…")
        let sdk = simulator ? "iphonesimulator" : "iphoneos"
        var args = ["xcodebuild", "-project", project.appendingPathComponent("Helper.xcodeproj").path, "-scheme", "Helper", "-configuration", "Debug",
                    "-sdk", sdk, "-destination", "id=" + device.udid, "-derivedDataPath", root.path,
                    "PRODUCT_BUNDLE_IDENTIFIER=" + bundle, "-quiet"]
        if simulator { args += ["CODE_SIGNING_ALLOWED=NO"] }
        else { args += ["DEVELOPMENT_TEAM=" + team, "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"] }
        try await command(args, timeout: 240)
        try Task.checkCancellation()
        let app = root.appendingPathComponent("Build/Products/Debug-\(sdk)/Helper.app")
        try IOSBuildProject.verifyApp(app, bundleID: bundle, device: device)
        await progress("正在安装并打开 IDFA 助手…")
        try await command(simulator ? ["simctl", "install", device.udid, app.path] : ["devicectl", "device", "install", "app", "--device", device.udid, app.path, "--quiet"], timeout: 90)
        try Task.checkCancellation()
        let started = Date()
        try await command(simulator ? ["simctl", "launch", "--terminate-running-process", device.udid, bundle, "--request-id", request] :
            ["devicectl", "device", "process", "launch", "--device", device.udid, "--terminate-existing", "--quiet", bundle, "--", "--request-id", request], timeout: 30)
        let resultFile: URL
        if simulator {
            let output = try await output(["simctl", "get_app_container", device.udid, bundle, "data"], timeout: 20)
            resultFile = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("Documents/idfa-result.json")
        } else { resultFile = transfer.appendingPathComponent("idfa-result.json") }
        await progress("请在手机助手中点击「授权并读取 IDFA」，并选择是否允许跟踪。")
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        var lastError: Error?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                if !simulator {
                    try? FileManager.default.removeItem(at: resultFile)
                    try await command(["devicectl", "device", "copy", "from", "--device", device.udid,
                        "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                        "--source", "Documents/idfa-result.json", "--destination", resultFile.path, "--quiet", "--timeout", "10"], timeout: 15)
                }
                let result = try IOSIDFAResult.decode(Data(contentsOf: resultFile), requestID: request, bundleID: bundle, simulator: simulator, since: started)
                if simulator || result.authorization != "notDetermined" { return result }
                lastError = nil
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
            try await Task.sleep(for: .seconds(1.5))
        }
        throw LocalBuildError.message(lastError.map { "未能读取助手结果：\($0.localizedDescription)" } ?? "等待授权超时。可在手机完成选择后，回到这里重新读取。")
    }
    private func output(_ args: [String], timeout: TimeInterval) async throws -> String {
        try Task.checkCancellation()
        let result = try await run(.init(executable: "/usr/bin/xcrun", arguments: args, timeout: timeout), { _ in })
        guard result.status == 0 else { throw LocalBuildError.message(String(result.output.suffix(6000))) }
        return result.output
    }
    private func command(_ args: [String], timeout: TimeInterval) async throws { _ = try await output(args, timeout: timeout) }
}
