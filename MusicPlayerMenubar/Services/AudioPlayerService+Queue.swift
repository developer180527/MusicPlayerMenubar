import Foundation
import AVFoundation

// Loop mode, moving through the queue, and what happens when a track ends.
extension AudioPlayerService {

    /// Drops a track from the pending queue.
    ///
    /// The queue is a snapshot taken when playback started, so deleting a track
    /// from the library otherwise leaves it there and playback walks into a
    /// file that no longer exists.
    func dropFromQueue(_ track: Track) {
        playlist.removeAll { $0.id == track.id }
    }

    func cycleLoopMode() {
        switch loopMode {
        case .off: loopMode = .all
        case .all: loopMode = .one
        case .one: loopMode = .off
        }
    }

    /// Advances to the next track.
    ///
    /// Returns whether the queue resolved the request — either by starting
    /// another track or by deliberately ending playback. `false` means the
    /// queue could say nothing about what comes next, which the caller must
    /// handle: leaving `isPlaying` set with no audio strands the UI showing a
    /// pause button and a playing menubar icon over silence.
    @discardableResult
    func playNext() -> Bool {
        guard let current = currentTrack,
              !playlist.isEmpty,
              let index = playlist.firstIndex(where: { $0.id == current.id })
        else { return false }

        let nextIndex = (index + 1) % playlist.count
        if loopMode == .off && nextIndex == 0 {
            stop()
            return true
        }
        play(track: playlist[nextIndex])
        return true
    }

    func playPrevious() {
        guard let current = currentTrack,
              !playlist.isEmpty,
              let index = playlist.firstIndex(where: { $0.id == current.id })
        else { return }

        let pos = player?.currentTime().seconds ?? savedPosition
        if pos.isFinite && pos > 3 {
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            savedPosition = 0
            // Rewinding without clearing these leaves the scrubber showing the
            // old position until the next observer tick.
            progress = 0
            currentTime = 0
            updateNowPlayingInfo()
            return
        }

        let prevIndex = index > 0 ? index - 1 : playlist.count - 1
        play(track: playlist[prevIndex])
    }

    func handlePlaybackEnd() {
        switch loopMode {
        case .one:
            restartCurrentItem()
        case .all:
            if !playNext() { stop() }
        case .off:
            let autoPlay = UserDefaults.standard.object(forKey: "autoPlayNext") as? Bool ?? true
            if autoPlay {
                if !playNext() { stop() }
            } else {
                stop()
            }
        }
    }
}
