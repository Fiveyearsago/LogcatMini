import Foundation

public struct ReplayError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ReplayRequest: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name = "未命名请求"
    public var method = "GET"
    public var url = ""
    public var headers = ""
    public var body = ""
    public var timeout: Double = 30
    public var source = ""
    public var importNotes = ""
    public var updatedAt = Date()
    public init() {}

    public func prepared() throws -> URLRequest {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.fragment == nil, let target = components.url else {
            throw ReplayError("请输入完整的 http / https 地址，不支持 URL 内的用户名、密码或 #fragment。")
        }
        let verb = method.uppercased().trimmingCharacters(in: .whitespaces)
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(verb) else {
            throw ReplayError("不支持的 HTTP 方法。")
        }
        guard timeout.isFinite, (1...120).contains(timeout) else { throw ReplayError("超时应为 1–120 秒。") }
        let sendsBody = !["GET", "HEAD"].contains(verb)
        guard !sendsBody || body.utf8.count <= 4 * 1_024 * 1_024 else { throw ReplayError("请求体超过 4 MiB。") }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = verb
        for (key, value) in try Self.parseHeaders(headers) { request.setValue(value, forHTTPHeaderField: key) }
        // Send the explicit wire body verbatim; s decryption and JSON validation are optional editing tools.
        if sendsBody, !body.isEmpty { request.httpBody = Data(body.utf8) }
        return request
    }

    public static func parseHeaders(_ text: String) throws -> [(String, String)] {
        var result: [(String, String)] = [], names = Set<String>()
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw ReplayError("请求头格式应为 Header: value。") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }) else {
                throw ReplayError("请求头含无效字符。")
            }
            let lower = name.lowercased()
            // The transport must recalculate these after editing URL/body.
            if ["host", "content-length", "connection", "transfer-encoding", "accept-encoding"].contains(lower) { continue }
            guard names.insert(lower).inserted else { throw ReplayError("请求头重复：\(name)。请合并为一行。") }
            result.append((name, value))
        }
        return result
    }
}

public enum ReplaySLocation: String, CaseIterable, Identifiable {
    case jsonBody, formBody, query
    public var id: String { rawValue }
    public var title: String {
        switch self { case .jsonBody: return "JSON Body 的 s"; case .formBody: return "表单 Body 的 s"; case .query: return "URL 查询参数 s" }
    }
    public func read(from request: ReplayRequest) throws -> String {
        switch self {
        case .jsonBody:
            guard let object = try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any], let s = object["s"] as? String else {
                throw ReplayError("JSON Body 中没有字符串类型的 s 字段。")
            }
            return s
        case .formBody, .query:
            let pairs = try fields(request)
            let matches = pairs.filter { decode($0.0) == "s" }
            guard matches.count == 1 else { throw ReplayError("需要且只能有一个 s 参数。") }
            return decode(matches[0].1 ?? "")
        }
    }
    public func write(_ value: String, to request: inout ReplayRequest) throws {
        switch self {
        case .jsonBody:
            guard var object = try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any] else { throw ReplayError("请先填写 JSON 对象 Body，例如 {\"s\":\"\"}。") }
            object["s"] = value
            request.body = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        case .formBody, .query:
            var pairs = try fields(request)
            guard pairs.filter({ decode($0.0) == "s" }).count <= 1 else { throw ReplayError("存在多个 s 参数，请先保留一个。") }
            let escaped = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
            if let index = pairs.firstIndex(where: { decode($0.0) == "s" }) { pairs[index].1 = escaped }
            else { pairs.append(("s", escaped)) }
            let encoded = pairs.map { pair in pair.0 + (pair.1.map { "=" + $0 } ?? "") }.joined(separator: "&")
            if self == .formBody { request.body = encoded }
            else {
                guard var url = URLComponents(string: request.url) else { throw ReplayError("URL 无效。") }
                url.percentEncodedQuery = encoded; request.url = url.string ?? request.url
            }
        }
    }
    private func fields(_ request: ReplayRequest) throws -> [(String, String?)] {
        let text: String
        if self == .formBody { text = request.body }
        else {
            guard let url = URLComponents(string: request.url) else { throw ReplayError("URL 无效。") }
            text = url.percentEncodedQuery ?? ""
        }
        guard !text.isEmpty else { return [] }
        // Keep untouched fields byte-for-byte, including bare flags and empty query segments.
        return text.components(separatedBy: "&").map {
            let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pair[0]), pair.count > 1 ? String(pair[1]) : nil)
        }
    }
    private func decode(_ value: String) -> String {
        // A literal Base64 '+' in a URL query is not a form-encoded space.
        let encoded = self == .formBody ? value.replacingOccurrences(of: "+", with: " ") : value
        return encoded.removingPercentEncoding ?? encoded
    }
}

public struct ReplayResponse: Codable, Equatable {
    public var status: Int?
    public var headers: String
    public var body: String
    public var elapsed: Double
    public var error: String?
    public var truncated: Bool
    public init(status: Int? = nil, headers: String = "", body: String = "", elapsed: Double = 0, error: String? = nil, truncated: Bool = false) {
        self.status = status; self.headers = headers; self.body = body; self.elapsed = elapsed; self.error = error; self.truncated = truncated
    }
}

public struct ReplayRecord: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var request: ReplayRequest
    public var response: ReplayResponse?
    public init(request: ReplayRequest) { self.request = request }
}

/// A dedicated ephemeral session avoids leaking browser cookies and shows redirects as responses.
public final class ReplayHTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let responseLimit = 2 * 1_024 * 1_024
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    public func send(_ request: URLRequest) async -> ReplayResponse {
        let started = Date()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil; config.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var result = ReplayResponse()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            guard let http = response as? HTTPURLResponse else { throw ReplayError("未收到 HTTP 响应。") }
            result.status = http.statusCode
            result.headers = http.allHeaderFields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                if data.count == Self.responseLimit { result.truncated = true; break }
                data.append(byte)
            }
            result.body = String(data: data, encoding: .utf8) ?? "[二进制响应，Base64]\n" + data.base64EncodedString()
        } catch { result.error = Task.isCancelled ? "请求已取消；服务端可能已经收到请求。" : error.localizedDescription }
        result.elapsed = Date().timeIntervalSince(started)
        return result
    }
}
