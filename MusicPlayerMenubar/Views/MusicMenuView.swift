import SwiftUI

struct MusicMenuView: View {

    @EnvironmentObject var library: MusicLibraryService
    @EnvironmentObject var player: AudioPlayerService

    @State private var searchText = ""
    @State private var isHoveringVolume = false

    var filteredTracks: [Track] {
        if searchText.isEmpty {
            return library.tracks
        }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
            || $0.artist.localizedCaseInsensitiveContains(searchText)
            || $0.album.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            nowPlayingSection
            Divider()
            librarySection
            Divider()
            bottomBar
        }
        .frame(width: 340, height: 480)
    }

    // MARK: - Now Playing

    private var nowPlayingSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                artworkView(
                    image: player.currentTrack?.artwork,
                    size: 56
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentTrack?.title ?? "No Track Selected")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Text(player.currentTrack?.artist ?? "—")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let album = player.currentTrack?.album,
                       !album.isEmpty, album != "Unknown Album" {
                        Text(album)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }

            progressSection

            controlsRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var progressSection: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { player.progress },
                    set: { player.seek(to: $0) }
                )
            )
            .controlSize(.mini)

            HStack {
                Text(AudioPlayerService.formatTime(player.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                Spacer()
                Text(AudioPlayerService.formatTime(player.duration))
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 0) {
            loopButton
            Spacer()
            transportControls
            Spacer()
            volumeControl
        }
    }

    private var loopButton: some View {
        Button {
            player.cycleLoopMode()
        } label: {
            Image(systemName: player.loopMode.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(player.loopMode == .off ? Color.secondary : Color.accentColor)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(player.loopMode.label)
    }

    private var transportControls: some View {
        HStack(spacing: 20) {
            Button { player.playPrevious() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16))
            }

            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
            }

            Button { player.playNext() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
            }
        }
        .buttonStyle(.plain)
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: volumeIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            if isHoveringVolume {
                Slider(
                    value: Binding(
                        get: { Double(player.volume) },
                        set: { player.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .controlSize(.mini)
                .frame(width: 60)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: isHoveringVolume ? 78 : 28, height: 28)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHoveringVolume = hovering
            }
        }
    }

    private var volumeIcon: String {
        if player.volume == 0 { return "speaker.slash.fill" }
        if player.volume < 0.33 { return "speaker.wave.1.fill" }
        if player.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Library

    private var librarySection: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search music...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))

            Divider()

            if library.isScanning {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning library...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredTracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text(library.tracks.isEmpty ? "No music found" : "No results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if library.tracks.isEmpty {
                        Button("Add Music...") {
                            library.addFiles()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredTracks) { track in
                            trackRow(track)
                            if track.id != filteredTracks.last?.id {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func trackRow(_ track: Track) -> some View {
        Button {
            player.play(track: track, playlist: filteredTracks)
        } label: {
            HStack(spacing: 10) {
                artworkView(image: track.artwork, size: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if track.duration > 0 {
                    Text(AudioPlayerService.formatTime(track.duration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                if player.currentTrack?.id == track.id {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            player.currentTrack?.id == track.id
            ? Color.accentColor.opacity(0.08)
            : Color.clear
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Button { library.addFiles() } label: {
                Label("Add Music", systemImage: "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            if !library.tracks.isEmpty {
                Text("\(library.tracks.count) tracks")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func artworkView(image: NSImage?, size: CGFloat) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
    }
}
