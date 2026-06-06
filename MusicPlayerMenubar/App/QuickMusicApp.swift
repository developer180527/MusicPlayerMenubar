import SwiftUI

@main
struct QuickMusicApp: App {

    @StateObject private var library = MusicLibraryService()
    @StateObject private var player = AudioPlayerService()

    var body: some Scene {
        MenuBarExtra("Music", systemImage: "music.note") {
            MusicMenuView()
                .environmentObject(library)
                .environmentObject(player)
                .onAppear {
                    library.loadLibrary()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
