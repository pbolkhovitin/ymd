import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: PlayerState?
    @Published private(set) var errorText: String?
    @Published private(set) var busy = false

    @Published private(set) var connection: DaemonSupervisor.Phase = .stopped
    @Published private(set) var account: Account?
    @Published private(set) var auth: DeviceAuth?
    @Published private(set) var authBusy = false
    @Published private(set) var authCancelling = false
    @Published private(set) var authError: String?
    private let api: APIClient
    private let supervisor: DaemonSupervisor
    private var startup: Task<Void, Never>?
    private var startupGeneration = UUID()
    private var authTask: Task<Void, Never>?
    private var refreshing = false
    private var connectionGeneration = UUID()
    private var started = false
    private var terminationObserver: NSObjectProtocol?

    private var timer: Timer?

    init(api: APIClient = APIClient(), supervisor: DaemonSupervisor? = nil) {
        self.api = api
        self.supervisor = supervisor ?? DaemonSupervisor { await api.probe() }
        self.supervisor.onChange = { [weak self] phase in
            self?.connectionGeneration = UUID()
            self?.connection = phase
            if phase != .ready { self?.timer?.invalidate(); self?.timer = nil }
            if case .failed(let message) = phase { self?.errorText = message }
        }
    }

    var iconName: String {
        switch state?.status {
        case "playing": return "pause.circle.fill"
        case "paused": return "play.circle.fill"
        default: return "music.note"
        }
    }

    /// В баре показываем «Трек — артист», обрезая длинные названия.
    var menuTitle: String {
        guard let track = state?.track else { return "" }
        let artist = track.artists.first ?? ""
        let line = artist.isEmpty ? track.title : "\(track.title) — \(artist)"
        return line.count > 28 ? String(line.prefix(27)) + "…" : line
    }

    var isPlaying: Bool { state?.status == "playing" }
    var shuffle: Bool { state?.queue?.shuffle ?? false }
    var repeatMode: String { state?.queue?.repeatMode ?? "off" }

    var repeatLabel: String {
        switch repeatMode {
        case "one": return "1"
        case "all": return "∞"
        default: return "→"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        connect()
    }

    func connect() {
        guard startup == nil else { return }
        let attempt = UUID()
        startupGeneration = attempt
        startup = Task {
            defer { if startupGeneration == attempt { startup = nil } }
            await supervisor.start()
            guard startupGeneration == attempt, !Task.isCancelled, connection == .ready else { return }
            let generation = connectionGeneration
            await refresh()
            await refreshAccount()
            guard startupGeneration == attempt, connection == .ready, connectionGeneration == generation else { return }
            schedule()
        }
    }

    func stop() {
        startupGeneration = UUID()
        startup?.cancel()
        startup = nil
        authTask?.cancel()
        authTask = nil
        timer?.invalidate()
        timer = nil
        supervisor.stop()
    }

    func refreshAccount() async {
        guard connection == .ready else { return }
        let generation = connectionGeneration
        do {
            let fresh = try await api.account()
            guard connection == .ready, connectionGeneration == generation else { return }
            account = fresh
        } catch {
            guard connection == .ready, connectionGeneration == generation else { return }
            errorText = error.localizedDescription
            if (error as? URLError)?.code == .cannotConnectToHost { supervisor.connectionLost() }
        }
    }

    func login() {
        guard authTask == nil, account == nil else { return }
        authError = nil
        authCancelling = false
        authBusy = true
        authTask = Task {
            defer { authBusy = false; authCancelling = false; authTask = nil }
            do {
                let flow: DeviceAuth
                do { flow = try await api.deviceAuth(method: "POST") }
                catch APIError.http(409) { flow = try await api.deviceAuth() }
                try Task.checkCancellation()
                if authCancelling {
                    _ = try await api.deviceAuth(method: "DELETE")
                    return
                }
                auth = flow
                if flow.state == "pending" {
                    guard let url = DeviceAuth.browserURL(flow.url) else { throw APIError.badReply }
                    NSWorkspace.shared.open(url)
                }
                let deadline = Date().addingTimeInterval(TimeInterval(max(1, flow.expiresIn)))
                while !Task.isCancelled {
                    guard Date() < deadline else {
                        authError = "Срок действия кода истёк. Начните вход заново."
                        auth = nil
                        return
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if authCancelling {
                        _ = try await api.deviceAuth(method: "DELETE")
                        return
                    }
                    let fresh = try await api.deviceAuth()
                    try Task.checkCancellation()
                    if authCancelling {
                        _ = try await api.deviceAuth(method: "DELETE")
                        return
                    }
                    auth = fresh
                    switch fresh.state {
                    case "authorized":
                        auth = nil
                        await refreshAccount()
                        await refresh()
                        return
                    case "pending": continue
                    case "expired": authError = "Срок действия кода истёк. Начните вход заново."
                    case "cancelled", "idle": authError = "Вход отменён."
                    default: authError = fresh.error ?? "Не удалось войти. Повторите попытку."
                    }
                    auth = nil
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                authError = error.localizedDescription
                auth = nil
            }
        }
    }

    func cancelLogin() {
        // DELETE отправляется после завершения POST: иначе поздний POST снова начнёт вход.
        authCancelling = true
        auth = nil
    }

    func openLoginPage() {
        if let value = auth?.url, let url = DeviceAuth.browserURL(value) { NSWorkspace.shared.open(url) }
    }

    func copyLoginCode() {
        guard let code = auth?.userCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = isPlaying ? 1 : 3
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func reload() {
        if connection == .ready {
            Task {
                await refresh()
                if connection == .ready { await refreshAccount() }
                else { connect() }
            }
        } else { connect() }
    }

    func refresh() async {
        guard !refreshing, connection == .ready else { return }
        refreshing = true
        let generation = connectionGeneration
        defer { refreshing = false }
        do {
            let fresh = try await api.state()
            guard connection == .ready, connectionGeneration == generation else { return }
            let wasPlaying = isPlaying
            state = fresh
            errorText = nil
            if wasPlaying != isPlaying { schedule() }
        } catch {
            guard connection == .ready, connectionGeneration == generation else { return }
            errorText = error.localizedDescription
            if isPlaying { state = nil }
            if (error as? URLError)?.code == .cannotConnectToHost { supervisor.connectionLost() }
        }
    }

    func send(_ op: String, payload: [String: Any]? = nil) {
        guard !busy, connection == .ready else { return }
        busy = true
        let generation = connectionGeneration
        Task {
            do {
                try await api.command(op, payload: payload)
                if connection == .ready, connectionGeneration == generation { await refresh() }
            } catch {
                if connection == .ready, connectionGeneration == generation { errorText = error.localizedDescription }
            }
            busy = false
        }
    }

    func toggle() { send("toggle") }
    func next() { send("next") }
    func previous() { send("prev") }
    func like() { send("like") }

    func cycleRepeat() {
        let order = ["off", "all", "one"]
        let index = order.firstIndex(of: repeatMode) ?? 0
        send("repeat", payload: ["value": order[(index + 1) % order.count]])
    }

    func toggleShuffle() {
        send("shuffle", payload: ["value": !shuffle])
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }
}

func timecode(_ ms: Int) -> String {
    let total = max(0, ms / 1000)
    return String(format: "%d:%02d", total / 60, total % 60)
}
