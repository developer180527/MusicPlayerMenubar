import Foundation
import AppKit

// The scan folders listed in Settings.
//
// These are the subset of granted roots the user designated for rescanning.
// The stored paths are only an index — the authority to open them comes from
// the bookmark `SecurityScopedStore` holds.
extension MusicLibraryService {

    private static var foldersKey: String { "customScanFolders" }

    func loadCustomFolders() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? []
        let store = SecurityScopedStore.shared
        customFolders = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { store.isCovered($0) }

        // A folder whose bookmark no longer resolves can never be scanned, so
        // drop it instead of leaving a dead row in Settings.
        if customFolders.count != paths.count {
            saveCustomFolders()
        }
    }

    func addCustomFolder() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select folders to scan for music"
        panel.level = .floating

        guard panel.runModal() == .OK else { return }

        let existing = Set(customFolders.map { $0.path })
        var newFolders: [URL] = []
        var ungranted = 0
        for url in panel.urls where !existing.contains(url.path) {
            if SecurityScopedStore.shared.addRoot(url) {
                newFolders.append(url)
            } else {
                ungranted += 1
            }
        }

        if ungranted > 0 {
            showStatus("\(ungranted) folder\(ungranted == 1 ? "" : "s") couldn't be added")
        }
        guard !newFolders.isEmpty else { return }
        customFolders.append(contentsOf: newFolders)
        saveCustomFolders()
    }

    func removeCustomFolder(_ folder: URL) {
        customFolders.removeAll { $0 == folder }
        saveCustomFolders()

        // Keep the underlying grant when tracks still live inside this folder.
        // Removing it from the scan list shouldn't make those tracks unplayable.
        let prefix = folder.standardizedFileURL.path + "/"
        let stillNeeded = tracks.contains {
            $0.url.standardizedFileURL.path.hasPrefix(prefix)
        }
        if !stillNeeded {
            SecurityScopedStore.shared.removeRoot(folder)
        }
    }

    func scanCustomFolders() {
        let valid = customFolders.filter { (try? $0.checkResourceIsReachable()) == true }
        guard !valid.isEmpty else {
            showStatus("No valid folders to scan")
            return
        }
        importURLs(valid)
    }

    private func saveCustomFolders() {
        let paths = customFolders.map { $0.path }
        UserDefaults.standard.set(paths, forKey: Self.foldersKey)
    }
}
