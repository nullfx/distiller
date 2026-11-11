import Foundation

/// Rebuilding a game's bottle: the last resort when a game won't move to newer components.
/// The game's own recipe (with its local overrides) is installed into a new bottle with the
/// active components; only when that succeeds does the game switch to it. The old bottle stays
/// until the player keeps the new one (`keepRebuild`, which moves the old one to the Trash) or
/// switches back (`switchBack`, which removes the new one).
///
/// What the recipe asked the player for is reused from the old bottle where it can be
/// (`rebuildItems`): a game folder linked in from another drive is linked again, files and
/// downloaded installers are copied from the old bottle (and still verified as usual). Anything
/// the game keeps inside its bottle (saves under C:\users, settings, a launcher's sign-in) isn't
/// carried over.
extension DistillerEngine {
    /// What the old bottle can supply for the recipe's steps that ask the player for something.
    public func rebuildItems(for game: Game) throws -> UserSupplied {
        let old = try bottles.bottle(id: game.bottleID)
        let root = bottles.root(of: old)
        var supplied = UserSupplied()
        for step in game.recipe.install ?? [] {
            switch step {
            case .userFile(let file):
                if let path = try? BottlePath.resolve(file.to, in: root).followingSymlinks,
                   FileManager.default.fileExists(atPath: path.path) {
                    supplied.files[file.id] = path
                }
            case .userDownload(let download):
                if let path = try? BottlePath.resolve(download.to, in: root).followingSymlinks,
                   FileManager.default.fileExists(atPath: path.path),
                   (try? RecipeInstaller.checkPageDownload(path, for: download)) != nil {
                    supplied.files[download.id] = path
                }
            case .userFolder(let folder):
                guard let path = try? BottlePath.resolve(folder.to, in: root) else { continue }
                if APFSClone.isSymlink(path) {
                    // Used in place from another drive: link the same folder again, if it's there.
                    let target = path.followingSymlinks
                    if FileManager.default.fileExists(atPath: target.path) {
                        supplied.folders[folder.id] = UserFolderSource(url: target, linkInPlace: true)
                    }
                } else if FileManager.default.fileExists(atPath: path.path) {
                    supplied.folders[folder.id] = UserFolderSource(url: path, linkInPlace: false)
                }
            default:
                continue
            }
        }
        return supplied
    }

    /// Installs `game`'s recipe into a new bottle with the active components and switches the
    /// game to it. On failure or cancellation the new bottle is removed and the game is unchanged.
    public func rebuild(
        _ game: Game,
        supplied: UserSupplied,
        cancellation: InstallCancellation? = nil,
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> Game {
        guard game.rebuild == nil else {
            throw DistillerError.setupFailed("\(game.title) was already rebuilt. Keep the new bottle or switch back first.")
        }
        try paths.requireAvailable(.wine)
        try paths.requireAvailable(.bottles)
        let old = try bottles.bottle(id: game.bottleID)
        let resolved = resolve(game.recipe, overrides: game.overrides)
        let stack = try selectStack(for: resolved)
        let plan = InstallPlan.tasks(for: resolved)
        try cancellation?.check()
        progress(InstallProgress(step: 1, total: plan.count, message: plan[0].title))
        let fresh = try await bottles.makeBottle(name: game.title, wine: stack.wine, runner: runner)
        let environment = WineEnvironment.build(prefix: bottles.prefix(of: fresh), wine: stack.wine, graphics: stack.graphics, resolved: resolved)
        let runner = self.runner
        cancellation?.onCancel {
            Task { try? await runner.killAll(wine: stack.wine, environment: environment) }
        }
        do {
            try await installer.install(
                resolved, in: fresh, wine: stack.wine, graphics: stack.graphics, supplied: supplied,
                cancellation: cancellation, progress: progress
            )
            try cancellation?.check()
            if let missing = Self.missingLaunchProgram(resolved, root: bottles.root(of: fresh)) {
                throw DistillerError.setupFailed(
                    "The rebuild finished, but \(missing) isn't in the new bottle, so \(game.title) stays in its old bottle. If the installer was cancelled or showed an error, try the rebuild again."
                )
            }
        } catch {
            try? await runner.killAll(wine: stack.wine, environment: environment)
            try? bottles.delete(fresh)
            throw cancellation?.isCancelled == true ? CancellationError() : error
        }

        var updated = (try? library.game(id: game.id)) ?? game
        updated.bottleID = fresh.id
        updated.rebuild = Game.Rebuild(previousBottleID: old.id, rebuiltAt: Date())
        try library.upsert(updated)
        // The editable copy of the recipe lives next to the bottle.
        let oldRecipeFile = bottles.root(of: old).appendingPathComponent("recipe.yaml")
        if FileManager.default.fileExists(atPath: oldRecipeFile.path) {
            _ = try? writeRecipeFile(for: updated)
        }
        return updated
    }

    /// The game works in its rebuilt bottle: the old bottle goes to the Trash.
    public func keepRebuild(_ game: Game) throws {
        var updated = (try? library.game(id: game.id)) ?? game
        guard let rebuild = updated.rebuild else { return }
        if let old = try? bottles.bottle(id: rebuild.previousBottleID) {
            try bottles.delete(old)
        }
        updated.rebuild = nil
        try library.upsert(updated)
    }

    /// Back to the bottle the game had before the rebuild; the new bottle goes to the Trash.
    public func switchBack(_ game: Game) throws -> Game {
        var updated = (try? library.game(id: game.id)) ?? game
        guard let rebuild = updated.rebuild else { return updated }
        let old = try bottles.bottle(id: rebuild.previousBottleID)
        let fresh = try? bottles.bottle(id: updated.bottleID)
        updated.bottleID = old.id
        updated.rebuild = nil
        try library.upsert(updated)
        if let fresh { try bottles.delete(fresh) }
        return updated
    }

    /// Records that Distiller asked whether the rebuilt bottle works, so it asks once.
    public func markRebuildAsked(_ game: Game, now: Date = Date()) {
        guard var updated = try? library.game(id: game.id), updated.rebuild != nil else { return }
        updated.rebuild?.askedAt = now
        try? library.upsert(updated)
    }
}
