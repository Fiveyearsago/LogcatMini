import AppKit
import Combine
import Security
import LogcatCore

/// A session-only scratchpad, independent of request replay and its saved history.
@MainActor final class LogSDecryptionStore: ObservableObject {
    @Published var serviceEndpoint = ""
    @Published var input = "" { didSet { if input != oldValue { plain = ""; error = nil; notice = nil } } }
    @Published var mode = "old"
    @Published private(set) var candidates: [String] = []
    @Published private(set) var source = ""
    @Published private(set) var plain = ""
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var privateKeyName: String?
    private var privateKey: SecKey?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func importLog(_ entry: LogEntry) {
        cancel()
        source = "\(entry.tag) · \(entry.time)" + (entry.mergedParts > 1 ? " · 已合并 \(entry.mergedParts) 段" : "")
        input = entry.displayMessage
        extract()
    }
    func extract() {
        guard !busy else { return }
        candidates = LogSExtractor.values(in: input)
        plain = ""; error = nil; notice = nil
        if candidates.count == 1 { input = candidates[0] }
        else if candidates.count > 1 { notice = "找到 \(candidates.count) 个不同的 s，请选择要解密的一项。" }
        else { error = "未找到完整的 s 字段。可以直接粘贴完整 s 串，或等待分段日志合并后再导入。" }
    }
    func selectCandidate(_ index: Int) {
        guard !busy, candidates.indices.contains(index) else { return }
        input = candidates[index]
    }
    private func value() throws -> String {
        guard input.utf8.count <= 4 * 1_024 * 1_024 else { throw ReplayError("s 超过 4 MiB。") }
        let values = LogSExtractor.values(in: input)
        guard values.count < 2 else { candidates = values; throw ReplayError("日志包含多个 s，请先选择要解密的一项。") }
        let value = (values.first ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = value.removingPercentEncoding ?? value
        let compact = decoded.filter { !$0.isWhitespace }
        guard !compact.isEmpty, Data(base64Encoded: compact) != nil else { throw ReplayError("请提供完整的 Base64 s 串；日志中的其他内容不会发送到解密服务。") }
        return compact
    }
    func decryptUsingService(endpoint: String? = nil) {
        guard !busy else { return }
        let endpoint = endpoint ?? serviceEndpoint
        do {
            let value = try value(), original = input, selectedMode = mode, token = UUID()
            generation = token; busy = true; plain = ""; error = nil; notice = nil
            task = Task {
                defer { if generation == token { busy = false; task = nil } }
                do {
                    let result = try await RemoteSDecryptor.decrypt(value, mode: selectedMode, endpoint: endpoint)
                    try Task.checkCancellation()
                    guard generation == token, input == original, mode == selectedMode else { return }
                    plain = result; notice = "解密成功（\(selectedMode)）"
                } catch {
                    guard generation == token else { return }
                    self.error = Task.isCancelled ? "解密已取消。" : error.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func decryptLocally() {
        guard !busy else { return }
        plain = ""; notice = nil
        do { plain = try SPacketCodec.decrypt(value(), privateKey: privateKey); error = nil; notice = "本机解密成功" }
        catch { self.error = error.localizedDescription }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
    func clear() { cancel(); input = ""; candidates = []; source = ""; plain = ""; error = nil; notice = nil }
    func importPrivateKey() {
        let panel = NSOpenPanel(); panel.title = "选择对应的 RSA 私钥（PEM）"; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 64 * 1_024 else { throw ReplayError("私钥文件过大。") }
            privateKey = try SPacketCodec.importPrivateKey(String(contentsOf: url, encoding: .utf8))
            privateKeyName = url.lastPathComponent; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func forgetPrivateKey() { privateKey = nil; privateKeyName = nil }
}
