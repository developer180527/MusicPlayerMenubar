import SwiftUI

// The transient banner above the list, and the toolbar below it.
extension MusicMenuView {

    @ViewBuilder
    var statusBanner: some View {
        if let error = player.playbackError {
            statusPill(error, color: .red)
        } else if let removed = library.lastRemoved {
            HStack {
                Text("Removed \"\(removed.track.title)\"")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Button("Undo") {
                    library.undoRemove()
                }
                .font(.system(size: 11, weight: .bold))
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.85))
        } else if let message = library.statusMessage {
            statusPill(message, color: .orange)
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.85))
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: text)
    }

    var bottomBar: some View {
        HStack {
            Button { library.addFiles() } label: {
                Label("Add Music", systemImage: "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            if !library.tracks.isEmpty {
                Text("\(library.tracks.count) tracks")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                AppDelegate.shared.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
