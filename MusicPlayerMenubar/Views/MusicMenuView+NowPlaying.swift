import SwiftUI

// Current track, scrubber, transport controls and volume.
extension MusicMenuView {

    var nowPlayingSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                TrackArtworkView(track: player.currentTrack, size: 56)

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
}
