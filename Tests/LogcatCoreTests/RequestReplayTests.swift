import XCTest
import Security
@testable import LogcatCore

final class RequestReplayTests: XCTestCase {
    private func row(_ id: UInt64, _ message: String, tid: String = "2", pid: String = "1", raw: String? = nil) -> LogEntry {
        LogEntry(id: id, date: "10-14", time: "10:00:00.100", pid: pid, tid: tid, level: .info, tag: "LC.Network", message: message, raw: raw ?? "10-14 10:00:00.100 \(pid) \(tid) I LC.Network: \(message)")
    }
    func testTraceAssociationHandlesInterleavedRequestsAndPhysicalContinuationLines() throws {
        let rows = [row(1, "--> POST https://example.test/a trace_id=A request_id=1"),
                    row(2, "--> POST https://example.test/b trace_id=B request_id=2"),
                    row(3, "request headers trace_id=A request_id=1", tid: "3"),
                    row(4, #"{"Content-Type":"application/json","portal":"qa"}"#, tid: "3", raw: #"{"Content-Type":"application/json","portal":"qa"}"#),
                    row(5, "request body trace_id=B request_id=2\n{\"wrong\":true}"),
                    row(6, "request body trace_id=A request_id=1"),
                    row(7, #"{"s":"only-A","n":1}"#, raw: #"{"s":"only-A","n":1}"#),
                    row(8, "<-- 200 https://example.test/a trace_id=A\n{\"result\":200}")]
        for selected in [rows[0], rows[6], rows[7]] {
            let request = RequestLogImporter.extract(selected: selected, context: rows)
            XCTAssertEqual(request.url, "https://example.test/a")
            XCTAssertEqual(request.body, #"{"s":"only-A","n":1}"#)
            XCTAssertTrue(request.headers.contains("portal: qa"))
            XCTAssertEqual(request.method, "POST")
            XCTAssertFalse(request.body.contains("result"))
        }
    }
    func testChunkedBodiesRequireEveryPartAndStayWithinSource() {
        let rows = [row(1, "--> POST https://example.test/chunk trace_id=C"),
                    row(2, "request body [1/2] trace_id=C\n{\"s\":\""),
                    row(3, "request body [2/2] trace_id=C\nvalue\"}"),
                    row(4, "request body trace_id=C\n{\"wrong\":1}", pid: "99")]
        XCTAssertEqual(RequestLogImporter.extract(selected: rows[0], context: rows).body, #"{"s":"value"}"#)
        XCTAssertEqual(RequestLogImporter.extract(selected: rows[0], context: Array(rows.prefix(2))).body, "")
    }
    func testThreadtimePrefixedPhysicalPayloadLinesAreAssociatedWithTrace() {
        let rows = [row(1, "--> POST https://example.test/a trace_id=T"),
                    row(2, "request headers trace_id=T"), row(3, #"{"Content-Type":"application/json"}"#),
                    row(4, "request body trace_id=T"), row(5, #"{"s":"a"}"#),
                    row(6, "<-- 200 https://example.test/a trace_id=T"), row(7, "response body trace_id=T"), row(8, "{\"ok\":true}")]
        for index in [0, 3, 4] {
            let request = RequestLogImporter.extract(selected: rows[index], context: rows)
            XCTAssertEqual(request.url, "https://example.test/a")
            XCTAssertEqual(request.body, #"{"s":"a"}"#)
            XCTAssertEqual(request.headers, "Content-Type: application/json")
        }
    }
    func testNoTraceStopsAtNextRequestAndResponseAndImportsFCMChunks() {
        let rows = [row(1, "--> POST https://example.test/first"),
                    row(2, "request body [1/2]={\"s\":"), row(3, "request body [2/2]=\"first\"}"),
                    row(4, "<-- 200 https://example.test/first"), row(5, "response body={\"response\":1}"),
                    row(6, "--> POST https://example.test/second"), row(7, "request body={\"s\":\"second\"}")]
        let request = RequestLogImporter.extract(selected: rows[2], context: rows)
        XCTAssertEqual(request.url, "https://example.test/first")
        XCTAssertEqual(request.body, #"{"s":"first"}"#)
        XCTAssertFalse(request.importNotes.contains("trace_id"))
        XCTAssertEqual(RequestLogImporter.extract(selected: rows[6], context: rows).body, #"{"s":"second"}"#)
    }
    func testOmittedBodyAndCachedCommandAreNotSentAsBody() {
        for payload in ["request body=<omitted for non-debug build> trace_id=X", "request body trace_id=X bytes=9999\nadb shell run-as example cat cache/request.json"] {
            let rows = [row(1, "--> POST https://example.test/path trace_id=X"), row(2, payload)]
            let request = RequestLogImporter.extract(selected: rows[0], context: rows)
            XCTAssertTrue(request.body.isEmpty); XCTAssertTrue(request.importNotes.contains("请"))
        }
    }
    func testImportsSingleLineFieldsAndOkHttpLogBlock() {
        let inline = row(1, #"url=https://example.test/update method=PATCH requestBody={"amount":5}"#)
        let request = RequestLogImporter.extract(selected: inline, context: [inline])
        XCTAssertEqual(request.method, "PATCH"); XCTAssertEqual(request.body, #"{"amount":5}"#)
        let okhttp = row(2, "--> POST https://example.test/test\nContent-Type: application/json\nX-Test: value\n\n{\"x\":1}\n--> END POST (7-byte body)")
        let imported = RequestLogImporter.extract(selected: okhttp, context: [okhttp])
        XCTAssertEqual(imported.body, #"{"x":1}"#)
        XCTAssertTrue(imported.headers.contains("X-Test: value"))
    }
    func testHttpMobileClientNamedPOSTImportsInlineParamsWithoutRewritingBody() throws {
        // Same logger format as the reported request; identifiers and ciphertext are synthetic.
        let s = "A4AAAABN+" + String(repeating: #"test\/value+"#, count: 60) + "=="
        let body = #"{"app_version":10100016,"gaid":"qa-device","screen_height":2376,"day":"2026-10-14","app_id":"com.example.qa","screen_width":1080,"identity_id":"qa-identity","os_version":36,"version_id":"qa-version","api_version":1,"emotion":"sad","os_type":"android","s":""# + s + #""}"#
        let raw = "2026-10-14 17:55:42.164 22069 29273 V MD.HttpMobileClient: 17:55:42.164[15086] POST request v1_emotion_get, http://example.test/v1/emotion/get, params:" + body
        let entry = try XCTUnwrap(LogParser.parse(raw, id: 1))
        let request = RequestLogImporter.extract(selected: entry, context: [entry])
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, "http://example.test/v1/emotion/get")
        XCTAssertEqual(request.body, body)
        XCTAssertEqual(request.headers, "Content-Type: application/json; charset=utf-8")
        XCTAssertEqual(try ReplaySLocation.jsonBody.read(from: request), s.replacingOccurrences(of: #"\/"#, with: "/"))
        XCTAssertFalse(request.importNotes.contains("未识别请求方法"))
        XCTAssertFalse(request.importNotes.contains("未取得完整 Body"))
        let wire = try request.prepared()
        XCTAssertEqual(wire.httpMethod, "POST")
        XCTAssertEqual(wire.httpBody, Data(body.utf8))
    }
    func testHttpMobileClientNamedRequestsDoNotMixParamsOrParsePayloadAsEnvelope() {
        let bodies = [#"{"emotion":"sad","requestBody":"keep literal","callback":"GET https://example.test/not-the-request","s":"first+\/=="}"#,
                      #"{"emotion":"happy","s":"second"}"#]
        let rows = bodies.enumerated().map { index, body in
            row(UInt64(index + 1), "17:55:42.164[15086] POST request v1_emotion_get, https://example.test/\(index), params:" + body)
        }
        for (index, entry) in rows.enumerated() {
            let request = RequestLogImporter.extract(selected: entry, context: rows)
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.url, "https://example.test/\(index)")
            XCTAssertEqual(request.body, bodies[index])
        }
    }
    func testEditedRequestRecalculatesTransportHeadersAndPreservesExactBody() throws {
        var request = ReplayRequest(); request.url = "https://example.test/a?q=1"; request.method = "PATCH"
        request.headers = "Content-Type: application/json\nContent-Length: 1\nHost: stale.test\nAuthorization: qa-only\nAccept-Encoding: gzip"
        request.body = "{\"id\":9223372036854775807,\"text\":\"中文\"}"
        let wire = try request.prepared()
        XCTAssertEqual(wire.httpMethod, "PATCH"); XCTAssertEqual(wire.httpBody, Data(request.body.utf8))
        XCTAssertNil(wire.value(forHTTPHeaderField: "Content-Length")); XCTAssertNil(wire.value(forHTTPHeaderField: "Host"))
        XCTAssertNil(wire.value(forHTTPHeaderField: "Accept-Encoding")); XCTAssertEqual(wire.value(forHTTPHeaderField: "Authorization"), "qa-only")
    }
    func testInvalidURLsMethodsAndHeadersAreRejected() {
        var request = ReplayRequest()
        for url in ["file:///tmp/test", "https://", "https://user:pass@example.test/", "https://example.test/#part"] {
            request.url = url; XCTAssertThrowsError(try request.prepared())
        }
        request.url = "http://127.0.0.1:8123/"
        request.headers = "X-Test: one\nx-test: two"; XCTAssertThrowsError(try request.prepared())
        request.headers = "Invalid header"; XCTAssertThrowsError(try request.prepared())
        request.headers = ""; request.method = "INVALID"; XCTAssertThrowsError(try request.prepared())
        request.method = "POST"
        request.body = ""; request.timeout = .nan; XCTAssertThrowsError(try request.prepared())
    }
    func testGETIgnoresBodyAndPOSTPreservesRawBodyWithoutContentValidation() throws {
        var request = ReplayRequest(); request.url = "https://example.test/"
        request.body = "left over from POST"
        XCTAssertNil(try request.prepared().httpBody)
        request.method = "HEAD"; XCTAssertNil(try request.prepared().httpBody)
        request.method = "POST"; request.headers = "Content-Type: application/json"
        for body in [#"{"token":"<redacted>"}"#, "<omitted>", "{\"s\":"] {
            request.body = body
            XCTAssertEqual(try request.prepared().httpBody, Data(body.utf8))
        }
    }
    func testSEditingPreservesOtherFieldsAndEncodesPlusSlashEquals() throws {
        var request = ReplayRequest(); request.body = #"{"s":"old","other":42}"#
        try ReplaySLocation.jsonBody.write("a+b/c=", to: &request)
        XCTAssertEqual(try ReplaySLocation.jsonBody.read(from: request), "a+b/c=")
        XCTAssertTrue(request.body.contains("42"))
        request.body = "keep=a%2Bb&s=old&empty="
        try ReplaySLocation.formBody.write("a+b/c=中文", to: &request)
        XCTAssertEqual(try ReplaySLocation.formBody.read(from: request), "a+b/c=中文")
        XCTAssertTrue(request.body.hasPrefix("keep=a%2Bb&s=a%2Bb%2Fc%3D"))
        request.url = "https://example.test/path?keep=a%2Bb&s=old"
        try ReplaySLocation.query.write("a+b/c=", to: &request)
        XCTAssertEqual(try ReplaySLocation.query.read(from: request), "a+b/c=")
        XCTAssertTrue(request.url.contains("keep=a%2Bb"))
        request.body = "s=a&s=b"; XCTAssertThrowsError(try ReplaySLocation.formBody.read(from: request))
    }
    func testTypeOneAndMalformedPackets() throws {
        XCTAssertEqual(try SPacketCodec.decrypt(Data([1] + Array("中文".utf8)).base64EncodedString()), "中文")
        for data in [Data(), Data([3, 255, 255, 255, 255]), Data([2, 16, 0, 0, 0]), Data([4, 1])] {
            XCTAssertThrowsError(try SPacketCodec.decrypt(data.base64EncodedString()))
        }
        XCTAssertThrowsError(try SPacketCodec.decrypt("not-base64"))
    }
    func testURLSDecodesOnceAndWritebackPreservesOtherQueryBytes() throws {
        var request = ReplayRequest()
        let prefix = "http://example.test/mira/v1/drama/info?drama_id=qa&s="
        let suffix = "&trace_id=qa-trace&from=example.test&keep=a%2bb&repeat=1&repeat=2&flag&&empty=&support_pangle=1&"
        request.url = prefix + "a%2Bb%2Fc%3D" + suffix
        XCTAssertEqual(try ReplaySLocation.query.read(from: request), "a+b/c=")
        try ReplaySLocation.query.write("new+/=", to: &request)
        XCTAssertEqual(request.url, prefix + "new%2B%2F%3D" + suffix)
        XCTAssertTrue(request.body.isEmpty)
        request.url = prefix + "a+b/c="
        XCTAssertEqual(try ReplaySLocation.query.read(from: request), "a+b/c=")
        request.url = prefix + "a%252Bb"
        XCTAssertEqual(try ReplaySLocation.query.read(from: request), "a%2Bb")
        request.url = prefix + "one&%73=two"
        XCTAssertThrowsError(try ReplaySLocation.query.read(from: request))
        let original = request.url
        XCTAssertThrowsError(try ReplaySLocation.query.write("replacement", to: &request))
        XCTAssertEqual(request.url, original)
        request.body = "s=a+b%2Bc"
        XCTAssertEqual(try ReplaySLocation.formBody.read(from: request), "a b+c")
    }
    func testTypeTwoMatchesIndependentOpenSSLAESCBCFixture() throws {
        let packet = "AhAAAAAwMTIzNDU2Nzg5YWJjZGVmS0IUlFNUGQJw9xJeNhdj+LHo3T9R4l+ablqhbxoC3Qtbn65Hl75uqS78/dCWqH5HxbWu7DZ8524T6wahwKz0hg=="
        XCTAssertEqual(try SPacketCodec.decrypt(packet), #"{"message":"中文✨","amount":12.5,"request_id":"qa-only"}"#)
    }
    func testRemoteServiceRejectsFailureHiddenInsideHTTP200AndBusiness200() throws {
        XCTAssertThrowsError(try RemoteSDecryptor.parseResponse(#"{"data":{"message":"no decrpt message,please check your encrpt params!"},"result_code":200}"#))
        XCTAssertThrowsError(try RemoteSDecryptor.parseResponse(#"{"data":null,"result_code":200}"#))
        XCTAssertThrowsError(try RemoteSDecryptor.parseResponse(#"{"data":{},"result_code":500}"#))
        let plain = try RemoteSDecryptor.parseResponse(#"{"data":{"message":"中文","count":1},"result_code":200}"#)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any])?["message"] as? String, "中文")
    }
    func testRemoteDecoderRequiresExplicitEndpoint() async {
        XCTAssertTrue(RemoteSDecryptor.endpoint.isEmpty)
        do {
            _ = try await RemoteSDecryptor.decrypt("AQ==")
            XCTFail("An unconfigured remote decoder must not send a request")
        } catch { XCTAssertTrue(error.localizedDescription.contains("服务地址")) }
    }
    func testRSAEncryptionAndPEMImportAndWrongKeyFailure() throws {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n" + der.base64EncodedString() + "\n-----END RSA PRIVATE KEY-----"
        let imported = try SPacketCodec.importPrivateKey(pem)
        let plain = #"{"message":"中文","request_id":"test"}"#
        let first = try SPacketCodec.encrypt(plain, publicKey: publicKey)
        let second = try SPacketCodec.encrypt(plain, publicKey: publicKey)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try SPacketCodec.decrypt(first, privateKey: imported), plain)
        XCTAssertThrowsError(try SPacketCodec.decrypt(first))
        let wrong = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        XCTAssertThrowsError(try SPacketCodec.decrypt(first, privateKey: wrong))
        XCTAssertThrowsError(try SPacketCodec.encrypt(plain))
        let publicDER = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let publicPEM = "-----BEGIN RSA PUBLIC KEY-----\n" + publicDER.base64EncodedString() + "\n-----END RSA PUBLIC KEY-----"
        let importedPublic = try SPacketCodec.importPublicKey(publicPEM)
        let encrypted = try SPacketCodec.encrypt(plain, publicKey: importedPublic)
        XCTAssertEqual(try SPacketCodec.decrypt(encrypted, privateKey: imported), plain)
        XCTAssertThrowsError(try SPacketCodec.importPrivateKey("-----BEGIN ENCRYPTED PRIVATE KEY-----"))
    }
}
