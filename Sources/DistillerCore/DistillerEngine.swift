import Foundation

/// The one entry point the app and the CLI use. Everything Wine-related goes through here.
public final class DistillerEngine: @unchecked Sendable {
    public let paths: DistillerPaths
    public let components: ComponentStore
    public let bottles: BottleStore
    public let library: LibraryStore
    public let runner: WineRunner
    public let installer: RecipeInstaller
    private let hardwareLock = NSLock()
    private var probedHardware: HardwareProfile
    /// Probed once at start; `refreshHardware()` probes again, for example after Rosetta is installed.
    public var hardware: HardwareProfile {
        hardwareLock.lock()
        defer { hardwareLock.unlock() }
        return probedHardware
    }

    public init(paths: DistillerPaths = DistillerPaths(), hardware: HardwareProfile? = nil) throws {
        try paths.ensureDirectories()
        self.paths = paths
        self.components = ComponentStore(paths: paths)
        self.bottles = BottleStore(paths: paths)
        self.library = LibraryStore(paths: paths)
        self.runner = WineRunner(paths: paths)
        self.installer = RecipeInstaller(runner: runner, bottles: bottles, components: components)
        self.probedHardware = hardware ?? HardwareProbe.current()
    }

    public func refreshHardware() {
        let fresh = HardwareProbe.current()
        hardwareLock.lock()
        probedHardware = fresh
        hardwareLock.unlock()
    }

    public func resolve(_ recipe: Recipe, overrides: LocalOverrides? = nil) -> ResolvedRecipe {
        RecipeResolver.resolve(recipe, for: hardware, overrides: overrides)
    }

    /// Picks the newest Wine build that satisfies the recipe and the graphics layer it names,
    /// and composes them. Fails with a clear message when something is missing.
    /// Chooses the Wine build for `resolved`: the newest one that meets the recipe's runner
    /// requirement, that can run its graphics layer (D3DMetal and DXMT need `macdrv_*`
    /// exports), and, for an existing `bottle`, that won't harm it: the same build or family
    /// as the one that made the bottle, at the same or a newer version. Wine upgrades a
    /// bottle in place but can't safely go back, and other kinds of Wine may not read it.
    public func chooseWine(for resolved: ResolvedRecipe, bottle: Bottle? = nil) throws -> InstalledComponent {
        let candidates = components.wineCandidates(for: resolved.runner)
        guard !candidates.isEmpty else {
            let minimum = resolved.runner.minVersion.map { " \($0) or later" } ?? ""
            let family = resolved.runner.family == "any" ? "" : "\(resolved.runner.family) "
            throw DistillerError.componentNotFound("a \(family)Wine build\(minimum)")
        }
        var allowed = candidates
        if let bottle {
            let made = BottleWine(bottle.wine)
            let original = components.installed().first { $0.manifest.kind == .wine && $0.manifest.id == made.id }
            allowed = candidates.filter { candidate in
                let sameKind = candidate.manifest.id == made.id
                    || (original?.manifest.family != nil && candidate.manifest.family == original?.manifest.family)
                return sameKind && VersionNumber(candidate.manifest.version) >= VersionNumber(made.version)
            }
            if allowed.isEmpty {
                let name = original.map { "\($0.manifest.displayName.components(separatedBy: " ").dropLast().joined(separator: " ")) \(made.version)" }
                    ?? "\(made.id) \(made.version)"
                throw DistillerError.bottleNeedsItsWine(
                    "\(bottle.name)'s bottle was made with \(name). Running it with an older or different kind of Wine build can damage it. Install \(name) or newer, or create a new bottle for the other Wine build."
                )
            }
        }
        // Fail clearly rather than let the game crash in a layer this Wine can't run.
        guard let wine = allowed.first(where: { WineCapabilities.canRun(resolved.graphics, on: $0) }) else {
            throw DistillerError.graphicsNeedsOtherWine(WineCapabilities.whyNot(resolved.graphics))
        }
        return wine
    }

