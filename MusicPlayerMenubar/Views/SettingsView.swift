import SwiftUI
import ServiceManagement

struct SettingsView: View {

    @EnvironmentObject var library: MusicLibraryService

    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoPlayNext = UserDefaults.standard.object(forKey: "autoPlayNext") as? Bool ?? true
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            startAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

                Toggle("Auto-play next track", isOn: $autoPlayNext)
                    .onChange(of: autoPlayNext) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "autoPlayNext")
                    }

                Text("When off, playback stops after each track finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Library") {
                HStack {
                    Text("\(library.tracks.count) tracks in library")
                    Spacer()
                }

                Button("Add Music...") {
                    library.addFiles()
                }

                Button("Scan Music Folder") {
                    library.scanMusicFolder()
                }

                Text("Imports all audio files from ~/Music.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear Library") {
                    showClearConfirmation = true
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 340)
        .alert("Clear Library?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                library.clearLibrary()
            }
        } message: {
            Text("This will remove all \(library.tracks.count) tracks from your library. Audio files on disk won't be deleted.")
        }
        .onAppear {
            startAtLogin = SMAppService.mainApp.status == .enabled
            autoPlayNext = UserDefaults.standard.object(forKey: "autoPlayNext") as? Bool ?? true
        }
    }
}
