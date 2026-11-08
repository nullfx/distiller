import AppKit
import Foundation
import DistillerCommunity
import DistillerCore

/// Where Wine builds and bottles live, and moving them between drives.
extension AppModel {
    var storageConfirmed: Bool { engine?.paths.storage.locationsConfirmed == true }

    func location(of kind: StorageKind) -> URL? {
        engine?.paths.location(of: kind)
    }

    /// The drive bottles are on, for comparing with a game folder's drive.
    var bottlesVolume: StorageVolume? {
        guard let engine else { return nil }
        return StorageVolume(containing: engine.paths.bottles)
    }

    func confirmStorageLocations() {
        guard let engine else { return }
        do {
            try DistillerEngine.confirmStorageLocations(paths: engine.paths)
            restartEngine()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Asks for a new folder for `kind`, then moves what's there after confirming.
    func chooseStorageLocation(_ kind: StorageKind) {
        guard let engine else { return }
        guard running.isEmpty else {
            errorMessage = "Quit your running games before moving \(kind.displayName.lowercased())."
            return
        }
        let panel = NSOpenPanel()
        panel.message = "Choose where Distiller keeps \(kind.displayName.lowercased()). Choosing a drive puts them in a Distiller folder on it."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = engine.paths.location(of: kind)
        guard panel.runModal() == .OK, let choice = panel.url else { return }

        let destination = StorageSettings.storageFolder(forChoice: choice)
        guard let volume = StorageVolume(containing: destination) else {
            errorMessage = "\(destination.path) isn't on a connected drive."
            return
        }
        if !volume.problems.isEmpty {
            errorMessage = volume.problems.joined(separator: "\n\n")
            return
        }

        let paths = engine.paths
        perform("Checking what's in \(kind.displayName.lowercased())…") {
            let bytes = await Task.detached {
                kind.folderNames.reduce(Int64(0)) { $0 + DistillerEngine.allocatedSize(of: paths.location(of: kind).appendingPathComponent($1)) }
            }.value
            if bytes > 50_000_000 && !self.confirmMove(kind, bytes: bytes, to: volume, destination: destination, from: paths) {
                return
            }
            self.busyMessage = "Moving \(kind.displayName.lowercased())…"
            _ = try await Task.detached {
                try await DistillerEngine.moveStorage(kind, to: choice, paths: paths) { step in
                    Task { @MainActor in self.busyMessage = step.message }
                }
            }.value
            self.restartEngine()
        }
    }

    private func confirmMove(_ kind: StorageKind, bytes: Int64, to volume: StorageVolume, destination: URL, from paths: DistillerPaths) -> Bool {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let sameDrive = StorageVolume(containing: paths.location(of: kind))?.root == volume.root
        let alert = NSAlert()
        alert.messageText = "Move \(size) of \(kind.displayName.lowercased()) to “\(volume.name)”?"
        alert.informativeText = sameDrive
            ? "They move to \(destination.path). This is quick on the same drive."
            : "Distiller copies them to \(destination.path), then deletes the originals. Keep the drive connected and don't start games until it finishes."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Size and drive of a game folder, for the copy-or-link choice.
    func describeFolder(_ url: URL) async -> (bytes: Int64, volume: StorageVolume?) {
        await Task.detached { (DistillerEngine.allocatedSize(of: url), StorageVolume(containing: url)) }.value
    }
}
