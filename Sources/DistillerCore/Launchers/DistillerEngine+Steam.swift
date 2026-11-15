import Foundation

/// Games Steam installs get library entries of their own. A library entry whose program is
/// Steam's client is a **Steam launcher**; every game Steam has fully installed in that bottle
/// (`SteamLibrary.installedGames`) gets an entry sharing the bottle, whose recipe starts it
/// through Steam (`steam.exe -applaunch <id>`), and loses it once Steam uninstalls the game.
/// This works the same whether the game was installed from Distiller or inside Steam.
public struct SteamSync: Equatable, Sendable {
    public var added: [Game] = []
    public var removed: [Game] = []
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

extension DistillerEngine {
    /// Library entries for Steam itself.
    public func steamLaunchers(in games: [Game]? = nil) -> [Game] {
        (games ?? library.load()).filter { game in
            game.steam == nil && resolve(game.recipe, overrides: game.overrides).launch.map { SteamLibrary.isClient($0.exe) } == true
        }
    }

    public func isSteamLauncher(_ game: Game) -> Bool {
        game.steam == nil && resolve(game.recipe, overrides: game.overrides).launch.map { SteamLibrary.isClient($0.exe) } == true
    }

    /// Adds entries for games Steam has installed and removes those it has uninstalled. Skips
    /// Steam bottles that can't be read now (a disconnected drive), so nothing is removed then.
    @discardableResult
    public func syncSteamGames() -> SteamSync {
        guard paths.unavailable.isEmpty else { return SteamSync() }
        var games = library.load()
        var sync = SteamSync()
        for launcher in steamLaunchers(in: games) {
            guard let bottle = try? bottles.bottle(id: launcher.bottleID),
                  let clientExe = resolve(launcher.recipe, overrides: launcher.overrides).launch?.exe else { continue }
            let root = bottles.root(of: bottle)
            guard FileManager.default.fileExists(atPath: bottles.prefix(of: bottle).path) else { continue }
            let installed = SteamLibrary.installedGames(clientExe: clientExe, root: root)
            let existing = games.filter { $0.steam?.launcherID == launcher.id }

            for (app, folder) in installed where !existing.contains(where: { $0.steam?.appID == app.appID }) {
                // Steam's tools and runtimes have no Windows program of their own: not games.
                guard let program = Self.bestIconProgram(in: folder) else { continue }
                let relative = program.relativePath.replacingOccurrences(of: "/", with: "\\")
                let windowsFolder = Self.windowsPath(of: folder, root: root)
                let game = Game(
                    id: "\(launcher.id)-steam-\(app.appID)", title: app.name, bottleID: launcher.bottleID,
                    recipe: Self.steamGameRecipe(launcher: launcher.recipe, app: app, clientExe: clientExe),
                    steam: Game.SteamLink(appID: app.appID, launcherID: launcher.id, program: windowsFolder.map { $0 + relative })
                )
                try? library.upsert(game)
                refreshIcon(for: game)
                games.append(game)
                sync.added.append(game)
            }
            // Keep each game's bottle settings in step with Steam's (they're the bottle's).
            for game in existing where installed.contains(where: { $0.app.appID == game.steam?.appID }) {
                let aligned = Self.aligned(game.recipe, with: launcher.recipe)
                if aligned != game.recipe {
                    var updated = game
                    updated.recipe = aligned
                    try? library.upsert(updated)
                }
            }
            for game in existing where !installed.contains(where: { $0.app.appID == game.steam?.appID }) {
                try? library.remove(id: game.id)
                removeIcons(for: game)
                sync.removed.append(game)
            }
        }
        return sync
    }

    /// Of the folder's likeliest programs, the one with the biggest icon (games often ship a
    /// small launcher stub next to the real program).
    static func bestIconProgram(in folder: URL) -> DiscoveredProgram? {
        let candidates = ProgramFinder.find(in: folder, limit: 50)
        let best = candidates.prefix(6).max { a, b in iconSize(a.url) < iconSize(b.url) }
        return (best.map { iconSize($0.url) } ?? 0) > 0 ? best : candidates.first
    }

    static func iconSize(_ program: URL) -> Int {
        guard let ico = PEIcon.ico(fromExecutable: program), let png = PEIcon.png(fromImageData: ico) else { return 0 }
        return png.count
    }

    /// Steam's launch arguments for a game: `-applaunch <id>`, then whatever the player added
    /// (Steam passes those on to the game).
    static func steamLaunchArguments(appID: String, recipeArgs: [String]?) -> [String] {
        var extra = recipeArgs ?? []
        if extra.count >= 2, extra[0] == "-applaunch", extra[1] == appID { extra.removeFirst(2) }
        return ["-applaunch", appID] + extra
    }

