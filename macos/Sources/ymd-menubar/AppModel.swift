import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: PlayerState?
    @Published private(set) var errorText: String?
    @Published private(set) var busy = false

    private let api = APIClient()
    private var timer: Timer?

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
        Task { await refresh() }
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = isPlaying ? 1 : 3
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func reload() {
        Task { await refresh() }
    }

    func refresh() async {        do {
            let fresh = try await api.state()
            let wasPlaying = isPlaying
            state = fresh
            errorText = nil
            if wasPlaying != isPlaying { schedule() }
        } catch {
            errorText = error.localizedDescription
            if isPlaying { state = nil }
        }
    }

    func send(_ op: String, payload: [String: Any]? = nil) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await api.command(op, payload: payload)
                await refresh()
            } catch {
                errorText = error.localizedDescription
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
        NSApplication.shared.terminate(nil)
    }
}

func timecode(_ ms: Int) -> String {
    let total = max(0, ms / 1000)
    return String(format: "%d:%02d", total / 60, total % 60)
}
