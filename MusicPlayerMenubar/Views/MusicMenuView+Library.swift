import SwiftUI

// Search field, the track list, and the rows in it.
extension MusicMenuView {

    var librarySection: some View {
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
                    // Resolve the filter once per render. `filteredTracks` is
                    // computed, so reading it inside the row body reran the
                    // whole fuzzy search for every row that materialized.
                    let tracks = filteredTracks
                    let lastID = tracks.last?.id
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(tracks) { track in
                                trackRow(track)
                                    .id(track.id)
                                if track.id != lastID {
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
                    TrackArtworkView(track: track, size: 36)

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
                player.dropFromQueue(track)
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
}