    /// The Wine build (with its graphics layer merged in, when needed) to run `resolved` with.
    /// Pass the bottle for anything that runs in an existing one.
    public func selectStack(for resolved: ResolvedRecipe, bottle: Bottle? = nil) throws -> (wine: InstalledComponent, graphics: InstalledComponent?) {
        let wine = try chooseWine(for: resolved, bottle: bottle)
        if wine.requiresRosetta && !hardware.rosetta {
            throw DistillerError.rosettaUnavailable(wine.manifest.displayName)
        }
        var graphics: InstalledComponent?
        if resolved.graphics != .wined3d {
            guard let layer = components.graphicsLayer(resolved.graphics) else {
                throw DistillerError.componentNotFound(resolved.graphics.displayName)
            }
            graphics = layer
        }
        let composed = try StackComposer.compose(wine: wine, graphics: graphics, store: components)
        return (composed, graphics)
    }

    /// `selectStack` for a game in its own bottle. When it picks a newer Wine than the bottle
    /// last ran with, the bottle records it: Wine upgrades the bottle on that run, so older
    /// builds are no longer safe for it.
    public func selectStack(for game: Game, recordUpgrade: Bool = false) throws -> (wine: InstalledComponent, graphics: InstalledComponent?) {
        var bottle = try bottles.bottle(id: game.bottleID)
        let stack = try selectStack(for: resolve(game.recipe, overrides: game.overrides), bottle: bottle)
        if recordUpgrade {
            let base = stack.wine.manifest.composedFrom?.first.flatMap(components.component(withID:)) ?? stack.wine
            let made = BottleWine(bottle.wine)
            if VersionNumber(base.manifest.version) > VersionNumber(made.version) || base.manifest.id != made.id {
                bottle.wine = base.id
                try bottles.save(bottle)
            }
        }
        return stack
    }

