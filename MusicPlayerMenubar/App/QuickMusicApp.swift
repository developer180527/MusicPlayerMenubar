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

    static private(set) var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let library = MusicLibraryService()
    private let player = AudioPlayerService()
    private var cancellable: AnyCancellable?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        statusItem = NSStatusBar.system.statusItem(withLength: 28)

        if let button = statusItem.button {
            button.image = Self.menubarIcon(playing: false)
            button.imagePosition = .imageOnly
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
        library.loadCustomFolders()

        cancellable = player.$isPlaying.receive(on: RunLoop.main).sink { [weak self] isPlaying in
            guard let button = self?.statusItem.button else { return }
            button.image = Self.menubarIcon(playing: isPlaying)
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

    private static func menubarIcon(playing: Bool) -> NSImage? {
        let name = playing ? "waveform" : "music.note"
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Music")?
            .withSymbolConfiguration(config) else { return nil }

        // Draw into a fixed-size canvas so both icons have identical bounds
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let symbolSize = symbol.size
            let x = (rect.width - symbolSize.width) / 2
            let y = (rect.height - symbolSize.height) / 2
            symbol.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    func openSettings() {
        popover.performClose(nil)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .environmentObject(library)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }
}
