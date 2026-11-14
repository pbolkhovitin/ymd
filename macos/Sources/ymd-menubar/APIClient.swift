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
            return "нет ключа сессии — запустите ymd serve"
        case .http(let code):
            return "демон ответил \(code)"
        case .badReply:
            return "непонятный ответ демона"
        }
    }
}

struct APIClient {
    var base = URL(string: "http://127.0.0.1:8765")!

    /// Ключ лежит рядом с демоном: `~/Library/Application Support/ymd/run/session.key`.
    func key() -> String? {
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

    func state() async throws -> PlayerState {
        let req = try request("/v1/state")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badReply }
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(PlayerState.self, from: data)
        } catch {
            throw APIError.badReply
        }
    }

    func command(_ op: String, payload: [String: Any]? = nil) async throws {
        var body: [String: Any] = ["op": op]
        if let payload { body["payload"] = payload }
        let req = try request("/v1/cmd", method: "POST", body: body)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}
