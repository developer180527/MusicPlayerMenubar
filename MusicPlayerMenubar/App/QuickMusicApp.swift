import SwiftUI
import Combine

@main
struct QuickMusicApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let library = MusicLibraryService()
    private let player = AudioPlayerService()
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hostingView = NSHostingView(
            rootView: MusicMenuView()
                .environmentObject(library)
                .environmentObject(player)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 580)

        let viewController = NSViewController()
        viewController.view = hostingView

        popover.contentViewController = viewController
        popover.contentSize = NSSize(width: 340, height: 580)
        popover.behavior = .transient
        popover.delegate = self

        library.loadLibrary()

        cancellable = player.$isPlaying.receive(on: RunLoop.main).sink { [weak self] isPlaying in
            guard let button = self?.statusItem.button else { return }
            let name = isPlaying ? "waveform" : "music.note"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Music")
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
