import XCTest
@testable import ymd_menubar

private final class ReplyProtocol: URLProtocol {
    static var reply: (URLRequest) throws -> (Int, String) = { _ in (500, "") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, body) = try Self.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    private func client() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReplyProtocol.self]
        return APIClient(session: URLSession(configuration: config), sessionKey: { "test-session-key-123456" })
    }

    func testHealthWithBadSessionIsConflict() async {
        ReplyProtocol.reply = { request in
            request.url!.path == "/v1/health" ? (200, "{\"ok\":true}") : (401, "")
        }
        let result = await client().probe()
        XCTAssertEqual(result, .conflict)
    }

    func testConnectionRefusedIsAbsent() async {
        ReplyProtocol.reply = { _ in throw URLError(.cannotConnectToHost) }
        let result = await client().probe()
        XCTAssertEqual(result, .absent)
    }

    func testUnknownHealthReplyIsConflict() async {
        ReplyProtocol.reply = { _ in (200, "<html>other server</html>") }
        let result = await client().probe()
        XCTAssertEqual(result, .conflict)
    }

    func testMissingAccountDoesNotInvalidateWorkingSession() async throws {
        ReplyProtocol.reply = { request in
            if request.url!.path == "/v1/account" { return (401, "no account") }
            if request.url!.path == "/v1/health" { return (200, "{\"ok\":true}") }
            return (200, "{\"rev\":1,\"status\":\"stopped\",\"positionMs\":0}")
        }
        let api = client()
        let status = await api.probe()
        XCTAssertEqual(status, .available)
        let account = try await api.account()
        XCTAssertNil(account)
    }

    func testDeviceFlowMethodsAndSessionHeader() async throws {
        var methods: [String] = []
        ReplyProtocol.reply = { request in
            XCTAssertEqual(request.url!.path, "/v1/auth/device")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-YMD-Session"), "test-session-key-123456")
            methods.append(request.httpMethod!)
            return (200, "{\"state\":\"pending\",\"userCode\":\"ABCD\",\"url\":\"https://oauth.yandex.ru/device\",\"expiresIn\":600}")
        }
        let api = client()
        let flow = try await api.deviceAuth(method: "POST")
        XCTAssertEqual(flow.userCode, "ABCD")
        _ = try await api.deviceAuth()
        _ = try await api.deviceAuth(method: "DELETE")
        XCTAssertEqual(methods, ["POST", "GET", "DELETE"])
    }

    func testWaveCommand() async throws {
        ReplyProtocol.reply = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            XCTAssertEqual(body["op"] as? String, "wave_start")
            return (200, "{}")
        }
        try await client().command("wave_start")
    }

    func testAuthURLRequiresExactTrustedHTTPSHost() {
        XCTAssertNotNil(DeviceAuth.browserURL("https://oauth.yandex.ru/device"))
        for value in ["http://oauth.yandex.ru/device", "https://oauth.yandex.ru.evil.com", "https://evil.yandex.ru", "https://evil.com@oauth.yandex.ru/device", "file:///tmp/a", "https://oauth.yandex.ru:8443/device"] {
            XCTAssertNil(DeviceAuth.browserURL(value), value)
        }
    }
}

private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&bytes, maxLength: bytes.count)
        if count <= 0 { break }
        data.append(contentsOf: bytes.prefix(count))
    }
    return data
}
