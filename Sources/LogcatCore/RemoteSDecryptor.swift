import Foundation

public enum RemoteSDecryptor {
    public static let endpoint = ""
    public static func decrypt(_ s: String, mode: String = "old", endpoint: String = endpoint) async throws -> String {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReplayError("请先填写你有权使用的解密服务地址。") }
        guard ["old", "new"].contains(mode), !s.isEmpty, s.utf8.count <= 4 * 1_024 * 1_024 else { throw ReplayError("s 为空、过长或解密模式无效。") }
        var request = ReplayRequest()
        request.url = endpoint; request.method = "POST"; request.timeout = 20
        request.headers = "Content-Type: application/json;charset=UTF-8"
        request.body = String(decoding: try JSONSerialization.data(withJSONObject: ["is_new": mode, "encrpt_params": s]), as: UTF8.self)
        let response = await ReplayHTTPClient().send(try request.prepared())
        if let error = response.error { throw ReplayError("解密服务连接失败：\(error)") }
        guard response.status == 200, !response.truncated else { throw ReplayError("解密服务返回 HTTP \(response.status ?? 0)，或结果超过 2 MiB。") }
        return try parseResponse(response.body)
    }
    public static func parseResponse(_ body: String) throws -> String {
        guard let envelope = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let code = envelope["result_code"] as? Int, code == 200,
              let data = envelope["data"], !(data is NSNull) else { throw ReplayError("解密服务未返回成功结果，请核对 s 和 old / new 模式。") }
        // This service also reports a wrong key/mode inside data despite result_code=200.
        let message = (data as? [String: Any])?["message"] as? String ?? (data as? String ?? "")
        guard !message.lowercased().contains("no decrpt message,please check your encrpt params") else {
            throw ReplayError("服务无法解密此 s，请核对 old / new 模式；请确认服务支持所选模式。")
        }
        if let text = data as? String { return text }
        guard JSONSerialization.isValidJSONObject(data) else { throw ReplayError("解密服务返回的明文格式不受支持。") }
        return String(decoding: try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
