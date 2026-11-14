import Foundation

/// Состояние плеера — подмножество `/v1/state` демона.
struct PlayerState: Decodable {
    struct Track: Decodable {
        let id: String
        let title: String
        let artists: [String]
        let album: String?
        let durationMs: Int
        let cover: String?
    }

    struct Queue: Decodable {
        let length: Int
        let index: Int
        let shuffle: Bool
        let repeatMode: String?

        enum CodingKeys: String, CodingKey {
            case length, index, shuffle
            case repeatMode = "repeat"
        }
    }

    let rev: Int
    let status: String
    let track: Track?
    let positionMs: Int
    let volume: Double?
    let quality: String?
    let codec: String?
    let queue: Queue?
}

enum APIError: LocalizedError {
    case noKey
    case http(Int)
    case badReply

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "Ключ сессии пока недоступен. Повторите подключение."
        case .http(let code):
            return "демон ответил \(code)"
        case .badReply:
            return "непонятный ответ демона"
        }
    }
}

struct APIClient {
    var base = URL(string: "http://127.0.0.1:8765")!

    var session: URLSession = .shared
    var sessionKey: (() -> String?)?

    /// Ключ лежит рядом с демоном: `~/Library/Application Support/ymd/run/session.key`.
    func key() -> String? {
        if let sessionKey { return sessionKey() }
        let fm = FileManager.default
        var candidates: [URL] = []
        if let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !runtime.isEmpty {
            candidates.append(URL(fileURLWithPath: runtime).appendingPathComponent("ymd/session.key"))
        }
        let support = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ymd/run/session.key")
        candidates.append(support)
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/ymd/session.key"))

        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.count >= 16 { return key }
            }
        }
        return nil
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let key = key() else { throw APIError.noKey }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 4
        req.setValue(key, forHTTPHeaderField: "X-YMD-Session")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func data(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let (data, response) = try await session.data(for: request(path, method: method, body: body))
        guard let http = response as? HTTPURLResponse else { throw APIError.badReply }
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode) }
        return data
    }

    func state() async throws -> PlayerState {
        try JSONDecoder().decode(PlayerState.self, from: await data("/v1/state"))
    }

    func probe() async -> DaemonProbe {
        var req = URLRequest(url: base.appendingPathComponent("/v1/health"))
        req.timeoutInterval = 0.5
        do {
            let (body, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let health = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  health["ok"] as? Bool == true else { return .conflict }
            var stateRequest = try request("/v1/state")
            stateRequest.timeoutInterval = 0.5
            let (stateData, stateResponse) = try await session.data(for: stateRequest)
            guard (stateResponse as? HTTPURLResponse)?.statusCode == 200,
                  (try? JSONDecoder().decode(PlayerState.self, from: stateData)) != nil else { return .conflict }
            return .available
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .absent
        } catch {
            return .conflict
        }
    }

    func account() async throws -> Account? {
        do { return try JSONDecoder().decode(Account.self, from: await data("/v1/account")) }
        catch APIError.http(401) {
            // Сначала проверяем ключ сессии, чтобы не спутать его с отсутствием входа.
            _ = try await state()
            return nil
        }
    }

    func deviceAuth(method: String = "GET") async throws -> DeviceAuth {
        try JSONDecoder().decode(DeviceAuth.self, from: await data("/v1/auth/device", method: method))
    }

    func command(_ op: String, payload: [String: Any]? = nil) async throws {
        var body: [String: Any] = ["op": op]
        if let payload { body["payload"] = payload }
        _ = try await data("/v1/cmd", method: "POST", body: body)
    }
}

struct Account: Decodable {
    let login: String
    let uid: UInt64
    let plus: Bool
    let backend: String
    let savedAt: UInt64
}

struct DeviceAuth: Decodable {
    let state: String
    let userCode: String
    let url: String
    let expiresIn: Int
    let login: String?
    let error: String?

    static func browserURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https",
              let host = url.host?.lowercased(),
              ["oauth.yandex.ru", "yandex.ru"].contains(host),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }
}
