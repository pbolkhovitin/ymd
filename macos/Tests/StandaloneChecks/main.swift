import Foundation

// Проверки без XCTest для машины только с Command Line Tools.
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct StandaloneChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(description: message) }
    }

    @MainActor
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ymd-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func config(_ name: String, _ script: String) throws -> DaemonConfiguration {
            let file = dir.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            return DaemonConfiguration(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [file.path], environment: [:], logURL: dir.appendingPathComponent("child.log"), timeout: 0.3, pollInterval: 0.02)
        }
        var probes = 0
        let owned = DaemonSupervisor(configuration: try config("owned", "exec /bin/sleep 20")) {
            probes += 1
            return probes == 1 ? .absent : .available
        }
        await owned.start()
        try expect(owned.phase == .ready, "Свой процесс должен запуститься")
        guard let pid = owned.ownedProcessID else { throw CheckFailure(description: "Нет PID своего процесса") }
        await owned.start()
        try expect(owned.ownedProcessID == pid, "Повторный start создал дубликат")
        owned.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(kill(pid, 0) == -1, "Свой процесс остался после stop")
        print("ok: own start/stop, no duplicates")

        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/bin/sleep")
        external.arguments = ["20"]
        try external.run()
        defer { if external.isRunning { external.terminate() } }
        let attached = DaemonSupervisor(configuration: try config("external", "exit 99")) { .available }
        await attached.start()
        attached.stop()
        try expect(attached.ownedProcessID == nil && external.isRunning, "Клиент остановил внешний процесс")
        print("ok: external process preserved")

        let conflict = DaemonSupervisor(configuration: try config("conflict", "exit 99")) { .conflict }
        await conflict.start()
        guard case .failed = conflict.phase else { throw CheckFailure(description: "Конфликт должен давать ошибку") }
        try expect(conflict.ownedProcessID == nil, "Запущен процесс при конфликте")
        let crash = DaemonSupervisor(configuration: try config("crash", "exit 7")) { .absent }
        await crash.start()
        guard case .failed = crash.phase else { throw CheckFailure(description: "Нет ошибки раннего падения") }
        await crash.start()
        guard case .failed = crash.phase else { throw CheckFailure(description: "Нет ошибки при retry") }
        let timeout = DaemonSupervisor(configuration: try config("timeout", "exec /bin/sleep 20")) { .absent }
        await timeout.start()
        guard case .failed = timeout.phase else { throw CheckFailure(description: "Нет ошибки таймаута") }
        try expect(timeout.ownedProcessID == nil, "Процесс таймаута остался собственностью клиента")
        var runtimeProbes = 0
        let runtimeCrash = DaemonSupervisor(configuration: try config("runtime-crash", "/bin/sleep 0.15; exit 7")) {
            runtimeProbes += 1
            return runtimeProbes == 1 ? .absent : .available
        }
        await runtimeCrash.start()
        try expect(runtimeCrash.phase == .ready, "Демон не перешёл в готовность")
        try await Task.sleep(nanoseconds: 400_000_000)
        guard case .failed = runtimeCrash.phase else { throw CheckFailure(description: "Нет ошибки падения после готовности") }
        print("ok: conflict, startup crash, timeout, retry, runtime crash")

        let env = DaemonConfiguration.bundleEnvironment(contents: URL(fileURLWithPath: "/tmp/App.app/Contents"), runDirectory: dir, version: "test", inherited: ["GST_DEBUG": "9", "GIO_USE_TLS": "bad", "DYLD_INSERT_LIBRARIES": "bad"])
        try expect(env["GST_DEBUG"] == nil && env["GIO_USE_TLS"] == nil && env["DYLD_INSERT_LIBRARIES"] == nil, "Унаследованы runtime-переменные")
        try expect(env["YMD_CA_BUNDLE"] == "/tmp/App.app/Contents/Resources/certs/ca-certificates.crt", "Нет bundle CA")
        try expect(env["DYLD_LIBRARY_PATH"] == "/tmp/App.app/Contents/Frameworks", "Неверный поиск dylib")
        for value in ["http://oauth.yandex.ru", "https://oauth.yandex.ru.evil.com", "https://evil.yandex.ru", "https://a@oauth.yandex.ru", "file:///tmp/a", "https://oauth.yandex.ru:8443"] {
            try expect(DeviceAuth.browserURL(value) == nil, "Разрешён недоверенный URL: \(value)")
        }
        try expect(DeviceAuth.browserURL("https://oauth.yandex.ru/device") != nil, "Запрещён доверенный OAuth URL")
        print("ok: runtime environment and trusted OAuth URL")
        try await checkHTTP()
        try await checkLocalHTTP(in: dir)
        try await checkDelayedTermination(in: dir)
        try await checkIgnoredTermination(in: dir)
        try await checkModelRegressions(in: dir)
    }

    @MainActor
    static func checkModelRegressions(in dir: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedProtocol.self]
        let api = APIClient(session: URLSession(configuration: config), sessionKey: { "fixture-session-key-123" })
        var externalProbes = 0
        let supervisor = DaemonSupervisor { externalProbes += 1; return .available }
        let model = AppModel(api: api, supervisor: supervisor)
        await supervisor.start()
        DelayedProtocol.response = (200, "{\"rev\":1,\"status\":\"stopped\",\"positionMs\":0}")
        var requested = false
        DelayedProtocol.onStart = { Task { @MainActor in requested = true } }
        let pending = Task { await model.refresh() }
        while !requested { try await Task.sleep(nanoseconds: 1_000_000) }
        supervisor.stop()
        await supervisor.start()
        await pending.value
        try expect(model.connection == .ready && model.state == nil, "Поздний refresh прежнего подключения изменил новое состояние")

        await supervisor.start()
        requested = false
        DelayedProtocol.response = (200, "{\"login\":\"alice\",\"uid\":1,\"plus\":true,\"backend\":\"keychain\",\"savedAt\":1}")
        let account = Task { await model.refreshAccount() }
        while !requested { try await Task.sleep(nanoseconds: 1_000_000) }
        supervisor.stop()
        await account.value
        try expect(model.account == nil, "Поздний account изменил состояние после stop")

        let crashConfig = DaemonConfiguration(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.1"], environment: [:], logURL: dir.appendingPathComponent("model-crash.log"))
        var crashProbes = 0
        let crashing = DaemonSupervisor(configuration: crashConfig) {
            crashProbes += 1
            return crashProbes == 1 ? .absent : .available
        }
        let crashModel = AppModel(api: api, supervisor: crashing)
        await crashing.start()
        requested = false
        DelayedProtocol.response = (200, "{\"rev\":1,\"status\":\"stopped\",\"positionMs\":0}")
        let delayed = Task { await crashModel.refresh() }
        while !requested { try await Task.sleep(nanoseconds: 1_000_000) }
        while crashing.phase == .ready { try await Task.sleep(nanoseconds: 1_000_000) }
        let failure = crashModel.errorText
        await delayed.value
        try expect(crashModel.errorText == failure && failure != nil && crashModel.state == nil, "Поздний state затёр ошибку падения демона")

        await supervisor.start()
        DelayedProtocol.failure = URLError(.cannotConnectToHost)
        await model.refresh()
        try expect(model.connection != .ready, "Исчезнувший external оставил ready и скрыл retry")
        DelayedProtocol.failure = nil
        DelayedProtocol.response = (200, "{\"rev\":1,\"status\":\"stopped\",\"positionMs\":0}")
        model.reload()
        let reconnectDeadline = Date().addingTimeInterval(1)
        while model.connection != .ready && Date() < reconnectDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
        try expect(model.connection == .ready && externalProbes > 2, "Reload не вызвал supervisor.start после потери external")
        model.stop()
        var liveProbes = 0
        let liveConfig = DaemonConfiguration(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], environment: [:], logURL: dir.appendingPathComponent("model-live.log"))
        let live = DaemonSupervisor(configuration: liveConfig) {
            liveProbes += 1
            return liveProbes == 1 ? .absent : .available
        }
        let liveModel = AppModel(api: api, supervisor: live)
        await live.start()
        let ownPID = live.ownedProcessID
        DelayedProtocol.failure = URLError(.cannotConnectToHost)
        await liveModel.refresh()
        try expect(live.phase == .ready && live.ownedProcessID == ownPID, "Ошибка HTTP потеряла живой own процесс")
        live.stop()
        DelayedProtocol.failure = nil
        print("ok: delayed state/account/crash guarded, external reconnect, live own preserved")
    }

    @MainActor
    static func checkIgnoredTermination(in dir: URL) async throws {
        let script = dir.appendingPathComponent("ignore-term.py")
        let ready = dir.appendingPathComponent("ignore-ready")
        try """
        import signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        open(sys.argv[1], 'w').close()
        time.sleep(20)
        """.write(to: script, atomically: true, encoding: .utf8)
        let external = Process()
        external.executableURL = URL(fileURLWithPath: "/bin/sleep")
        external.arguments = ["20"]
        try external.run()
        defer { if external.isRunning { external.terminate() } }
        var probes = 0
        let config = DaemonConfiguration(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, ready.path], environment: ["PATH": "/usr/bin:/bin"], logURL: dir.appendingPathComponent("ignore.log"), timeout: 2, pollInterval: 0.01, stopGracePeriod: 0.15)
        let supervisor = DaemonSupervisor(configuration: config) {
            probes += 1
            if probes == 1 { return .absent }
            return FileManager.default.fileExists(atPath: ready.path) ? .available : .absent
        }
        await supervisor.start()
        guard let pid = supervisor.ownedProcessID else { throw CheckFailure(description: "Нет ignore TERM процесса") }
        let started = Date()
        supervisor.stop()
        await supervisor.start()
        try expect(kill(pid, 0) == -1, "SIGKILL fallback не завершил собственный процесс")
        try expect(Date().timeIntervalSince(started) < 1.2, "Ожидание SIGKILL fallback не ограничено")
        try expect(external.isRunning, "Fallback затронул внешний процесс")
        supervisor.stop()
        print("ok: bounded SIGKILL only for owned child ignoring TERM")
    }

    @MainActor
    static func checkDelayedTermination(in dir: URL) async throws {
        let script = dir.appendingPathComponent("delayed-term.py")
        let ready = dir.appendingPathComponent("term-ready")
        try """
        import signal, sys, time
        def stop(*args):
            time.sleep(0.35)
            sys.exit(0)
        signal.signal(signal.SIGTERM, stop)
        open(sys.argv[1], 'w').close()
        while True:
            time.sleep(0.01)
        """.write(to: script, atomically: true, encoding: .utf8)
        var count = 0
        var stoppedPID: Int32?
        var prematureProbe = false
        let config = DaemonConfiguration(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, ready.path], environment: ["PATH": "/usr/bin:/bin"], logURL: dir.appendingPathComponent("term.log"), timeout: 2, pollInterval: 0.01)
        let supervisor = DaemonSupervisor(configuration: config) {
            count += 1
            if let pid = stoppedPID, kill(pid, 0) == 0 { prematureProbe = true }
            if count == 1 { return .absent }
            return FileManager.default.fileExists(atPath: ready.path) ? .available : .absent
        }
        await supervisor.start()
        guard let pid = supervisor.ownedProcessID else { throw CheckFailure(description: "Нет delayed TERM процесса") }
        stoppedPID = pid
        supervisor.stop()
        try expect(supervisor.ownedProcessID == pid, "stop потерял владение ещё живым процессом")
        await supervisor.start()
        try expect(!prematureProbe, "retry проверял порт до завершения прежнего own процесса")
        try expect(kill(pid, 0) == -1, "retry оставил прежний own процесс живым")
        supervisor.stop()
        try await Task.sleep(nanoseconds: 450_000_000)
        print("ok: delayed TERM preserves ownership and retry waits for exit")
    }

    @MainActor
    static func checkLocalHTTP(in dir: URL) async throws {
        let script = dir.appendingPathComponent("server.py")
        let portFile = dir.appendingPathComponent("port")
        let marker = dir.appendingPathComponent("starts")
        try """
        import http.server, json, sys
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/v1/health':
                    code, data = 200, {'ok': True}
                elif self.path == '/v1/state' and self.headers.get('X-YMD-Session') == 'fixture-session-key-123':
                    code, data = 200, {'rev': 1, 'status': 'stopped', 'positionMs': 0}
                else:
                    code, data = 401, {}
                self.send_response(code)
                self.end_headers()
                self.wfile.write(json.dumps(data).encode())
            def log_message(self, *args):
                pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        with open(sys.argv[1], 'w') as file:
            file.write(str(server.server_port))
        with open(sys.argv[2], 'a') as file:
            file.write('start\\n')
        server.serve_forever()
        """.write(to: script, atomically: true, encoding: .utf8)
        let configuration = DaemonConfiguration(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, portFile.path, marker.path], environment: ["PATH": "/usr/bin:/bin"], logURL: dir.appendingPathComponent("http.log"), timeout: 10, pollInterval: 0.05)
        let supervisor = DaemonSupervisor(configuration: configuration) {
            guard let text = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(text) else { return .absent }
            let api = APIClient(base: URL(string: "http://127.0.0.1:\(port)")!, sessionKey: { "fixture-session-key-123" })
            return await api.probe()
        }
        let first = Task { await supervisor.start() }
        let repeated = Task { await supervisor.start() }
        await first.value
        await repeated.value
        try expect(supervisor.phase == .ready, "HTTP fixture не дождался готовности: \(supervisor.phase)")
        try expect((try? String(contentsOf: marker, encoding: .utf8)) == "start\n", "Параллельный start запустил несколько HTTP процессов")
        supervisor.stop()
        print("ok: real local HTTP readiness and concurrent start")
    }

    static func checkHTTP() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = APIClient(session: URLSession(configuration: config), sessionKey: { "fixture-session-key-123" })
        FixtureProtocol.reply = { _ in throw URLError(.cannotConnectToHost) }
        let absent = await api.probe()
        try expect(absent == .absent, "Отсутствующий сервер определён неверно")
        var timeouts: [TimeInterval] = []
        FixtureProtocol.reply = { request in
            timeouts.append(request.timeoutInterval)
            return request.url!.path == "/v1/health" ? (200, "{\"ok\":true}") : (401, "")
        }
        let rejected = await api.probe()
        try expect(rejected == .conflict, "Чужой session key не дал конфликт")
        try expect(timeouts.allSatisfy { $0 <= 0.5 }, "Проверка готовности использует долгий таймаут")
        FixtureProtocol.reply = { request in
            switch request.url!.path {
            case "/v1/health": return (200, "{\"ok\":true}")
            case "/v1/account": return (401, "")
            default: return (200, "{\"rev\":1,\"status\":\"stopped\",\"positionMs\":0}")
            }
        }
        let available = await api.probe()
        try expect(available == .available, "Валидная сессия отвергнута")
        let account = try await api.account()
        try expect(account == nil, "Отсутствие аккаунта не распознано")
        var methods: [String] = []
        FixtureProtocol.reply = { request in
            try expect(request.value(forHTTPHeaderField: "X-YMD-Session") == "fixture-session-key-123", "Нет session header")
            try expect(request.url!.path == "/v1/auth/device", "Неверный device endpoint")
            methods.append(request.httpMethod!)
            return (200, "{\"state\":\"pending\",\"userCode\":\"ABCD\",\"url\":\"https://oauth.yandex.ru/device\",\"expiresIn\":600}")
        }
        let flow = try await api.deviceAuth(method: "POST")
        try expect(flow.userCode == "ABCD", "Потерян код OAuth")
        _ = try await api.deviceAuth()
        _ = try await api.deviceAuth(method: "DELETE")
        try expect(methods == ["POST", "GET", "DELETE"], "Неверные методы Device Flow")
        FixtureProtocol.reply = { request in
            let object = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            try expect(object["op"] as? String == "wave_start", "Неверная команда волны")
            return (200, "{}")
        }
        try await api.command("wave_start")
        print("ok: HTTP health/session/account, device flow methods, wave_start")
    }
}

private final class FixtureProtocol: URLProtocol {
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

private final class DelayedProtocol: URLProtocol {
    static var response = (200, "{}")
    static var failure: Error?
    static var onStart: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.onStart?()
        let response = Self.response
        let failure = Self.failure
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
            if let failure { client?.urlProtocol(self, didFailWithError: failure); return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
