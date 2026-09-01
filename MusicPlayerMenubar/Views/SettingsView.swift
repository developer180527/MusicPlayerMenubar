import SwiftUI
import ServiceManagement

struct SettingsView: View {

    @EnvironmentObject var library: MusicLibraryService
    @EnvironmentObject var player: AudioPlayerService

    @State private var startAtLogin = SettingsView.isLoginItemRegistered
    @State private var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var autoPlayNext = UserDefaults.standard.object(forKey: "autoPlayNext") as? Bool ?? true
    @State private var showClearConfirmation = false

    /// Version as reported by the bundle itself, so it can't disagree with what
    /// was actually shipped.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        guard let build, build != short else { return short }
        return "\(short) (\(build))"
    }

    /// Whether the app is registered as a login item.
    ///
    /// `register()` usually lands on `.requiresApproval` rather than `.enabled`,
    /// because macOS asks the user to confirm in System Settings. Treating only
    /// `.enabled` as on made the toggle spring back off after a successful
    /// registration, with nothing explaining why.
    private static var isLoginItemRegistered: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    var body: some View {
        Form {
            Section("General") {
                // A plain binding plus .onChange would also fire when the value
                // is refreshed programmatically, so merely opening this window
                // could register or unregister the login item. A custom setter
                // runs only on real interaction.
                Toggle("Start at login", isOn: Binding(
                    get: { startAtLogin },
                    set: { newValue in
                        try? newValue
                            ? SMAppService.mainApp.register()
                            : SMAppService.mainApp.unregister()
                        refreshLoginState()
                    }
                ))

                if loginNeedsApproval {
                    Text("Approve MusicPlayerMenubar in System Settings → General → Login Items to finish enabling this.")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Self.appVersion)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 460)
        .alert("Clear Library?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                // Playback and the queue outlive the library otherwise: the
                // track keeps playing, Now Playing stays populated, and the
                // queue pins every Track from the library just cleared.
                player.stop()
                library.clearLibrary()
            }
        } message: {
            Text("This will remove all \(library.tracks.count) tracks from your library. Audio files on disk won't be deleted.")
        }
        .onAppear {
            refreshLoginState()
            autoPlayNext = UserDefaults.standard.object(forKey: "autoPlayNext") as? Bool ?? true
        }
    }

    private func refreshLoginState() {
        startAtLogin = Self.isLoginItemRegistered
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
}
