import Foundation
import DistillerCore

/// Rebuilding a game's bottle with the current components (Workshop ▸ Bottle): the recipe is
/// installed into a new bottle in the install window, the game switches to it, and the old
/// bottle is kept until the player keeps the new one or switches back.
extension AppModel {
    func rebuild(_ game: Game) {
        guard let engine else { return }
        guard running[game.id] == nil else {
            errorMessage = "Quit \(game.title) before rebuilding its bottle."
            return
        }
        Task {
            do {
                let reused = (try? engine.rebuildItems(for: game)) ?? UserSupplied()
                guard let supplied = await askForUserItems(game.recipe, already: reused) else { return }
                // Page downloads asked for now are temporary copies; reused files are the old bottle's.
                let temporary = supplied.files.values.filter { $0.path.contains("/distiller-installer-") }
                defer { temporary.forEach(PageDownloadWindow.removeDownload) }
                busyMessage = "Rebuilding \(game.title)'s bottle…"
                defer { busyMessage = nil }
                let resolved = engine.resolve(game.recipe, overrides: game.overrides)
                let session = InstallSession(title: game.title, tasks: InstallPlan.tasks(for: resolved), purpose: .rebuild)
                InstallProgressWindow.show(session)
                do {
                    let updated = try await engine.rebuild(game, supplied: supplied, cancellation: session.cancellation) { progress in
                        Task { @MainActor in
                            session.update(progress)
                            self.busyMessage = "Rebuilding \(game.title): \(progress.message)"
                        }
                    }
                    session.finish(.installed)
                    if gameInWorkshop?.id == game.id { gameInWorkshop = updated }
                } catch is CancellationError {
                    session.finish(.cancelled)
                } catch {
                    session.finish(.failed(error.localizedDescription))
                    throw error
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            reload()
        }
    }

    func keepRebuild(_ game: Game) {
        guard let engine else { return }
        do {
            try engine.keepRebuild(game)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func switchBack(_ game: Game) {
        guard let engine else { return }
        guard running[game.id] == nil else {
            errorMessage = "Quit \(game.title) before switching back."
            return
        }
        do {
            let updated = try engine.switchBack(game)
            if gameInWorkshop?.id == game.id { gameInWorkshop = updated }
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
}
