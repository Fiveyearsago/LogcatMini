import Foundation

enum BastionPower: String, Decodable {
    case running = "RUNNING", stopped = "STOPPED", starting = "STARTING", stopping = "STOPPING"
    case unknown = "UNKNOWN", error = "ERROR", missing = "NOT_FOUND", deleted = "DELETED"

    var label: String {
        switch self {
        case .running: return "已开机"
        case .stopped: return "已关机"
        case .starting: return "开机中"
        case .stopping: return "关机中"
        case .unknown: return "状态未知"
        case .error: return "主机异常"
        case .missing: return "云端不存在"
        case .deleted: return "已删除"
        }
    }
}

struct BastionHost: Decodable {
    enum ID: Codable {
        case number(Int64), text(String)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Int64.self), number > 0 { self = .number(number); return }
            let text = try value.decode(String.self)
            guard text.range(of: "^[1-9][0-9]{0,19}$", options: .regularExpression) != nil else {
                throw BastionError("平台返回的主机标识无效。")
            }
            self = .text(text)
        }
        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .number(let id): try value.encode(id)
            case .text(let id): try value.encode(id)
            }
        }
    }
    let id: ID
    let version: Int
    let publicIp: String
    let status: String?
    var power: BastionPower { status.flatMap(BastionPower.init) ?? .unknown }
}

enum BastionPortalError: LocalizedError {
    case expired, forbidden, rejectedLogin, rejected, startFailed, unavailable, malformed
    var errorDescription: String? {
        switch self {
        case .expired: return "平台登录已失效，请刷新状态或更新账号。"
        case .forbidden: return "平台账号没有此操作权限。"
        case .rejectedLogin: return "登录未通过，请核对平台账号和密码。"
        case .rejected: return "平台未接受请求，请刷新主机状态。"
        case .startFailed: return "平台报告开机失败，请刷新状态。"
        case .unavailable: return "无法连接跳板机管理平台，请稍后刷新。"
        case .malformed: return "无法识别平台响应，请稍后刷新。"
        }
    }
    var definitelyRejected: Bool {
        switch self {
        case .expired, .forbidden, .rejected, .startFailed: return true
        default: return false
        }
    }
}

