import SwiftUI

// Arrow / return / command-delete handling, and the matcher the search uses.
extension MusicMenuView {

    func moveSelection(by offset: Int) {
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

    func playSelectedTrack() {
        guard let id = selectedTrackID,
              let track = filteredTracks.first(where: { $0.id == id })
        else { return }
        player.play(track: track, playlist: filteredTracks)
    }

    func removeSelectedTrack() {
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
        player.dropFromQueue(track)
        selectedTrackID = nextID
    }

    /// Subsequence match, with a fast path for a plain substring hit.
    ///
    /// `text` is expected to be one of `Track`'s precomputed lowercase fields
    /// and `query` already lowercased, so neither is folded here.
    func fuzzyMatch(_ query: String, in text: String) -> Bool {
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
}
