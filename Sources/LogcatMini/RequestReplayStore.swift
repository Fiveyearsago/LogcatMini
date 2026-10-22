import Foundation
import Combine
import AppKit
import Security
import LogcatCore

@MainActor final class RequestReplayStore: ObservableObject {
    private struct Catalog: Codable {
        var version = 1
        var requests: [ReplayRequest] = []
        var records: [ReplayRecord] = []
    }
    @Published var serviceEndpoint = ""
    @Published var draft = ReplayRequest()
    @Published private(set) var requests: [ReplayRequest] = []
    @Published private(set) var records: [ReplayRecord] = []
    @Published private(set) var sending = false
    @Published private(set) var decrypting = false
    @Published var decryptionMode = "old"
    @Published var error: String?
    @Published var notice: String?
    @Published var response: ReplayResponse?
    @Published var responseFullscreen = false
    @Published var plain = ""
    @Published var sLocation = ReplaySLocation.jsonBody
    @Published private(set) var privateKeyName: String?
    private var privateKey: SecKey?
    @Published private(set) var publicKeyName: String?
    private var publicKey: SecKey?
    private var appliedPlain = ""
    private var activeTask: Task<Void, Never>?
    private var decryptTask: Task<Void, Never>?
    private var readFailure = false
    let catalogURL: URL
    var hasUnappliedPlain: Bool { plain != appliedPlain }
    var busy: Bool { sending || decrypting }
    var canSend: Bool {
        !busy && !draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (usesURLS || !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var usesURLS: Bool { ["GET", "HEAD"].contains(draft.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) }
    var effectiveSLocation: ReplaySLocation { usesURLS ? .query : sLocation }

    init(catalogURL: URL? = nil) {
        self.catalogURL = catalogURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.songran.LogcatMini", isDirectory: true)
            .appendingPathComponent("request-replay/history.json")
        do {
            if FileManager.default.fileExists(atPath: self.catalogURL.path) {
                let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: self.catalogURL))
                guard catalog.version == 1 else { throw ReplayError("请求记录来自不支持的版本。") }
                requests = catalog.requests; records = catalog.records
                for index in records.indices where records[index].response == nil {
                    records[index].response = ReplayResponse(error: "上次运行中断，未取得响应；服务端可能已收到请求。")
                }
            }
        } catch { self.error = "读取请求记录失败，原文件已保留：\(error.localizedDescription)"; readFailure = true }
    }
    func load(_ request: ReplayRequest, historicalSnapshot: Bool = false) {
        guard !busy else { error = "请先等待当前请求或解密完成，或取消操作。"; return }
        guard !hasUnappliedPlain else { error = "明文尚未写回，请先写回请求或清空明文，再切换请求。"; return }
        // Keep edits when navigating between logs, saved requests and historical snapshots.
        var target = request
        if (!draft.url.isEmpty || !draft.body.isEmpty || !draft.headers.isEmpty), requests.first(where: { $0.id == draft.id }) != draft {
            guard save() else { return }
            if target.id == draft.id && !historicalSnapshot { target = draft }
        }
        draft = target; response = nil; responseFullscreen = false; plain = ""; appliedPlain = ""; notice = nil
        if !readFailure { error = nil }
        sLocation = usesURLS ? .query : ReplaySLocation.allCases.first { (try? $0.read(from: target)) != nil } ?? .jsonBody
    }
    func importLog(_ entry: LogEntry, context: [LogEntry]) { load(RequestLogImporter.extract(selected: entry, context: context)) }
    func newRequest() { load(ReplayRequest()) }
    func duplicate() { var copy = draft; copy.id = UUID(); copy.name += " 副本"; load(copy) }
    @discardableResult func save() -> Bool {
        do {
            var saved = draft
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if saved.name.isEmpty { saved.name = saved.method + " " + saved.url }
            guard saved.body.utf8.count <= 4 * 1_024 * 1_024, saved.headers.utf8.count <= 256 * 1_024 else { throw ReplayError("请求内容过大。") }
            saved.updatedAt = Date()
            var updated = requests.filter { $0.id != saved.id }; updated.insert(saved, at: 0)
            try persist(requests: updated, records: records)
            draft = saved; requests = updated; notice = "已保存「\(saved.name)」"; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func deleteRequest(_ id: UUID) {
        do {
            let updated = requests.filter { $0.id != id }
            try persist(requests: updated, records: records); requests = updated
        } catch { self.error = error.localizedDescription }
    }
    func deleteRecord(_ id: UUID) {
        guard !sending else { return }
        do {
            let updated = records.filter { $0.id != id }
            try persist(requests: requests, records: updated); records = updated
        } catch { self.error = error.localizedDescription }
    }
    func restore(_ record: ReplayRecord) {
        guard !busy, !hasUnappliedPlain else { error = "请先结束当前发送或解密，并写回或清空明文。"; return }
        load(record.request, historicalSnapshot: true)
        if draft == record.request { response = record.response }
    }

    func send() {
        guard canSend else { return }
        do {
            let prepared = try draft.prepared()
            guard save() else { return }
            // Store the actual explicit wire fields, after filtering managed transport headers.
            var snapshot = draft
            snapshot.method = prepared.httpMethod ?? draft.method; snapshot.url = prepared.url?.absoluteString ?? draft.url
            snapshot.body = prepared.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            snapshot.headers = (prepared.allHTTPHeaderFields ?? [:]).keys.sorted().map { "\($0): \(prepared.allHTTPHeaderFields![$0]!)" }.joined(separator: "\n")
            let record = ReplayRecord(request: snapshot)
            let updated = Array(([record] + records).prefix(200))
            try persist(requests: requests, records: updated)
            records = updated; sending = true; error = nil; notice = nil; response = nil
            activeTask = Task {
                let result = await ReplayHTTPClient().send(prepared)
                self.response = result
                if let index = self.records.firstIndex(where: { $0.id == record.id }) { self.records[index].response = result }
                do { try self.persist(requests: self.requests, records: self.records) }
                catch { self.error = "请求已执行，但结果保存失败：\(error.localizedDescription)" }
                self.sending = false; self.activeTask = nil
            }
        } catch { self.error = error.localizedDescription }
    }
    func cancel() { activeTask?.cancel() }
    func decryptUsingService(endpoint: String? = nil) {
        guard !busy else { return }
        let endpoint = endpoint ?? serviceEndpoint
        do {
            let s = try readSForDecryption()
            let id = draft.id, location = sLocation, mode = decryptionMode
            decrypting = true; error = nil; notice = nil
            decryptTask = Task {
                defer { self.decrypting = false; self.decryptTask = nil }
                do {
                    let value = try await RemoteSDecryptor.decrypt(s, mode: mode, endpoint: endpoint)
                    try Task.checkCancellation()
                    guard self.draft.id == id, (try? location.read(from: self.draft)) == s else { throw ReplayError("请求已变化，请重新解密。") }
                    self.plain = value; self.appliedPlain = value
                    self.notice = "服务解密成功（\(mode)）；修改后选择加密或明文写回。"
                } catch { self.error = Task.isCancelled ? "服务解密已取消。" : error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func cancelDecryption() { decryptTask?.cancel() }
    private func readSForDecryption() throws -> String {
        // Resolve at click time: the user may have just pasted a new GET URL.
        sLocation = effectiveSLocation
        return try sLocation.read(from: draft)
    }
    func decryptS() {
        guard !busy else { return }
        do {
            plain = try SPacketCodec.decrypt(readSForDecryption(), privateKey: privateKey)
            appliedPlain = plain; notice = "已解密，可编辑明文；修改后请写回请求。"; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func applyPlain(encrypt: Bool, wholeBody: Bool = false) {
        do {
            guard !plain.isEmpty else { throw ReplayError("请先解密或填写明文。") }
            if wholeBody {
                guard !usesURLS else { throw ReplayError("GET / HEAD 的 s 请写回 URL 查询参数。") }
                guard (try? JSONSerialization.jsonObject(with: Data(plain.utf8))) != nil else { throw ReplayError("明文 Body 必须为有效 JSON。") }
                let headers = try ReplayRequest.parseHeaders(draft.headers).filter { $0.0.lowercased() != "content-type" }
                draft.body = plain
                draft.headers = (headers.map { "\($0.0): \($0.1)" } + ["Content-Type: application/json; charset=utf-8"]).joined(separator: "\n")
            } else {
                let value = try encrypt ? SPacketCodec.encrypt(plain, publicKey: publicKey) : plain
                try effectiveSLocation.write(value, to: &draft)
            }
            appliedPlain = plain; error = nil; notice = encrypt ? "已重新加密并写回 s；Body / URL 即实际发送内容。" : "明文已写回请求，请核对 Body / URL。"
        } catch { self.error = error.localizedDescription }
    }
    func discardPlain() { plain = ""; appliedPlain = "" }
    func importPrivateKey() {
        let panel = NSOpenPanel(); panel.title = "选择对应的 RSA 私钥（PEM）"; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64 * 1_024 else { throw ReplayError("私钥文件过大。") }
            privateKey = try SPacketCodec.importPrivateKey(String(contentsOf: url, encoding: .utf8))
            privateKeyName = url.lastPathComponent; error = nil; notice = "私钥仅在本次运行中使用。"
        } catch { self.error = error.localizedDescription }
    }
    func importPublicKey() {
        let panel = NSOpenPanel(); panel.title = "选择对应的 RSA 公钥（PEM）"; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 64 * 1_024 else { throw ReplayError("公钥文件过大。") }
            try loadPublicKey(String(contentsOf: url, encoding: .utf8), name: url.lastPathComponent)
        } catch { self.error = error.localizedDescription }
    }
    func loadPublicKey(_ pem: String, name: String) throws {
        publicKey = try SPacketCodec.importPublicKey(pem)
        publicKeyName = name; error = nil; notice = "公钥仅在本次运行中使用。"
    }
    func forgetPublicKey() { publicKey = nil; publicKeyName = nil }
    func forgetPrivateKey() { privateKey = nil; privateKeyName = nil }
    private func persist(requests: [ReplayRequest], records: [ReplayRecord]) throws {
        guard !readFailure else { throw ReplayError("历史文件读取失败，为避免覆盖原记录，本次不写入。请先在 Finder 中备份并移走损坏的 history.json，然后重启。") }
        let folder = catalogURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Catalog(requests: requests, records: records))
        // .atomic preserves the previous catalog on failed writes; file permissions stay local-only.
        try data.write(to: catalogURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalogURL.path)
    }
}
