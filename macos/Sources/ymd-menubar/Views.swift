import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state = model.state, let track = state.track {
                header(track)
                progress(state)
                transport
                modes
            } else {
                unavailable
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private func header(_ track: PlayerState.Track) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CoverView(url: track.cover)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(track.artists.joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let album = track.album, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let quality = model.state?.quality {
                    Text(qualityLabel(quality))
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func progress(_ state: PlayerState) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: min(1, max(0, Double(state.positionMs) / Double(duration(state)))))
                .progressViewStyle(.linear)
            HStack {
                Text(timecode(state.positionMs))
                Spacer()
                Text(timecode(duration(state)))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Spacer()
            Button { model.previous() } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)

            Button { model.toggle() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            Button { model.next() } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .disabled(model.busy)
    }

    private var modes: some View {
        HStack(spacing: 14) {
            Button { model.cycleRepeat() } label: {
                Label(model.repeatLabel, systemImage: "repeat")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.repeatMode == "off" ? Color.secondary : Color.accentColor)

            Button { model.toggleShuffle() } label: {
                Image(systemName: "shuffle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.shuffle ? Color.accentColor : Color.secondary)

            Spacer()

            Button { model.like() } label: {
                Image(systemName: "heart")
            }
            .buttonStyle(.borderless)
            .help("Мне нравится")
        }
        .font(.system(size: 13))
        .disabled(model.busy)
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ничего не играет")
                .font(.system(size: 14, weight: .semibold))
            Text(model.errorText ?? "Запустите ymd serve и включите трек.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button("Обновить") { model.reload() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Выход") { model.quit() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func duration(_ state: PlayerState) -> Int {
        max(1, state.track?.durationMs ?? 1)
    }

    private func qualityLabel(_ quality: String) -> String {
        switch quality {
        case "lossless": return "FLAC"
        case "hq": return "AAC 256"
        case "nq": return "AAC 192"
        case "lq": return "AAC 64"
        case "cache": return "кэш"
        default: return quality.uppercased()
        }
    }
}

private struct CoverView: View {
    let url: String?

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
            } else {
                Color.secondary.opacity(0.15)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
