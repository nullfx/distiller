import AppKit
import Foundation
import UniformTypeIdentifiers
import DistillerCore

/// Game availability (a disconnected drive, a moved folder) and icons for the library.
extension AppModel {
    /// Re-checks every game and loads icons. Runs on each reload, which also happens when a
    /// drive is connected or disconnected and when the app comes to the front.
    func refreshLibraryState() {
        guard let engine else { return }
        var availability: [String: GameAvailability] = [:]
        var toRead: [Game] = []
        for game in games {
            let state = engine.availability(of: game)
            availability[game.id] = state
            let source = resolved(game)?.launch?.exe ?? ""
            if state == .ready, iconSources[game.id] != source, !engine.hasCustomIcon(game) {
                toRead.append(game)
            }
            loadIcon(for: game)
        }
        self.availability = availability
        guard !toRead.isEmpty else { return }
        for game in toRead { iconSources[game.id] = resolved(game)?.launch?.exe ?? "" }
        // Reading an icon means opening the program, which may be large or on a slow drive.
        Task {
            for game in toRead {
                _ = await Task.detached { engine.refreshIcon(for: game) }.value
                loadIcon(for: game)
            }
        }
    }

    func availability(of game: Game) -> GameAvailability {
        availability[game.id] ?? .ready
    }

    private func loadIcon(for game: Game) {
        guard let url = engine?.iconURL(for: game) else {
            icons[game.id] = nil
            return
        }
        icons[game.id] = NSImage(contentsOf: url)
    }

    /// Lets the player pick an image, an .icns or .ico file, or a program whose icon to use.
    func chooseIcon(for game: Game) {
        guard let engine else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose an image, or a Windows program (.exe) whose icon to use, for \(game.title)."
        panel.prompt = "Use as Icon"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .icns, .ico, .exe]
        if let bottle = try? engine.bottles.bottle(id: game.bottleID) {
            panel.directoryURL = engine.bottles.prefix(of: bottle).appendingPathComponent("drive_c")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try engine.setCustomIcon(for: game, from: url)
            loadIcon(for: game)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func useProgramIcon(for game: Game) {
        guard let engine else { return }
        do {
            try engine.removeCustomIcon(for: game)
            iconSources[game.id] = nil
            refreshLibraryState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
