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

                Button("Clear Library") {
                    showClearConfirmation = true
                }
                .foregroundStyle(.red)
            }

            Section("Scan Folders") {
                if library.customFolders.isEmpty {
                    Text("No folders added. Add folders to quickly scan for music.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.customFolders, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(folder.lastPathComponent)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Text(folder.path)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                library.removeCustomFolder(folder)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Button("Add Folder...") {
                        library.addCustomFolder()
                    }
                    Spacer()
                    Button("Scan All") {
                        library.scanCustomFolders()
                    }
                    .disabled(library.customFolders.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 460)
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