    /// Creates a bottle, runs the recipe's install, and adds the game to the library.
    /// On failure the bottle is kept so its logs and files can be inspected.
    public func install(
        recipe: Recipe,
        supplied: UserSupplied = UserSupplied(),
        authored: Bool = false,
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> Game {
        try RecipeLoader.validate(recipe)
        try paths.requireAvailable(.wine)
        let resolved = resolve(recipe)
        let stack = try selectStack(for: resolved)
        progress(InstallProgress(step: 0, total: 1, message: "Creating a bottle"))
        let bottle = try await bottles.makeBottle(name: recipe.game.title, wine: stack.wine, runner: runner)
        // Add the game before running steps, so a failed install still shows up and can be fixed.
        let game = Game(id: bottle.id, title: recipe.game.title, bottleID: bottle.id, recipe: recipe, authored: authored ? true : nil)
        if authored {
            try library.upsert(game)
            try writeRecipeFile(for: game)
        }
        try await installer.install(
            resolved, in: bottle, wine: stack.wine, graphics: stack.graphics, supplied: supplied, progress: progress
        )
        try library.upsert(game)
        return game
    }

    /// The pre-authoring form, kept for callers that only supply files.
    public func install(
        recipe: Recipe,
        userFiles: [String: URL],
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> Game {
        try await install(recipe: recipe, supplied: UserSupplied(files: userFiles), progress: progress)
    }

    /// Starts a game from the library. `onExit` runs on a background thread.
    public func launch(_ game: Game, onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
        try paths.requireAvailable(.bottles)
        try paths.requireAvailable(.wine)
        let bottle = try bottles.bottle(id: game.bottleID)
        let resolved = resolve(game.recipe, overrides: game.overrides)
        guard let launch = resolved.launch else {
            throw DistillerError.invalidRecipe("it has no launch section, so Distiller doesn't know which program to start.")
        }
        let stack = try selectStack(for: game, recordUpgrade: true)
        let root = bottles.root(of: bottle)
        let prefix = bottles.prefix(of: bottle)
        if let graphics = stack.graphics {
            try GraphicsPlacer.installPrefixDLLs(graphics, prefix: prefix)
        }
        let env = WineEnvironment.build(prefix: prefix, wine: stack.wine, graphics: stack.graphics, resolved: resolved)
        // Following links matters for games used in place from another drive: Wine names a
        // file by the drive whose folder is nearest above it, so the real path runs the game
        // from D: (or E:, …) instead of from a link on C:.
        // A game used in place writes to its own folder (for example a large data file it
        // updates at start), so it must never run against a missing drive.
        if case .unavailable(let reason) = availability(of: game) {
            throw DistillerError.storageUnavailable(reason)
        }
        let program = try BottlePath.resolve(launch.exe, in: root).followingSymlinks
        let workingDirectory = try launch.workingDir.map { try BottlePath.resolve($0, in: root).followingSymlinks }
            ?? program.deletingLastPathComponent()
        let prefixPath = prefix.followingSymlinks.path + "/"
        if !workingDirectory.path.hasPrefix(prefixPath) {
            try DriveMapper.mapVolume(of: workingDirectory, in: prefix)
        }
        return try runner.launch(
            program: program.path,
            arguments: launch.args ?? [],
            wine: stack.wine,
            environment: env,
            workingDirectory: workingDirectory,
            logName: game.id,
            onExit: onExit
        )
    }

    public func stop(_ game: Game) async throws {
        let bottle = try bottles.bottle(id: game.bottleID)
        let resolved = resolve(game.recipe, overrides: game.overrides)
        let stack = try selectStack(for: game)
        let env = WineEnvironment.build(prefix: bottles.prefix(of: bottle), wine: stack.wine, graphics: stack.graphics, resolved: resolved)
        try await runner.killAll(wine: stack.wine, environment: env)
    }

    /// Creates an empty bottle with a given Wine build (phase 0: no recipe needed).
    public func createBottle(name: String, wineID: String?) async throws -> Bottle {
        let wine: InstalledComponent?
        if let wineID {
            wine = components.component(withID: wineID)
        } else {
            wine = components.installed().first { $0.manifest.kind == .wine }
        }
        guard let wine, wine.manifest.kind == .wine else {
            throw DistillerError.componentNotFound(wineID.map { "Wine build \($0)" } ?? "a Wine build")
        }
        if wine.requiresRosetta && !hardware.rosetta {
            throw DistillerError.rosettaUnavailable(wine.manifest.displayName)
        }
        return try await bottles.makeBottle(name: name, wine: wine, runner: runner)
    }

    /// Runs any program in an existing bottle, such as "notepad". This is the phase 0 test.
    public func run(program: String, arguments: [String], inBottle bottleID: String, onExit: (@Sendable (Int32) -> Void)? = nil) throws -> Process {
        try paths.requireAvailable(.bottles)
        try paths.requireAvailable(.wine)
        let bottle = try bottles.bottle(id: bottleID)
        guard let wine = components.component(withID: bottle.wine) else {
            throw DistillerError.componentNotFound("the Wine build \(bottle.wine) this bottle was made with")
        }
        let env = WineEnvironment.build(prefix: bottles.prefix(of: bottle), wine: wine, graphics: nil, resolved: nil)
        return try runner.launch(
            program: program, arguments: arguments, wine: wine, environment: env,
            workingDirectory: nil, logName: "run-\(bottle.id)", onExit: onExit
        )
    }
}


/// The Wine build recorded in `Bottle.wine`: "wine-staging@11.21", or a composed build such
/// as "wine-staging+dxvk-macos@11.21" (the version is the Wine build's).
struct BottleWine {
    let id: String
    let version: String

    init(_ text: String) {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        id = String((parts.first ?? text).split(separator: "+").first ?? "")
        version = parts.count > 1 ? parts[1] : "0"
    }
}
