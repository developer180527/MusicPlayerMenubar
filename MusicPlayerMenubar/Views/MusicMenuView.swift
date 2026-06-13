import SwiftUI

struct MusicMenuView: View {

    @EnvironmentObject var library: MusicLibraryService
    @EnvironmentObject var player: AudioPlayerService
    @ObservedObject private var artworkCache = ArtworkCache.shared

    @State private var searchText = ""
    @State private var isHoveringVolume = false
    @State private var seekValue: Double?
    @State private var selectedTrackID: String?

    var filteredTracks: [Track] {
        if searchText.isEmpty {
            return library.tracks
        }
        return library.tracks.filter { track in
            fuzzyMatch(searchText, in: track.title)
            || fuzzyMatch(searchText, in: track.artist)
            || fuzzyMatch(searchText, in: track.album)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            nowPlayingSection
            statusBanner
            Divider()
            librarySection
            Divider()
            bottomBar
        }
        .frame(width: 340, height: 580)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            guard selectedTrackID != nil else { return .ignored }
            playSelectedTrack()
            return .handled
        }
        .onKeyPress(keys: [.delete], phases: .down) { press in
            guard press.modifiers.contains(.command),
                  selectedTrackID != nil else { return .ignored }
            removeSelectedTrack()
            return .handled
        }
    }

    // MARK: - Status Banner

    @ViewBuilder
    private var statusBanner: some View {
        if let error = player.playbackError {
            statusPill(error, color: .red)
        } else if let removed = library.lastRemoved {
            HStack {
                Text("Removed \"\(removed.track.title)\"")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Button("Undo") {
                    library.undoRemove()
                }
                .font(.system(size: 11, weight: .bold))
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.85))
        } else if let message = library.statusMessage {
            statusPill(message, color: .orange)
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.85))
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: text)
    }

    // MARK: - Now Playing

    private var nowPlayingSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                artworkView(for: player.currentTrack, size: 56)

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
                    get: { seekValue ?? player.progress },
                    set: { seekValue = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    player.isSeeking = editing
                    if !editing, let value = seekValue {
                        player.seek(to: value)
                        seekValue = nil
                    }
                }
            )
            .controlSize(.mini)

            HStack {
                Text(AudioPlayerService.formatTime(
                    seekValue != nil ? (seekValue! * player.duration) : player.currentTime
                ))
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
                    .onSubmit {
                        if let track = filteredTracks.first {
                            player.play(track: track, playlist: filteredTracks)
                        }
                    }
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredTracks) { track in
                                trackRow(track)
                                    .id(track.id)
                                if track.id != filteredTracks.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .onChange(of: selectedTrackID) { _, newID in
                        if let id = newID {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 0) {
            Button {
                player.play(track: track, playlist: filteredTracks)
            } label: {
                HStack(spacing: 10) {
                    artworkView(for: track, size: 36)

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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                library.removeTrack(track)
                if player.currentTrack?.id == track.id {
                    player.stop()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from library")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(trackBackground(track))
    }

    private func trackBackground(_ track: Track) -> Color {
        let isSelected = selectedTrackID == track.id
        let isPlaying = player.currentTrack?.id == track.id
        if isSelected && isPlaying {
            return Color.accentColor.opacity(0.15)
        } else if isSelected {
            return Color.secondary.opacity(0.12)
        } else if isPlaying {
            return Color.accentColor.opacity(0.08)
        }
        return Color.clear
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
                AppDelegate.shared.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

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

    // MARK: - Keyboard Navigation

    private func moveSelection(by offset: Int) {
        let tracks = filteredTracks
        guard !tracks.isEmpty else { return }

        if let currentID = selectedTrackID,
           let currentIndex = tracks.firstIndex(where: { $0.id == currentID }) {
            let newIndex = max(0, min(tracks.count - 1, currentIndex + offset))
            selectedTrackID = tracks[newIndex].id
        } else {
            selectedTrackID = offset > 0 ? tracks.first?.id : tracks.last?.id
        }
    }

    private func playSelectedTrack() {
        guard let id = selectedTrackID,
              let track = filteredTracks.first(where: { $0.id == id })
        else { return }
        player.play(track: track, playlist: filteredTracks)
    }

    private func removeSelectedTrack() {
        guard let id = selectedTrackID,
              let track = filteredTracks.first(where: { $0.id == id })
        else { return }

        let tracks = filteredTracks
        let nextID: String?
        if let index = tracks.firstIndex(where: { $0.id == id }) {
            if index + 1 < tracks.count {
                nextID = tracks[index + 1].id
            } else if index > 0 {
                nextID = tracks[index - 1].id
            } else {
                nextID = nil
            }
        } else {
            nextID = nil
        }

        if player.currentTrack?.id == track.id {
            player.stop()
        }
        library.removeTrack(track)
        selectedTrackID = nextID
    }

    // MARK: - Fuzzy Search

    private func fuzzyMatch(_ query: String, in text: String) -> Bool {
        let query = query.lowercased()
        let text = text.lowercased()

        if text.contains(query) { return true }

        var queryIndex = query.startIndex
        for char in text {
            if queryIndex == query.endIndex { break }
            if char == query[queryIndex] {
                queryIndex = query.index(after: queryIndex)
            }
        }
        return queryIndex == query.endIndex
    }

    // MARK: - Helpers

    private func artworkView(for track: Track?, size: CGFloat) -> some View {
        Group {
            if let track, let image = artworkCache.thumbnail(for: track, size: size) {
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
