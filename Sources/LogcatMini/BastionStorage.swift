import Foundation
import CryptoKit
import Network

struct BastionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct BastionApp: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var packageName = ""
    var ip = ""
    var icon: Data?

    static func address(_ raw: String) -> String? {
        guard !raw.contains("\0") else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, raw, &v4) == 1, IPv4Address(raw)?.debugDescription == raw { return raw }
        if inet_pton(AF_INET6, raw, &v6) == 1 { return IPv6Address(raw)?.debugDescription }
        return nil
    }

    func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.packageName = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, !value.packageName.isEmpty else { throw BastionError("请填写应用名和包名。") }
        guard let address = Self.address(ip.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BastionError("请填写 IPv4 或 IPv6 地址，无需端口。")
        }
        value.ip = address
        return value
    }
}

struct BastionAccount: Codable {
    let userName: String
    let password: String
    let platformURL: String?

    init(userName: String, password: String, platformURL: String) throws {
        self.userName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        guard let parts = URLComponents(string: platformURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.url != nil else {
            throw BastionError("请填写管理平台的 HTTPS 服务地址，例如 https://portal.example。")
        }
        var origin = parts
        origin.path = ""
        self.platformURL = origin.url!.absoluteString
        guard !self.userName.isEmpty, self.userName.count <= 200,
              !self.userName.contains(where: \.isNewline), !self.userName.contains("\0"),
              !password.isEmpty, password.count <= 4096, !password.contains("\0") else {
            throw BastionError("请填写有效的平台账号和密码。")
        }
    }
}

struct BastionStorage {
    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.songran.LogcatMini/Bastion", isDirectory: true)) {
        self.directory = directory
    }
    private var catalog: URL { directory.appendingPathComponent("apps.json") }
    private var credentials: URL { directory.appendingPathComponent("account.sealed") }
    private var keyFile: URL { directory.appendingPathComponent("account.key") }
    private let files = FileManager.default

    func loadApps() throws -> [BastionApp] {
        guard files.fileExists(atPath: catalog.path) else { return [] }
        return try JSONDecoder().decode([BastionApp].self, from: Data(contentsOf: catalog))
    }
    func saveApps(_ apps: [BastionApp]) throws {
        try write(JSONEncoder().encode(apps), to: catalog)
    }
    func loadAccount() throws -> BastionAccount? {
        guard files.fileExists(atPath: credentials.path) else { return nil }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: credentials))
        let data = try AES.GCM.open(box, using: key(create: false))
        return try JSONDecoder().decode(BastionAccount.self, from: data)
    }
    func saveAccount(_ account: BastionAccount) throws {
        let box = try AES.GCM.seal(JSONEncoder().encode(account), using: key(create: true))
        guard let sealed = box.combined else { throw BastionError("无法加密平台账号。") }
        try write(sealed, to: credentials)
    }
    func removeAccount() throws {
        for url in [credentials, keyFile] where files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }
    private func key(create: Bool) throws -> SymmetricKey {
        if create && !files.fileExists(atPath: keyFile.path) {
            let key = SymmetricKey(size: .bits256)
            try write(key.withUnsafeBytes { Data($0) }, to: keyFile, exclusive: true)
        }
        let data = try Data(contentsOf: keyFile)
        guard data.count == 32 else { throw BastionError("本机凭据密钥无效，请移除平台账号后重新保存。") }
        return SymmetricKey(data: data)
    }
    private func write(_ data: Data, to url: URL, exclusive: Bool = false) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: temp) }
        guard files.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BastionError("无法写入本机跳板机配置。")
        }
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if exclusive {
            // Publish a complete key once, even if two processes initialize storage together.
            if link(temp.path, url.path) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else if rename(temp.path, url.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
