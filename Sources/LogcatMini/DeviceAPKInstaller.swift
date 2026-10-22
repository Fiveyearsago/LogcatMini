import Foundation
import Combine
import LogcatCore

struct APKInstallTarget: Equatable {
    let path: String
    let serial: String
    let name: String
    var label: String { name + " · " + serial }
}

@MainActor final class DeviceAPKInstaller: ObservableObject {
    typealias Runner = (String, [String], TimeInterval) async throws -> String
    @Published private(set) var isInstalling = false
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    var onInstalled: ((String) -> Void)?
    var installationAllowed: () -> Bool = { true }
    private let run: Runner
    private var task: Task<Void, Never>?

    init(run: @escaping Runner = { try await ADB.run(path: $0, arguments: $1, timeout: $2) }) { self.run = run }

    nonisolated static func accepts(_ urls: [URL]) -> Bool {
        urls.count == 1 && urls[0].isFileURL && urls[0].pathExtension.lowercased() == "apk"
    }

    @discardableResult func install(_ url: URL, on target: APKInstallTarget) -> Bool {
        guard !isInstalling else { return false }
        guard installationAllowed() else { reportFailure("本地项目正在编译运行，请等待结束后再安装其他 APK。"); return false }
        guard Self.accepts([url]), !target.serial.isEmpty else {
            reportFailure("请将一个 APK 文件拖到已连接的手机画面上。"); return false
        }
        let access = url.startAccessingSecurityScopedResource()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0,
              FileManager.default.isReadableFile(atPath: url.path) else {
            if access { url.stopAccessingSecurityScopedResource() }
            reportFailure("无法读取 APK 文件，请检查文件是否完整及访问权限。"); return false
        }
        isInstalling = true; failed = false
        message = "正在安装 \(url.lastPathComponent)\n目标：\(target.label)"
        // Capture the drop target. Switching the selected phone must never redirect an installation.
        task = Task {
            defer { isInstalling = false; if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let output = try await run(target.path, ["-s", target.serial, "install", "-r", url.path], 180)
                guard output.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Success" }) else {
                    throw ADBError.failed(output.isEmpty ? "手机未返回安装成功结果。" : output)
                }
                message = "已安装 \(url.lastPathComponent)\n目标：\(target.label)"
                onInstalled?(target.serial)
            } catch {
                failed = true
                message = "安装失败：\(url.lastPathComponent)\n目标：\(target.label)\n" + String(error.localizedDescription.prefix(1500))
            }
        }
        return true
    }

    func reportFailure(_ text: String) { guard !isInstalling else { return }; failed = true; message = text }
    func dismiss() { guard !isInstalling else { return }; message = nil; failed = false }
    func waitUntilFinished() async { await task?.value }
}
