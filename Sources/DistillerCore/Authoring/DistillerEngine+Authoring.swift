import Foundation

/// Wine's own tools, run inside a game's bottle while building a recipe.
public enum WineTool: String, CaseIterable, Sendable {
    case winecfg, regedit, explorer, taskmgr, cmd

    public var displayName: String {
        switch self {
        case .winecfg: return "Wine Configuration"
        case .regedit: return "Registry Editor"
        case .explorer: return "Windows Explorer"
        case .taskmgr: return "Task Manager"
        case .cmd: return "Command Prompt"
        }
    }
}

/// A program found on a bottle's C: drive.
public struct ProgramInBottle: Identifiable, Hashable, Sendable {
    public var program: DiscoveredProgram
    /// Such as `C:\Program Files\Example\Game.exe`.
    public var windowsPath: String
    public var id: String { windowsPath }
}

/// Creating and editing recipes. The app and CLI use these; they never touch bottles directly.
extension DistillerEngine {
    /// Creates a bottle from a draft, runs its install steps and adds the game to the library
    /// as an authored game. A failed install still leaves the game in the library, so the
    /// player can fix the recipe and try again.
    public func create(
        from draft: RecipeDraft,
        supplied: UserSupplied,
        cancellation: InstallCancellation? = nil,
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> Game {
        try await install(recipe: draft.makeRecipe(), supplied: supplied, authored: true, cancellation: cancellation, progress: progress)
    }

    /// Windows programs in a game's bottle, best guesses first, with their Windows paths.
    public func discoverPrograms(for game: Game) throws -> [ProgramInBottle] {
        let bottle = try bottles.bottle(id: game.bottleID)
        let driveC = bottles.prefix(of: bottle).appendingPathComponent("drive_c", isDirectory: true)
        return ProgramFinder.find(in: driveC).map { program in
            let parts = program.relativePath.split(separator: "/").map(String.init)
            return ProgramInBottle(program: program, windowsPath: BottlePath.windowsPath(relativeComponents: parts))
        }
    }

    /// Replaces a game's recipe after checking it. Settings that live in the bottle (Windows
    /// version, registry, winetricks, graphics files) are re-applied when they changed, or
    /// always with `forceReconfigure`.
    @discardableResult
    public func updateRecipe(
        _ recipe: Recipe,
        for game: Game,
        forceReconfigure: Bool = false,
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> Game {
        try RecipeLoader.validate(recipe)
        var updated = (try? library.game(id: game.id)) ?? game
        let previous = updated.recipe
        updated.recipe = recipe
        updated.title = recipe.game.title
        try library.upsert(updated)
        try writeRecipeFile(for: updated)
        if forceReconfigure || needsReconfigure(from: previous, to: recipe, overrides: updated.overrides) {
            try await reconfigure(updated, progress: progress)
        }
        return updated
    }

    /// True when the change affects what's stored in the bottle rather than only how the game starts.
    public func needsReconfigure(from old: Recipe, to new: Recipe, overrides: LocalOverrides? = nil) -> Bool {
        let a = resolve(old, overrides: overrides)
        let b = resolve(new, overrides: overrides)
        return a.windowsVersion != b.windowsVersion || a.retina != b.retina || a.registry != b.registry
            || a.winetricks != b.winetricks || a.runner != b.runner
            || (a.graphics != b.graphics && (placesFilesInBottle(a.graphics) || placesFilesInBottle(b.graphics)))
    }

    /// Layers merged into the Wine build (D3DMetal, DXMT, DXVK-macOS builtin) need nothing in
    /// the bottle beyond what `launch` copies; only `prefix_dlls` layers do.
    private func placesFilesInBottle(_ backend: GraphicsBackend) -> Bool {
        components.graphicsLayer(backend)?.manifest.placement == .prefixDLLs
    }

    /// Re-applies the Windows version, registry, graphics files and winetricks to a game's bottle.
    public func reconfigure(_ game: Game, progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }) async throws {
        let bottle = try bottles.bottle(id: game.bottleID)
        let resolved = resolve(game.recipe, overrides: game.overrides)
        let stack = try selectStack(for: game, recordUpgrade: true)
        let total = RecipeInstaller.configureStepCount(for: resolved)
        try await installer.configurePrefix(resolved, in: bottle, wine: stack.wine, graphics: stack.graphics) { step, message in
            progress(InstallProgress(step: step, total: total, message: message))
        }
    }

    /// Runs a Windows installer from the Mac in a game's bottle and, with `record`, adds the
    /// `user_file` and `run_windows` steps that repeat it to the recipe, so the recipe still
    /// works for other players.
    @discardableResult
    public func runInstaller(
        _ installerURL: URL,
        for game: Game,
        arguments: [String] = [],
        record: Bool = true,
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> Game {
        let bottle = try bottles.bottle(id: game.bottleID)
        var recipe = ((try? library.game(id: game.id)) ?? game).recipe
        let usedIDs = Set((recipe.install ?? []).compactMap { step -> String? in
            if case .userFile(let file) = step { return file.id }
            return nil
        })
        var id = RecipeDraft.installerStepID
        var counter = 2
        while usedIDs.contains(id) {
            id = "\(RecipeDraft.installerStepID)-\(counter)"
            counter += 1
        }
        let steps = RecipeDraft.installerSteps(for: installerURL, id: id, gameTitle: recipe.game.title, args: arguments)
        let resolved = resolve(recipe, overrides: game.overrides)
        let stack = try selectStack(for: resolved, bottle: bottle)
        try await installer.runSteps(
            steps, in: bottle, resolved: resolved, wine: stack.wine, graphics: stack.graphics,
            supplied: UserSupplied(files: [id: installerURL])
        ) { index, message in
            progress(InstallProgress(step: index, total: steps.count, message: message))
        }
        guard record else { return (try? library.game(id: game.id)) ?? game }
        recipe.install = (recipe.install ?? []) + steps
        return try await updateRecipe(recipe, for: game)
    }

    /// Starts one of Wine's tools in a game's bottle, with the game's environment.
    public func runTool(_ tool: WineTool, for game: Game, onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
        let bottle = try bottles.bottle(id: game.bottleID)
        let resolved = resolve(game.recipe, overrides: game.overrides)
        let stack = try selectStack(for: game, recordUpgrade: true)
        let env = WineEnvironment.build(prefix: bottles.prefix(of: bottle), wine: stack.wine, graphics: stack.graphics, resolved: resolved)
        return try runner.launch(
            program: tool.rawValue, arguments: [], wine: stack.wine, environment: env,
            workingDirectory: nil, logName: "\(game.id)-\(tool.rawValue)", onExit: onExit
        )
    }

    // MARK: The editable recipe file

    /// `Bottles/<id>/recipe.yaml`: a copy of the game's recipe the player can open in any editor.
    public func recipeFileURL(for game: Game) throws -> URL {
        let bottle = try bottles.bottle(id: game.bottleID)
        return bottles.root(of: bottle).appendingPathComponent("recipe.yaml")
    }

    @discardableResult
    public func writeRecipeFile(for game: Game) throws -> URL {
        let url = try recipeFileURL(for: game)
        let header = """
            # Distiller recipe for \(game.recipe.game.title).
            # Edit this file, then choose Reload Recipe File in Distiller to apply it.
            # The format is described by schema/recipe.schema.json in the distiller-recipes repository.


            """
        try (header + RecipeLoader.encode(game.recipe)).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Reads `recipe.yaml` back after the player edited it, and applies it like `updateRecipe`.
    public func reloadRecipeFile(
        for game: Game,
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> Game {
        let recipe = try RecipeLoader.load(from: recipeFileURL(for: game))
        return try await updateRecipe(recipe, for: game, progress: progress)
    }
}
