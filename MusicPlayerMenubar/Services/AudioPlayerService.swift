import Foundation
import AVFoundation
import Combine

enum LoopMode: CaseIterable {
    case off
    case one
    case all

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .off: return "Loop Off"
        case .all: return "Loop All"
        case .one: return "Loop One"
        }
    }
}

@MainActor
final class AudioPlayerService: NSObject, ObservableObject {

    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 0.7
    @Published var loopMode: LoopMode = .off
    @Published var playbackError: String?
    var isSeeking = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var playlist: [Track] = []

    func play(track: Track, playlist: [Track] = []) {
        playbackError = nil

        guard (try? track.url.checkResourceIsReachable()) == true else {
            showError("File not found: \(track.title)")
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: track.url)
            player?.delegate = self
            player?.volume = volume
            player?.prepareToPlay()
            player?.play()

            currentTrack = track
            isPlaying = true
            duration = player?.duration ?? track.duration
            if !playlist.isEmpty {
                self.playlist = playlist
            }

            startTimer()
        } catch {
            showError("Can't play: \(track.title)")
        }
    }

    private func showError(_ message: String) {
        playbackError = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if playbackError == message {
                playbackError = nil
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        player?.play()
        isPlaying = true
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTrack = nil
        progress = 0
        currentTime = 0
        duration = 0
        timer?.invalidate()
    }

    func seek(to progress: Double) {
        guard let player else { return }
        let targetTime = player.duration * progress
        player.currentTime = targetTime
        self.progress = progress
        self.currentTime = targetTime
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        player?.volume = newVolume
    }

    func cycleLoopMode() {
        switch loopMode {
        case .off: loopMode = .all
        case .all: loopMode = .one
        case .one: loopMode = .off
        }
    }

    func playNext() {
        guard let current = currentTrack,
              !playlist.isEmpty,
              let index = playlist.firstIndex(where: { $0.id == current.id })
        else { return }

        let nextIndex = (index + 1) % playlist.count
        if loopMode == .off && nextIndex == 0 {
            stop()
            return
        }
        play(track: playlist[nextIndex])
    }

    func playPrevious() {
        guard let current = currentTrack,
              !playlist.isEmpty,
              let index = playlist.firstIndex(where: { $0.id == current.id })
        else { return }

        if let player, player.currentTime > 3 {
            player.currentTime = 0
            return
        }

        let prevIndex = index > 0 ? index - 1 : playlist.count - 1
        play(track: playlist[prevIndex])
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if player.duration > 0 && !self.isSeeking {
                    self.progress = player.currentTime / player.duration
                    self.currentTime = player.currentTime
                }
                if !player.isPlaying && self.isPlaying {
                    self.isPlaying = false
                }
            }
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}

extension AudioPlayerService: AVAudioPlayerDelegate {

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor in
            switch loopMode {
            case .one:
                if let track = currentTrack {
                    play(track: track)
                }
            case .all:
                playNext()
            case .off:
                playNext()
            }
        }
    }
}
