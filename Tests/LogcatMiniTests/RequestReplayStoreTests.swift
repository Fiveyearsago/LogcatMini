import XCTest
import Security
@testable import LogcatCore
@testable import LogcatMini

/// Loopback-only integration tests verify the real URLSession path, not a mocked send result.
private final class ReplayLoopbackServer {
    let process = Process()
    let baseURL: String
    init() throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", #"""
import json,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self): self.reply()
    def do_POST(self): self.reply()
    def do_PATCH(self): self.reply()
    def reply(self):
        body=self.rfile.read(int(self.headers.get('Content-Length','0')))
        if self.path=='/slow': time.sleep(2)
        if self.path=='/redirect':
            self.send_response(302); self.send_header('Location','/echo'); self.end_headers(); return
        payload=b'x'*(2*1024*1024+100) if self.path=='/large' else json.dumps({'method':self.command,'path':self.path,'body':body.decode(),'header':self.headers.get('X-QA'),'cookie':self.headers.get('Cookie')}).encode()
        if self.path=='/decrypt':
            params=json.loads(body)
            payload=json.dumps({'result_code':200,'data':{'received_s':params['encrpt_params'],'mode':params['is_new']}}).encode()
        self.send_response(422 if self.path=='/error' else 200)
        self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(payload)))
        self.send_header('Set-Cookie','should_not_persist=1');self.end_headers()
        try:self.wfile.write(payload)
        except (BrokenPipeError,ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""#]
        process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        var data = Data()
        while let byte = output.fileHandleForReading.readData(ofLength: 1).first, byte != 10 { data.append(byte) }
        guard let value = String(data: data, encoding: .utf8), Int(value) != nil else { process.terminate(); throw ReplayError("Loopback server failed to start") }
        baseURL = "http://127.0.0.1:" + value
    }
    deinit { process.terminate(); process.waitUntilExit() }
}

final class RequestReplayStoreTests: XCTestCase {
    @MainActor private func configureSyntheticPublicKey(_ store: RequestReplayStore) throws {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        try store.loadPublicKey("-----BEGIN RSA PUBLIC KEY-----\n" + der.base64EncodedString() + "\n-----END RSA PUBLIC KEY-----", name: "synthetic-test-key")
    }

