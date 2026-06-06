import SwiftUI

@main
struct QuickMusicApp: App {

    @StateObject private var library = MusicLibraryService()
    @StateObject private var player = AudioPlayerService()

    var body: some Scene {
        MenuBarExtra {
            MusicMenuView()
                .environmentObject(library)
                .environmentObject(player)
                .onAppear {
                    library.loadLibrary()
                }
        } label: {
            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "music.note")
                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
        }
        .menuBarExtraStyle(.window)
    }
}
