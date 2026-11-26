import XCTest
@testable import LogcatMini

private final class BastionProtocol: URLProtocol {
    struct Call {
        let path: String
        let query: [URLQueryItem]
        let method: String
        let token: String?
        let body: [String: Any]
    }
    struct Reply {
        var status: Int = 200
        var code: Int = 200
        var data: Any
        static var login: Self { Reply(data: ["token": "access", "refreshToken": "refresh"]) }
        static func host(_ power: String, ip: String = "192.0.2.8", version: Int = 1) -> Self {
            let row: [String: Any] = ["publicIp": ip, "status": power, "version": version, "id": "20000000000000000001"]
            return Reply(data: ["list": [row], "total": 1])
        }
    }
    static let lock = NSLock()
    private static var calls: [Call] = []
    private static var replies: [Reply] = []
    static func prepare(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        self.calls = []; self.replies = replies
    }
    static var history: [Call] {
        lock.lock(); defer { lock.unlock() }; return calls
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = stream.read(&buffer, maxLength: buffer.count)
                guard n > 0 else { break }
                body.append(contentsOf: buffer.prefix(n))
            }
        }
        let url = request.url!
        let call = Call(path: url.path, query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [],
                        method: request.httpMethod ?? "", token: request.value(forHTTPHeaderField: "Authorization"),
                        body: (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        Self.lock.lock()
        Self.calls.append(call)
        let reply = Self.replies.isEmpty ? Reply(status: 503, data: NSNull()) : Self.replies.removeFirst()
        Self.lock.unlock()
        let http = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["code": reply.code, "data": reply.data]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class BastionTests: XCTestCase {
    private let app = BastionApp(name: "Demo", packageName: "app.example", ip: "192.0.2.8")
    private var storage: BastionStorage!
    override func setUp() {
        storage = BastionStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent("bastion-test-" + UUID().uuidString))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: storage.directory) }
    @MainActor private func portal(_ account: BastionAccount) -> BastionPortal {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BastionProtocol.self]
        return BastionPortal(account, configuration: configuration)
    }
    @MainActor private func manager(open: @escaping (String) async throws -> Void = { _ in XCTFail("unexpected connection") }) -> BastionManager {
        BastionManager(storage: storage, makePortal: portal, openDesktop: open)
    }

    func testPortalAddressRequiresAnExplicitHTTPSOriginAndLoadsLegacyAccounts() throws {
        for address in ["", "http://portal.example", "https://qa:secret@portal.example", "https://portal.example/path",
                        "https://portal.example?query", "https://portal.example#fragment"] {
            XCTAssertThrowsError(try BastionAccount(userName: "qa", password: "test", platformURL: address))
        }
        let account = try BastionAccount(userName: "qa", password: "test", platformURL: " https://portal.example:8443/ ")
        XCTAssertEqual(account.platformURL, "https://portal.example:8443")
        let legacy = try JSONDecoder().decode(BastionAccount.self, from: Data(#"{"userName":"qa","password":"test"}"#.utf8))
        XCTAssertNil(legacy.platformURL)
        XCTAssertEqual(legacy.userName, "qa")
    }

    @MainActor func testAppCatalogAndEncryptedAccountRoundTrip() async throws {
        let manager = manager()
        var draft = app
        draft.name = "  Example  "; draft.icon = Data([0, 1, 2])
        try manager.saveApp(draft)
        draft.packageName = "app.renamed"; try manager.saveApp(draft)
        XCTAssertEqual(manager.apps.count, 1); XCTAssertEqual(manager.apps.first?.name, "Example")
        XCTAssertEqual(try storage.loadApps(), manager.apps)
        XCTAssertNil(manager.userName)
        for invalid in ["example.org", "192.0.2.8:3389", "10", "127.0.0.1\0oops", "01.2.3.4"] {
            draft.ip = invalid; XCTAssertThrowsError(try manager.saveApp(draft), invalid)
        }
        draft.ip = "2001:0db8::1"; XCTAssertEqual(try draft.validated().ip, "2001:db8::1")
        BastionProtocol.prepare([.login, .init(status: 401, data: NSNull())])
        try await manager.saveAccount(userName: " test-user ", password: " testcase secret ", platformURL: "https://portal.example")
        XCTAssertEqual(manager.userName, "test-user")
        do { try await manager.saveAccount(userName: "failed-replacement", password: "wrong", platformURL: "https://portal.example"); XCTFail() } catch {}
        XCTAssertEqual(try storage.loadAccount()?.password, " testcase secret ")
        XCTAssertEqual(try storage.loadAccount()?.userName, "test-user")
        for file in try FileManager.default.contentsOfDirectory(at: storage.directory, includingPropertiesForKeys: nil) {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data("testcase secret".utf8))); XCTAssertNil(bytes.range(of: Data("test-user".utf8)))
        }
        let restarted = self.manager()
        XCTAssertEqual(restarted.apps, manager.apps); XCTAssertEqual(restarted.userName, manager.userName)
        try restarted.removeAccount()
        XCTAssertNil(try storage.loadAccount()); XCTAssertEqual(try storage.loadApps().count, 1)
        try restarted.removeApp(app); XCTAssertTrue(try storage.loadApps().isEmpty)
    }

    @MainActor func testSharedIPStartRechecksVersionAndOpensOnlyAfterFreshRunningResponse() async throws {
        var opened: [String] = []
        let manager = manager { opened.append($0) }
        try manager.saveApp(app)
        try manager.saveApp(BastionApp(name: "Second", packageName: "app.second", ip: app.ip))
        BastionProtocol.prepare([.login, .host("STOPPED"), .host("STOPPED", version: 7),
                                 .init(data: ["operationStatus": "SUCCESS"]), .host("STOPPED"), .host("RUNNING"),
                                 .host("RUNNING"), .host("STOPPING")])
        try await manager.saveAccount(userName: "qa", password: "test", platformURL: "https://portal.example")
        await manager.refreshAll()
        XCTAssertEqual(BastionProtocol.history.count, 2)
        let lookup = try XCTUnwrap(BastionProtocol.history.last)
        XCTAssertEqual(lookup.query.first(where: { $0.name == "publicIp" })?.value, app.ip)
        XCTAssertEqual(lookup.token, "access"); XCTAssertEqual(lookup.method, "GET")
        XCTAssertEqual(manager.statuses[app.ip], .power(.stopped))
        async let start: Void = manager.perform(.start, for: app)
        async let sameHost: Void = manager.perform(.start, for: manager.apps[1])
        _ = await (start, sameHost)
        let writes = BastionProtocol.history.filter { $0.path.hasSuffix("/start") }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?.method, "POST")
        XCTAssertEqual(writes.first?.body["version"] as? Int, 7); XCTAssertEqual(writes.first?.body["id"] as? String, "20000000000000000001")
        XCTAssertEqual(manager.statuses[app.ip], .power(.starting))
        await manager.refreshAll()
        await manager.perform(.connect, for: app)
        await manager.perform(.connect, for: app)
        XCTAssertEqual(opened, [app.ip]); XCTAssertEqual(manager.statuses[app.ip], .power(.stopping))
    }

    @MainActor func testAmbiguousPaginatedAndPartialMatchesCannotOperate() async throws {
        let manager = manager()
        try manager.saveApp(app)
        let row: [String: Any] = ["publicIp": app.ip, "status": "STOPPED", "id": 1, "version": 4]
        BastionProtocol.prepare([.login, .host("STOPPED"), .init(data: ["list": [row, row], "total": 2]),
                                 .init(data: ["list": [row], "total": 13]), .host("STOPPED", ip: "192.0.2.80")])
        try await manager.saveAccount(userName: "qa", password: "test", platformURL: "https://portal.example")
        await manager.refreshAll()
        await manager.perform(.start, for: app)
        for attempt in 0..<3 {
            if attempt > 0 { await manager.refreshAll() }
            guard case .failed = manager.statuses[app.ip] else { return XCTFail() }
            await manager.perform(.start, for: app)
        }
        XCTAssertEqual(BastionProtocol.history.count, 5)
        XCTAssertFalse(BastionProtocol.history.contains { $0.path.hasSuffix("/start") })
    }

    @MainActor func testExpiredReadRecoversButUncertainStartNeverReplays() async throws {
        let manager = manager()
        try manager.saveApp(app)
        BastionProtocol.prepare([.login, .init(code: 8888, data: NSNull()), .init(data: ["token": "renewed"]),
                                 .host("STOPPED"), .host("STOPPED"), .init(status: 503, data: NSNull()), .host("STOPPED")])
        try await manager.saveAccount(userName: "qa", password: "test", platformURL: "https://portal.example")
        await manager.refreshAll()
        let renewal = BastionProtocol.history[2]
        XCTAssertEqual(renewal.path, "/auth/refreshToken"); XCTAssertEqual(renewal.token, "access")
        XCTAssertEqual(renewal.body["refreshToken"] as? String, "refresh")
        XCTAssertEqual(BastionProtocol.history.last?.token, "renewed")
        await manager.perform(.start, for: app)
        XCTAssertEqual(manager.statuses[app.ip], .pending)
        await manager.perform(.refresh, for: app)
        XCTAssertEqual(manager.statuses[app.ip], .pending)
        await manager.perform(.start, for: app)
        XCTAssertEqual(BastionProtocol.history.filter { $0.path.hasSuffix("/start") }.count, 1)
    }

    @MainActor func testRejectedSavedLoginIsSharedAndNotRepeatedPerRow() async throws {
        try storage.saveAccount(BastionAccount(userName: "qa", password: "outdated", platformURL: "https://portal.example"))
        let manager = manager()
        for n in 1...8 { try manager.saveApp(BastionApp(name: "Example", packageName: "app.test\(n)", ip: "192.0.2.\(n)")) }
        BastionProtocol.prepare([.init(status: 401, data: NSNull())])
        await manager.refreshAll(); await manager.refreshAll()
        XCTAssertEqual(BastionProtocol.history.map(\.path), ["/auth/login"])
        XCTAssertEqual(manager.statuses.count, 8)
    }

    func testWindowsAppSelectsTheExistingCardByExactAddress() async throws {
        let id = UUID(), other = UUID()
        let records = "\"Remote, Desktop\", \(id)\n\"Other\", \(other)"
        let name = try await BastionDesktop.savedCard(for: "2001:db8::1", list: records) { uuid in
            uuid == id ? "full address:s:[2001:0db8::1]:3389\r\nusername:s:test" : "full address:s:192.0.2.80"
        }
        XCTAssertEqual(name, "Remote, Desktop")
        XCTAssertNil(BastionDesktop.exportedAddress("full address:s:192.0.2.8:3390"))
        XCTAssertEqual(BastionDesktop.exportedAddress("full address:s:192.0.2.8:3389"), app.ip)
    }

    func testMissingOrAmbiguousBookmarksNeverOpenAnAdHocConnection() async throws {
        let id = UUID(), other = UUID()
        for (secondName, firstIP, secondIP) in [("Other", "192.0.2.80", "192.0.2.81"),
                                                 ("Other", app.ip, app.ip), ("Desktop", app.ip, "192.0.2.80")] {
            let records = "\"Desktop\", \(id)\n\"\(secondName)\", \(other)"
            do {
                _ = try await BastionDesktop.savedCard(for: app.ip, list: records) {
                    "full address:s:" + ($0 == id ? firstIP : secondIP)
                }
                XCTFail("Expected a missing or ambiguous bookmark to stop the connection")
            } catch is BastionError {}
        }
    }
}