    @MainActor func testStandaloneSDecryptionWorksWithoutARequestAndDoesNotPersist() async throws {
        let server = try ReplayLoopbackServer()
        let store = LogSDecryptionStore()
        let packet = "AhAAAAAwMTIzNDU2Nzg5YWJjZGVmS0IUlFNUGQJw9xJeNhdj+LHo3T9R4l+ablqhbxoC3Qtbn65Hl75uqS78/dCWqH5HxbWu7DZ8524T6wahwKz0hg=="
        let entry = try XCTUnwrap(LogParser.parse("2026-10-16 10:00:00.001 1 2 I Payload: stage=encode data={\"s\":\"\(packet)\"}", id: 1))
        store.importLog(entry)
        XCTAssertEqual(store.input, packet)
        store.decryptLocally()
        XCTAssertEqual(store.plain, #"{"message":"中文✨","amount":12.5,"request_id":"qa-only"}"#)
        store.decryptUsingService(endpoint: server.baseURL + "/decrypt")
        while store.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(store.plain.utf8)) as? [String: String])
        XCTAssertEqual(response["received_s"], packet); XCTAssertEqual(response["mode"], "old")
        XCTAssertNil(store.error)
        store.input = "not a valid packet"; store.decryptUsingService(endpoint: server.baseURL + "/decrypt")
        XCTAssertFalse(store.busy); XCTAssertNotNil(store.error); XCTAssertTrue(store.plain.isEmpty)
        store.clear(); XCTAssertTrue(store.source.isEmpty); XCTAssertTrue(store.input.isEmpty)
    }
    @MainActor func testStandaloneSRequiresSelectionAndDiscardsCancelledOrStaleResults() async throws {
        let server = try ReplayLoopbackServer(), store = LogSDecryptionStore()
        store.input = #"{"s":"AQ=="} {"s":"Ag=="}"#
        store.extract(); XCTAssertEqual(store.candidates, ["AQ==", "Ag=="])
        store.decryptUsingService(endpoint: server.baseURL + "/decrypt")
        XCTAssertFalse(store.busy); XCTAssertNotNil(store.error)
        store.selectCandidate(1); XCTAssertEqual(store.input, "Ag==")
        store.decryptUsingService(endpoint: server.baseURL + "/slow")
        store.clear()
        store.input = "AQ=="; store.decryptUsingService(endpoint: server.baseURL + "/decrypt")
        while store.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.plain.contains("AQ==")); XCTAssertNil(store.error)
        store.input = "Ag=="; XCTAssertTrue(store.plain.isEmpty)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RequestReplayTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor func testNamedRequestSaveRenameDuplicateDeleteAndRelaunch() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("requests/history.json")
        let store = RequestReplayStore(catalogURL: file)
        store.draft.name = "查询配置"; store.draft.url = "https://example.test/config"; store.draft.body = "body"
        XCTAssertTrue(store.save()); let id = store.draft.id
        store.draft.name = "重新命名"; XCTAssertTrue(store.save()); XCTAssertEqual(store.requests.count, 1)
        store.duplicate(); XCTAssertNotEqual(store.draft.id, id); XCTAssertTrue(store.save())
        let restored = RequestReplayStore(catalogURL: file)
        XCTAssertEqual(restored.requests.count, 2); XCTAssertEqual(restored.requests.last?.name, "重新命名")
        XCTAssertEqual(restored.requests.last?.body, "body")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        restored.deleteRequest(id); XCTAssertEqual(RequestReplayStore(catalogURL: file).requests.count, 1)
    }
    @MainActor func testSendAvailabilityOnlyRequiresURLAndBodyForBodyMethods() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RequestReplayStore(catalogURL: root.appendingPathComponent("history.json"))
        XCTAssertFalse(store.canSend)
        store.draft.importNotes = "日志没有 trace_id，请核对。"
        store.plain = #"{"a":2}"#
        store.draft.url = "https://example.test/config"
        for method in ["GET", "HEAD"] {
            store.draft.method = method
            XCTAssertTrue(store.canSend)
        }
        for method in ["POST", "PUT", "PATCH", "DELETE", "OPTIONS"] {
            store.draft.method = method; store.draft.body = " \n"
            XCTAssertFalse(store.canSend)
            store.draft.body = #"{"s":"opaque encrypted payload"}"#
            XCTAssertTrue(store.canSend)
        }
        store.draft.url = " \n"; XCTAssertFalse(store.canSend)
        store.draft.url = "https://example.test/config"
        try configureSyntheticPublicKey(store)
        store.applyPlain(encrypt: true); XCTAssertTrue(store.canSend)
        let packet = try ReplaySLocation.jsonBody.read(from: store.draft)
        XCTAssertEqual(Data(base64Encoded: packet)?.first, 3)
        store.plain = #"{"a":3}"#; XCTAssertTrue(store.canSend)
        store.applyPlain(encrypt: false, wholeBody: true)
        XCTAssertEqual(store.draft.body, #"{"a":3}"#); XCTAssertTrue(store.canSend)
    }
    @MainActor func testGETSendsWithOnlyURLDespiteOldImportNotesPlainEditsAndLeftoverBody() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try ReplayLoopbackServer()
        let store = RequestReplayStore(catalogURL: root.appendingPathComponent("history.json"))
        store.draft.url = server.baseURL + "/echo?s=opaque%2Bencrypted%2Fvalue%3D"
        store.draft.name = ""
        store.draft.importNotes = "日志没有 trace_id，请核对。"
        store.draft.body = "left over from POST"
        store.plain = "unapplied edit"
        XCTAssertTrue(store.canSend)
        store.send()
        XCTAssertTrue(store.sending); XCTAssertFalse(store.canSend)
        while store.sending { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(store.error); XCTAssertEqual(store.response?.status, 200)
        let response = try XCTUnwrap(store.response)
        let echo = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        XCTAssertEqual(echo["method"] as? String, "GET")
        XCTAssertEqual(echo["body"] as? String, "")
        XCTAssertEqual(server.baseURL + (echo["path"] as? String ?? ""), store.draft.url)
        XCTAssertEqual(store.records.first?.request.body, "")
        XCTAssertEqual(store.draft.body, "left over from POST")
        XCTAssertEqual(store.plain, "unapplied edit")
        XCTAssertFalse(store.draft.name.isEmpty)
    }
    @MainActor func testPOSTSendsCurrentRawBodyWithoutContentOrDecryptionGate() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try ReplayLoopbackServer()
        let store = RequestReplayStore(catalogURL: root.appendingPathComponent("history.json"))
        store.draft.url = server.baseURL + "/echo"; store.draft.method = "POST"
        store.draft.headers = "Content-Type: application/json"
        store.draft.body = "raw payload <redacted> <omitted> {"
        store.draft.importNotes = "旧日志的导入提示"
        store.plain = "unapplied edit"
        XCTAssertTrue(store.canSend)
        store.send()
        while store.sending { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(store.error); XCTAssertEqual(store.response?.status, 200)
        let response = try XCTUnwrap(store.response)
        let echo = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        XCTAssertEqual(echo["method"] as? String, "POST")
        XCTAssertEqual(echo["body"] as? String, store.draft.body)
        XCTAssertEqual(store.records.first?.request.body, store.draft.body)
    }
    @MainActor func testSwitchingRequestsKeepsUnsavedChangesAndDoesNotReloadStaleCopy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RequestReplayStore(catalogURL: root.appendingPathComponent("history.json"))
        store.draft.url = "https://example.test/"; XCTAssertTrue(store.save())
        let old = store.requests[0]
        store.draft.name = "已修改"; store.load(old)
        XCTAssertEqual(store.draft.name, "已修改")
        store.newRequest(); XCTAssertEqual(store.requests[0].name, "已修改")
        XCTAssertTrue(store.draft.url.isEmpty)
    }
    @MainActor func testGETLocalDecryptionUsesCurrentPastedURLAndWritesBackThere() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RequestReplayStore(catalogURL: root.appendingPathComponent("history.json"))
        let plain = #"{"message":"GET 中文参数","count":1}"#
        let s = Data([1] + Array(plain.utf8)).base64EncodedString()
        store.draft.url = "https://example.test/info?drama_id=qa&flag"
        try ReplaySLocation.query.write(s, to: &store.draft)
        store.sLocation = .jsonBody // Stale selection before pasting the URL.
        store.decryptS()
        XCTAssertNil(store.error); XCTAssertEqual(store.plain, plain); XCTAssertEqual(store.sLocation, .query)
        store.plain = #"{"message":"已修改","count":2}"#
        XCTAssertTrue(store.canSend)
        store.applyPlain(encrypt: false, wholeBody: true)
        XCTAssertNotNil(store.error); XCTAssertTrue(store.draft.body.isEmpty); XCTAssertTrue(store.canSend)
        store.applyPlain(encrypt: false)
        XCTAssertNil(store.error); XCTAssertTrue(store.canSend)
        XCTAssertEqual(try ReplaySLocation.query.read(from: store.draft), store.plain)
        XCTAssertTrue(store.draft.url.contains("drama_id=qa&flag&s="))
        XCTAssertNil(try store.draft.prepared().httpBody)
    }
    @MainActor func testGETServiceDecryptionReencryptionSendAndHistory() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try ReplayLoopbackServer()
        let file = root.appendingPathComponent("history.json")
        let store = RequestReplayStore(catalogURL: file)
        store.draft.name = "GET 参数编辑"
        store.draft.url = server.baseURL + "/info?drama_id=qa&s=a%2Bb%2Fc%3D&trace_id=test&flag&repeat=1&repeat=2"
        store.sLocation = .formBody
        store.decryptUsingService(endpoint: server.baseURL + "/decrypt")
        while store.decrypting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(store.error); XCTAssertEqual(store.sLocation, .query)
        let decrypted = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(store.plain.utf8)) as? [String: String])
        XCTAssertEqual(decrypted["received_s"], "a+b/c="); XCTAssertEqual(decrypted["mode"], "old")
        store.plain = #"{"message":"修改后的 GET 参数","count":2}"#
        try configureSyntheticPublicKey(store)
        store.applyPlain(encrypt: true)
        XCTAssertNil(store.error); XCTAssertTrue(store.draft.body.isEmpty)
        let encrypted = try ReplaySLocation.query.read(from: store.draft)
        XCTAssertEqual(Data(base64Encoded: encrypted)?.prefix(5), Data([3,128,0,0,0]))
        XCTAssertTrue(store.draft.url.hasSuffix("&trace_id=test&flag&repeat=1&repeat=2"))
        store.send()
        while store.sending { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(store.error); XCTAssertEqual(store.response?.status, 200)
        let response = try XCTUnwrap(store.response)
        let echo = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        XCTAssertEqual(echo["method"] as? String, "GET"); XCTAssertEqual(echo["body"] as? String, "")
        XCTAssertEqual(server.baseURL + (echo["path"] as? String ?? ""), store.draft.url)
        let restored = RequestReplayStore(catalogURL: file)
        XCTAssertEqual(restored.records.first?.request.url, store.draft.url)
        XCTAssertEqual(restored.records.first?.request.name, "GET 参数编辑")
        restored.restore(try XCTUnwrap(restored.records.first))
        XCTAssertEqual(restored.effectiveSLocation, .query)
        XCTAssertEqual(try ReplaySLocation.query.read(from: restored.draft), encrypted)
    }
    @MainActor func testGETMissingOrDuplicateSDoesNotUseStaleBody() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RequestReplayStore(catalogURL: root.appendingPathComponent("history.json"))
        store.draft.body = #"{"s":"AXt9"}"#
        for url in ["https://example.test/info?drama_id=qa", "https://example.test/info?s=AXt9&s=AXt9"] {
            store.draft.url = url; store.sLocation = .jsonBody
            store.decryptS()
            XCTAssertNotNil(store.error); XCTAssertTrue(store.plain.isEmpty)
            store.decryptUsingService(endpoint: "http://127.0.0.1:1/unused")
            XCTAssertFalse(store.decrypting); XCTAssertNotNil(store.error)
        }
    }
    @MainActor func testHttpMobileClientLogImportPopulatesPOSTBodyAndSAndSendsExactParams() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try ReplayLoopbackServer()
        let file = root.appendingPathComponent("history.json")
        let store = RequestReplayStore(catalogURL: file)
        store.sLocation = .query
        let body = #"{"app_version":10100016,"emotion":"sad","s":"qa+\/packet=="}"#
        let url = server.baseURL + "/v1/emotion/get"
        let raw = "2026-10-14 17:55:42.164 22069 29273 V MD.HttpMobileClient: 17:55:42.164[15086] POST request v1_emotion_get, \(url), params:\(body)"
        let entry = try XCTUnwrap(LogParser.parse(raw, id: 1))
        store.importLog(entry, context: [entry])
        XCTAssertEqual(store.draft.method, "POST")
        XCTAssertEqual(store.draft.url, url)
        XCTAssertEqual(store.draft.body, body)
        XCTAssertEqual(store.sLocation, .jsonBody)
        XCTAssertEqual(try store.effectiveSLocation.read(from: store.draft), "qa+/packet==")
        XCTAssertFalse(store.draft.importNotes.contains("trace_id"))
        XCTAssertTrue(store.canSend)
        store.send()
        while store.sending { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(store.error)
        XCTAssertEqual(store.response?.status, 200)
        let response = try XCTUnwrap(store.response)
        let echo = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        XCTAssertEqual(echo["method"] as? String, "POST")
        XCTAssertEqual(echo["path"] as? String, "/v1/emotion/get")
        XCTAssertEqual(echo["body"] as? String, body)
        let restored = RequestReplayStore(catalogURL: file)
        XCTAssertEqual(restored.records.first?.request.method, "POST")
        XCTAssertEqual(restored.records.first?.request.body, body)
    }
    @MainActor func testCorruptCatalogIsPreservedAndWriteFailureIsReported() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        try Data("invalid".utf8).write(to: file)
        let store = RequestReplayStore(catalogURL: file)
        XCTAssertNotNil(store.error); XCTAssertFalse(store.save())
        XCTAssertEqual(try String(contentsOf: file), "invalid")
        let blocked = RequestReplayStore(catalogURL: file.appendingPathComponent("child.json"))
        XCTAssertFalse(blocked.save()); XCTAssertTrue(blocked.requests.isEmpty)
    }
    func testRealHTTPMethodHeadersBodyStatusRedirectAndResponseLimit() async throws {
        let server = try ReplayLoopbackServer()
        var draft = ReplayRequest(); draft.url = server.baseURL + "/echo"; draft.method = "PATCH"
        draft.headers = "X-QA: replay\nContent-Type: application/json\nContent-Length: 1"; draft.body = #"{"modified":"中文"}"#
        let client = ReplayHTTPClient()
        let response = await client.send(try draft.prepared())
        XCTAssertEqual(response.status, 200); XCTAssertNil(response.error)
        let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        XCTAssertEqual(data["body"] as? String, draft.body); XCTAssertEqual(data["method"] as? String, "PATCH")
        XCTAssertEqual(data["header"] as? String, "replay"); XCTAssertTrue(data["cookie"] is NSNull)
        draft.method = "GET"; draft.body = ""; draft.url = server.baseURL + "/redirect"
        let redirect = await client.send(try draft.prepared()); XCTAssertEqual(redirect.status, 302)
        draft.url = server.baseURL + "/error"
        let failure = await client.send(try draft.prepared()); XCTAssertEqual(failure.status, 422); XCTAssertNil(failure.error)
        draft.url = server.baseURL + "/large"
        let large = await client.send(try draft.prepared()); XCTAssertTrue(large.truncated); XCTAssertEqual(large.body.utf8.count, ReplayHTTPClient.responseLimit)
    }
    @MainActor func testSendSavesExactSnapshotAndResultAcrossRelaunchAndCancel() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try ReplayLoopbackServer()
        let file = root.appendingPathComponent("history.json")
        let store = RequestReplayStore(catalogURL: file)
        store.draft.name = "本机回显"; store.draft.url = server.baseURL + "/echo"; store.draft.method = "POST"
        store.draft.body = "modified=1"; store.draft.headers = "Content-Length: 999\nX-QA: yes"
        store.send(); XCTAssertTrue(store.sending); XCTAssertEqual(store.records.count, 1)
        while store.sending { try await Task.sleep(nanoseconds: 10_000_000) }
        let restored = RequestReplayStore(catalogURL: file)
        XCTAssertEqual(restored.requests.first?.name, "本机回显")
        XCTAssertEqual(restored.records.first?.request.body, "modified=1")
        XCTAssertFalse(restored.records.first!.request.headers.contains("Content-Length"))
        XCTAssertEqual(restored.records.first?.response?.status, 200)
        restored.restore(restored.records[0]); XCTAssertEqual(restored.response?.status, 200)
        store.draft.url = server.baseURL + "/slow"; store.send()
        try await Task.sleep(nanoseconds: 100_000_000); store.cancel()
        while store.sending { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(store.records.first?.response?.error)
        XCTAssertEqual(RequestReplayStore(catalogURL: file).records.count, 2)
        store.deleteRecord(store.records[0].id); XCTAssertEqual(RequestReplayStore(catalogURL: file).records.count, 1)
    }
    @MainActor func testInterruptedPendingRequestIsNotReportedAsSuccess() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let record = ReplayRecord(request: ReplayRequest())
        let recordObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
        try JSONSerialization.data(withJSONObject: ["version":1, "requests":[], "records":[recordObject]]).write(to: file)
        let restored = RequestReplayStore(catalogURL: file)
        XCTAssertNil(restored.records[0].response?.status)
        XCTAssertTrue(restored.records[0].response!.error!.contains("中断"))
    }
}
