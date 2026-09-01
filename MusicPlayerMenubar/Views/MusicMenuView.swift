import SwiftUI

/// The popover's root view.
///
/// Sections live in sibling files, as extensions on this type:
///
/// - `+NowPlaying`: artwork, titles, scrubber, transport, volume
/// - `+Library`: search field, track list, rows
/// - `+Chrome`: status banner and bottom bar
/// - `+Keyboard`: arrow/return/delete handling and the fuzzy match
///
/// Those files reach the state declared here, so it can't be `private`, which
/// Swift scopes to a single file.
struct MusicMenuView: View {

    @EnvironmentObject var library: MusicLibraryService
    @EnvironmentObject var player: AudioPlayerService

    @State var searchText = ""
    @State var isHoveringVolume = false
    @State var seekValue: Double?
    @State var selectedTrackID: String?

    var filteredTracks: [Track] {
        if searchText.isEmpty {
            return library.tracks
        }
        let query = searchText.lowercased()
        return library.tracks.filter { track in
            fuzzyMatch(query, in: track.searchTitle)
            || fuzzyMatch(query, in: track.searchArtist)
            || fuzzyMatch(query, in: track.searchAlbum)
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
}