    /// The recipe of a game Steam installed: Steam's own settings (they apply to the whole
    /// bottle), started through Steam.
    static func steamGameRecipe(launcher: Recipe, app: SteamApp, clientExe: String) -> Recipe {
        var recipe = launcher
        recipe.id = "steam-\(app.appID)"
        recipe.name = nil
        recipe.forkedFrom = nil
        recipe.notes = nil
        recipe.game.title = app.name
        let slug = RecipeDraft.makeSlug(app.name)
        recipe.game.slug = RecipePolicy.isValidSlug(slug) ? slug : "steam-\(app.appID)"
        recipe.game.installer = nil
        recipe.install = nil
        recipe.launch = LaunchSpec(exe: clientExe, args: ["-applaunch", app.appID])
        return recipe
    }

    /// A Steam game's recipe with the bottle-wide settings (Wine, graphics, Windows version,
    /// winetricks, registry, environment, Mac-specific overlays) taken from Steam's current
    /// recipe: they belong to the shared bottle. Its name, notes and launch stay its own.
    static func aligned(_ recipe: Recipe, with launcher: Recipe) -> Recipe {
        var result = recipe
        result.schema = launcher.schema
        result.stack = launcher.stack
        result.prefix = launcher.prefix
        result.env = launcher.env
        result.overlays = launcher.overlays
        result.install = nil
        result.game.installer = nil
        return result
    }

    /// `C:\…` for a folder inside the bottle's drive_c, else nil.
    static func windowsPath(of folder: URL, root: URL) -> String? {
        let driveC = root.appendingPathComponent("prefix/drive_c").standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        guard path.hasPrefix(driveC + "/") else { return nil }
        return "C:" + path.dropFirst(driveC.count).replacingOccurrences(of: "/", with: "\\") + "\\"
    }

    /// Whether Steam says this game is running, and its Windows process ID.
    public func steamGameState(_ game: Game) -> (running: Bool, pid: Int?) {
        guard let appID = game.steam?.appID, let launcher = try? library.game(id: game.steam?.launcherID ?? ""),
              let bottle = try? bottles.bottle(id: game.bottleID),
              let clientExe = resolve(launcher.recipe, overrides: launcher.overrides).launch?.exe,
              let steam = SteamLibrary.steamFolder(clientExe: clientExe, root: bottles.root(of: bottle)),
              let log = try? String(contentsOf: steam.appendingPathComponent("logs/gameprocess_log.txt"), encoding: .utf8) else {
            return (false, nil)
        }
        return SteamLibrary.runningState(appID: appID, log: log)
    }

    /// Stops a Steam game, leaving Steam running.
    public func stopSteamGame(_ game: Game) async throws {
        guard let pid = steamGameState(game).pid else { return }
        let bottle = try bottles.bottle(id: game.bottleID)
        let resolved = resolve(game.recipe, overrides: game.overrides)
        let stack = try selectStack(for: game)
        let env = WineEnvironment.build(prefix: bottles.prefix(of: bottle), wine: stack.wine, graphics: stack.graphics, resolved: resolved)
        try? await runner.wineCommand(["taskkill", "/PID", String(pid), "/F"], wine: stack.wine, environment: env, logName: "taskkill")
    }

    /// Asks Steam to uninstall a game (Steam asks the player to confirm). Its library entry goes
    /// at the next sync, once Steam has removed it.
    public func uninstallSteamGame(_ game: Game) throws {
        guard let appID = game.steam?.appID else { return }
        var uninstall = game
        uninstall.recipe.launch?.args = ["steam://uninstall/\(appID)"]
        _ = try launch(uninstall)
    }
}

extension DistillerEngine {
    /// The prefixes of bottles whose Wine is running now (a wineserver is up for them).
    public func activeBottlePrefixes() async -> Set<String> {
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-axE", "-ww", "-o", "command="]) else { return [] }
        return Self.activePrefixes(psOutput: result.output)
    }

    /// From `ps -E` output: the WINEPREFIX of every running wineserver.
    static func activePrefixes(psOutput: String) -> Set<String> {
        var prefixes: Set<String> = []
        for line in psOutput.split(separator: "\n") {
            let words = line.split(separator: " ")
            guard let program = words.first, program.hasSuffix("/wineserver") || program.hasSuffix("bin/wineserver") else { continue }
            if let prefix = words.first(where: { $0.hasPrefix("WINEPREFIX=") }) {
                prefixes.insert(String(prefix.dropFirst("WINEPREFIX=".count)))
            }
        }
        return prefixes
    }

    /// Whether `game`'s bottle has Wine running (for Steam: whether Steam is up).
    public func isBottleActive(_ game: Game, active: Set<String>) -> Bool {
        guard let bottle = try? bottles.bottle(id: game.bottleID) else { return false }
        let prefix = bottles.prefix(of: bottle)
        return active.contains(prefix.path) || active.contains(prefix.standardizedFileURL.path)
    }
}
