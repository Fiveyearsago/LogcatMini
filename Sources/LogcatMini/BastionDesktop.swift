import AppKit
import ApplicationServices
import WindowsAppCards

enum BastionDesktop {
    struct Bookmark {
        let name: String
        let id: UUID
        static func parse(_ line: Substring) throws -> Self {
            guard line.first == "\"", let comma = line.lastIndex(of: ","),
                  let id = UUID(uuidString: line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)),
                  line[..<comma].last == "\"" else {
                throw BastionError("无法识别 Windows App 的连接列表。")
            }
            let name = line[..<comma].dropFirst().dropLast().replacingOccurrences(of: "\"\"", with: "\"")
            return Self(name: name, id: id)
        }
    }

    static func exportedAddress(_ settings: String) -> String? {
        let prefix = "full address:s:"
        guard let line = settings.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let host = String(line.dropFirst(prefix.count))
        if let ip = BastionApp.address(host) { return ip }
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            let suffix = host[host.index(after: end)...]
            guard suffix.isEmpty || suffix == ":3389" else { return nil }
            return BastionApp.address(String(host[host.index(after: host.startIndex)..<end]))
        }
        if host.hasSuffix(":3389") { return BastionApp.address(String(host.dropLast(5))) }
        return nil
    }

    private static func command(_ executable: URL, _ arguments: [String]) async throws -> String {
        let result = try await BuildProcessRunner().run(.init(executable: executable.path,
            arguments: ["--script", "bookmark"] + arguments, timeout: 10)) { _ in }
        guard result.status == 0 else { throw BastionError("无法读取 Windows App 的已保存连接。") }
        return result.output
    }

    static func savedCard(for ip: String, list: String, export: (UUID) async throws -> String) async throws -> String {
        guard BastionApp.address(ip) == ip else { throw BastionError("跳板机 IP 无效。") }
        let bookmarks = try list.split(whereSeparator: \.isNewline).map(Bookmark.parse)
        var match: Bookmark?
        for bookmark in bookmarks {
            guard exportedAddress(try await export(bookmark.id)) == ip else { continue }
            guard match == nil else { throw BastionError("Windows App 中有多个同地址的连接，请在客户端选择。") }
            match = bookmark
        }
        guard let match else { throw BastionError("Windows App 中没有此 IP 的已保存设备。请先在 Windows App 添加这台电脑。") }
        guard !match.name.isEmpty, bookmarks.filter({ $0.name == match.name }).count == 1 else {
            throw BastionError("Windows App 中的连接名称为空或重名，请为此 IP 的卡片设置唯一名称。")
        }
        return match.name
    }

    @MainActor static func open(_ ip: String) async throws {
        guard BastionApp.address(ip) == ip else { throw BastionError("跳板机 IP 无效。") }
        guard let client = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.rdc.macos"),
              let executable = Bundle(url: client)?.executableURL else { throw BastionError("请先安装 Microsoft Windows App。") }
        let list = try await command(executable, ["list"])
        let name = try await savedCard(for: ip, list: list) {
            try await command(executable, ["export", $0.uuidString])
        }
        if AXIsProcessTrusted() {
            try await WindowsAppCard.open(name)
            return
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Logcat Mini 跳板机连接.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [name]
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        let running = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
        // Keep the row busy while the user is granting access or the card is being opened.
        while !running.isTerminated { try await Task.sleep(nanoseconds: 250_000_000) }
    }
}