private final class BastionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class BastionPortal {
    private struct Envelope<T: Decodable>: Decodable { let data: T }
    private struct ReplyCode: Decodable {
        let code: Int
        private enum CodingKeys: CodingKey { case code }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let n = try? c.decode(Int.self, forKey: .code) { code = n }
            else if let n = Int(try c.decode(String.self, forKey: .code)) { code = n }
            else { throw BastionPortalError.malformed }
        }
    }
    private struct Tokens: Decodable {
        let token: String
        let refreshToken: String?
    }
    private struct Page: Decodable { let list: [BastionHost]; let total: Int }
    private struct StartBody: Encodable { let id: BastionHost.ID; let version: Int }
    private struct StartResult: Decodable { let operationStatus: String? }

    private let account: BastionAccount
    private let session: URLSession
    private var tokens: Tokens?
    private var refreshToken: String?
    private var authentication: Task<Tokens, Error>?
    private var loginFailure: (error: Error, until: Date)?
    private let decoder = JSONDecoder()

    init(_ account: BastionAccount, configuration: URLSessionConfiguration = .ephemeral) {
        self.account = account
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: BastionRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    private func request(_ path: String, query: [URLQueryItem] = [], body: Data? = nil, token: String? = nil) async throws -> Data {
        guard let address = account.platformURL,
              var parts = URLComponents(string: address), parts.scheme == "https", parts.host != nil else {
            throw BastionError("请在「平台账号」中配置管理平台的 HTTPS 服务地址。")
        }
        parts.path = path
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = path.hasSuffix("/start") ? 30 : 12
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue(token, forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw BastionPortalError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw BastionPortalError.unavailable }
        let code = (try? decoder.decode(ReplyCode.self, from: data))?.code
        if http.statusCode == 401 || [401, 8888, 8889, 7777, 7778, 9999, 9998, 3333].contains(code ?? -1) {
            throw BastionPortalError.expired
        }
        if http.statusCode == 403 || code == 403 { throw BastionPortalError.forbidden }
        guard (200..<500).contains(http.statusCode), http.statusCode != 429 else { throw BastionPortalError.unavailable }
        guard (200..<300).contains(http.statusCode), let code else { throw BastionPortalError.malformed }
        guard code == 200 else { throw BastionPortalError.rejected }
        return data
    }

    private func payload<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try decoder.decode(Envelope<T>.self, from: data).data }
        catch { throw BastionPortalError.malformed }
    }
    private func authenticate() async throws -> Tokens {
        if let refreshToken {
            do {
                let data = try await request("/auth/refreshToken", body: JSONEncoder().encode(["refreshToken": refreshToken]), token: tokens?.token)
                return try payload(Tokens.self, data)
            } catch let error as BastionPortalError where [.expired, .forbidden, .rejected].contains(error) {
                self.refreshToken = nil
            }
        }
        do {
            return try payload(Tokens.self, await request("/auth/login", body: JSONEncoder().encode(["userName": account.userName, "password": account.password])))
        } catch let error as BastionPortalError where [.expired, .forbidden, .rejected].contains(error) {
            throw BastionPortalError.rejectedLogin
        }
    }

    private func accessToken(expired: String? = nil) async throws -> String {
        if let task = authentication { return try await task.value.token }
        if let tokens, expired != tokens.token { return tokens.token }
        if let failure = loginFailure, failure.until > Date() { throw failure.error }
        let task = Task {
            let result = try await authenticate()
            guard !result.token.isEmpty, result.token.utf8.count <= 16384,
                  !result.token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw BastionPortalError.malformed
            }
            return result
        }
        authentication = task
        defer { authentication = nil }
        do {
            let result = try await task.value
            tokens = result; refreshToken = result.refreshToken; loginFailure = nil
            return result.token
        } catch {
            tokens = nil
            let rejected = error as? BastionPortalError == .rejectedLogin
            loginFailure = (error, rejected ? .distantFuture : Date().addingTimeInterval(30))
            throw error
        }
    }

    func verify() async throws { _ = try await accessToken() }

    func host(_ ip: String) async throws -> BastionHost {
        let query = [URLQueryItem(name: "pageNum", value: "1"), URLQueryItem(name: "pageSize", value: "100"),
                     URLQueryItem(name: "publicIp", value: ip)]
        let token = try await accessToken()
        let data: Data
        do { data = try await request("/system/bastion-host/list", query: query, token: token) }
        catch BastionPortalError.expired {
            data = try await request("/system/bastion-host/list", query: query, token: accessToken(expired: token))
        }
        let page = try payload(Page.self, data)
        guard page.total == page.list.count else { throw BastionError("平台查询结果不完整，请在平台核对此 IP。") }
        let matches = page.list.filter { BastionApp.address($0.publicIp) == ip }
        guard let match = matches.first else { throw BastionError("平台中未找到此 IP。") }
        guard matches.count == 1 else { throw BastionError("此 IP 对应多条主机记录，请在平台核对。") }
        guard match.version >= 0 else { throw BastionPortalError.malformed }
        return match
    }

    func start(_ host: BastionHost) async throws {
        guard host.power == .stopped, let token = tokens?.token else { throw BastionPortalError.expired }
        let data = try await request("/system/bastion-host/start", body: JSONEncoder().encode(StartBody(id: host.id, version: host.version)), token: token)
        let result = try payload(StartResult.self, data)
        switch result.operationStatus {
        case "SUCCESS": return
        case "FAILED", "FAILURE", "ERROR": throw BastionPortalError.startFailed
        default: throw BastionPortalError.malformed
        }
    }
}
