import Foundation
import DistillerCore

/// "Did <game> work on Wine X?" after the first session on a newer Wine.
struct RestorePointQuestion: Identifiable {
    var id: String { game.id }
    var game: Game
    var point: RestorePoint
}

/// Restore points: a game's bottle is copied before it moves to a newer Wine, so the move can
/// be undone (Workshop ▸ Bottle, and the question after its first session).
extension AppModel {
    /// Saves a restore point and updates the bottle, when the game's next run would move it to
    /// a newer Wine. Shows progress in the status bar.
    func prepareWineMove(for game: Game) async throws {
        guard let engine, (try? engine.pendingWineMove(for: game)) != nil else { return }
        let previous = busyMessage
        defer { busyMessage = previous }
        try await engine.prepareWineMove(for: game) { message in
            Task { @MainActor in self.busyMessage = message }
        }
        reload()
    }

    func restorePoint(for game: Game) -> RestorePoint? {
        guard let engine, let bottle = try? engine.bottles.bottle(id: game.bottleID) else { return nil }
        return engine.bottles.restorePoint(of: bottle)
    }

    func confirmWineMove(_ game: Game) {
        guard let engine else { return }
        do {
            try engine.confirmWineMove(game)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func rollBack(_ game: Game) {
        guard let engine else { return }
        guard running[game.id] == nil else {
            errorMessage = "Quit \(game.title) before rolling its bottle back."
            return
        }
        perform("Rolling \(game.title) back…") {
            try await engine.rollBack(game)
        }
    }

    func discardRestorePoint(_ game: Game) {
        guard let engine, let bottle = try? engine.bottles.bottle(id: game.bottleID) else { return }
        do {
            try engine.bottles.discardRestorePoint(of: bottle)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func setRestorePointDays(_ days: Int) {
        guard let engine else { return }
        var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        settings.restorePointDays = days
        do {
            try settings.save(toSupportFolder: engine.paths.root)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
}
