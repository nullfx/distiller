import Foundation

/// Games launchers install get library entries of their own. A library entry whose program is a
/// launcher's client (`LauncherKind.kind(ofClient:)`: Steam's `steam.exe`, Battle.net's launcher)
/// is that **launcher**; every game it has installed in that bottle gets an entry sharing the
/// bottle (`Game.launchedBy`), whose recipe starts it through the launcher, and loses it once the
/// launcher uninstalls the game. This works the same whether the game was installed from
/// Distiller or inside the launcher.
public struct LauncherSync: Equatable, Sendable {
    public var added: [Game] = []
    public var removed: [Game] = []
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

/// What's running in each bottle now: the Windows programs (as Wine shows them) and Wine's own
/// processes, by prefix. Bottles whose wineserver is up are active.
public struct BottleProcesses: Equatable, Sendable {
    public var active: Set<String> = []
    public var commands: [String: [String]] = [:]
}

extension DistillerEngine {
    /// Library entries for launchers themselves.
    public func launchers(in games: [Game]? = nil) -> [Game] {
        (games ?? library.load()).filter { launcherKind(of: $0) != nil }
    }

    /// The launcher a library entry is (nil for games, including a launcher's games).
    public func launcherKind(of game: Game) -> LauncherKind? {
        guard game.launchedBy == nil, let exe = resolve(game.recipe, overrides: game.overrides).launch?.exe else { return nil }
        return LauncherKind.kind(ofClient: exe)
    }

    public func isLauncher(_ game: Game) -> Bool { launcherKind(of: game) != nil }

    /// Steam's entries (for what only Steam does: installing a game by its app ID).
    public func steamLaunchers(in games: [Game]? = nil) -> [Game] {
        launchers(in: games).filter { launcherKind(of: $0) == .steam }
    }

    public func isSteamLauncher(_ game: Game) -> Bool { launcherKind(of: game) == .steam }

    /// The games a launcher has installed in its bottle.
    func installedGames(kind: LauncherKind, clientExe: String, root: URL) -> [LauncherGame] {
        switch kind {
        case .steam:
            return SteamLibrary.installedGames(clientExe: clientExe, root: root).map {
                LauncherGame(gameID: $0.app.appID, name: $0.app.name, folder: $0.folder, iconProgram: nil)
            }
        case .battlenet:
            return BattleNetLibrary.installedGames(root: root)
        }
    }

    /// Adds entries for games launchers have installed and removes those they've uninstalled.
    /// Skips bottles that can't be read now (a disconnected drive), so nothing is removed then.
    @discardableResult
    public func syncLauncherGames() -> LauncherSync {
        guard paths.unavailable.isEmpty else { return LauncherSync() }
        var games = library.load()
        var sync = LauncherSync()
        for launcher in launchers(in: games) {
            guard let kind = launcherKind(of: launcher),
                  let bottle = try? bottles.bottle(id: launcher.bottleID),
                  let clientExe = resolve(launcher.recipe, overrides: launcher.overrides).launch?.exe else { continue }
            let root = bottles.root(of: bottle)
            guard FileManager.default.fileExists(atPath: bottles.prefix(of: bottle).path) else { continue }
            let installed = installedGames(kind: kind, clientExe: clientExe, root: root)
            let existing = games.filter { $0.launchedBy?.launcherID == launcher.id }

            for item in installed where !existing.contains(where: { $0.launchedBy?.gameID == item.gameID }) {
                // Tools and runtimes a launcher installs have no Windows program of their own: not games.
                guard let program = item.iconProgram ?? Self.bestIconProgram(in: item.folder)?.url else { continue }
                var recipe = Self.launcherGameRecipe(launcher: launcher.recipe, kind: kind, game: item, clientExe: clientExe)
                // A recipe the player added for it before the launcher had it.
                if let added = takePendingLauncherGame(gameID: item.gameID, launcherID: launcher.id) {
                    recipe = Self.applying(added, to: recipe, kind: kind, gameID: item.gameID)
                }
                let game = Game(
                    id: "\(launcher.id)-\(kind.rawValue)-\(item.gameID)", title: item.name, bottleID: launcher.bottleID,
                    recipe: recipe,
                    launchedBy: LauncherLink(kind: kind, gameID: item.gameID, launcherID: launcher.id,
                                             program: Self.windowsPath(of: program, root: root, isFolder: false))
                )
                try? library.upsert(game)
                refreshIcon(for: game)
                games.append(game)
                sync.added.append(game)
            }
            // Keep each game's bottle settings in step with its launcher's (they're the
            // bottle's), and give an existing entry a recipe the player added for it.
            for game in existing where installed.contains(where: { $0.gameID == game.launchedBy?.gameID }) {
                var base = game.recipe
                if let gameID = game.launchedBy?.gameID, let added = takePendingLauncherGame(gameID: gameID, launcherID: launcher.id) {
                    base = Self.applying(added, to: base, kind: kind, gameID: gameID)
                }
                let aligned = Self.aligned(base, with: launcher.recipe)
                if aligned != game.recipe {
                    var updated = game
                    updated.recipe = aligned
                    try? library.upsert(updated)
                }
            }
            for game in existing where !installed.contains(where: { $0.gameID == game.launchedBy?.gameID }) {
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

    /// How a launcher starts one of its games: Steam `-applaunch <id>` then whatever the player
    /// added (Steam passes those on to the game); Battle.net `--exec=launch <code>` (it doesn't
    /// pass anything on).
    static func launchArguments(kind: LauncherKind, gameID: String, recipeArgs: [String]?) -> [String] {
        switch kind {
        case .steam:
            return steamLaunchArguments(appID: gameID, recipeArgs: recipeArgs)
        case .battlenet:
            return ["--exec=launch \(BattleNetLibrary.launchCode(for: gameID))"]
        }
    }

    static func steamLaunchArguments(appID: String, recipeArgs: [String]?) -> [String] {
        var extra = recipeArgs ?? []
        if extra.count >= 2, extra[0] == "-applaunch", extra[1] == appID { extra.removeFirst(2) }
        return ["-applaunch", appID] + extra
    }

    /// The recipe of a game a launcher installed: the launcher's own settings (they apply to
    /// the whole bottle), started through the launcher.
    static func launcherGameRecipe(launcher: Recipe, kind: LauncherKind, game: LauncherGame, clientExe: String) -> Recipe {
        var recipe = launcher
        recipe.id = "\(kind.rawValue)-\(game.gameID.lowercased().replacingOccurrences(of: "_", with: "-"))"
        recipe.name = nil
        recipe.forkedFrom = nil
        recipe.notes = nil
        recipe.game.title = game.name
        let slug = RecipeDraft.makeSlug(game.name)
        recipe.game.slug = RecipePolicy.isValidSlug(slug) ? slug : recipe.id
        recipe.game.installer = nil
        recipe.install = nil
        switch kind {
        case .steam:
            recipe.launch = LaunchSpec(exe: clientExe, args: ["-applaunch", game.gameID])
        case .battlenet:
            recipe.launch = LaunchSpec(exe: BattleNetLibrary.gameClient(launcherExe: clientExe),
                                       args: launchArguments(kind: kind, gameID: game.gameID, recipeArgs: nil))
        }
        return recipe
    }

    /// A launcher game's recipe with the bottle-wide settings (Wine, graphics, Windows version,
    /// winetricks, registry, environment, Mac-specific overlays) taken from the launcher's
    /// current recipe: they belong to the shared bottle. Its name, notes and launch stay its own.
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

    /// `C:\…` for a folder (with a trailing backslash) or file inside the bottle's drive_c, else nil.
    static func windowsPath(of url: URL, root: URL, isFolder: Bool = true) -> String? {
        let driveC = root.appendingPathComponent("prefix/drive_c").standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(driveC + "/") else { return nil }
        return "C:" + path.dropFirst(driveC.count).replacingOccurrences(of: "/", with: "\\") + (isFolder ? "\\" : "")
    }

    // MARK: Running, stopping, uninstalling

    /// Whether a launcher's game is running, and its Windows process ID when the launcher says
    /// (Steam's log). Battle.net games are running while a program from their folder is.
    public func launcherGameState(_ game: Game, processes: BottleProcesses) -> (running: Bool, pid: Int?) {
        guard let link = game.launchedBy, let bottle = try? bottles.bottle(id: game.bottleID) else { return (false, nil) }
        let prefix = bottles.prefix(of: bottle)
        guard processes.active.contains(prefix.path) || processes.active.contains(prefix.standardizedFileURL.path) else { return (false, nil) }
        switch link.kind {
        case .steam:
            return steamGameState(game)
        case .battlenet:
            guard let folder = gameFolder(of: link) else { return (false, nil) }
            let commands = processes.commands[prefix.path] ?? processes.commands[prefix.standardizedFileURL.path] ?? []
            return (!BattleNetLibrary.runningPrograms(inFolder: folder, commands: commands).isEmpty, nil)
        }
    }

    /// The game's folder (`C:\…\`), from its program.
    func gameFolder(of link: LauncherLink) -> String? {
        guard let program = link.program, let slash = program.lastIndex(of: "\\") else { return nil }
        return String(program[...slash])
    }

    /// Whether Steam says this game is running, and its Windows process ID.
    public func steamGameState(_ game: Game) -> (running: Bool, pid: Int?) {
        guard let link = game.launchedBy, link.kind == .steam, let launcher = try? library.game(id: link.launcherID),
              let bottle = try? bottles.bottle(id: game.bottleID),
              let clientExe = resolve(launcher.recipe, overrides: launcher.overrides).launch?.exe,
              let steam = SteamLibrary.steamFolder(clientExe: clientExe, root: bottles.root(of: bottle)),
              let log = try? String(contentsOf: steam.appendingPathComponent("logs/gameprocess_log.txt"), encoding: .utf8) else {
            return (false, nil)
        }
        return SteamLibrary.runningState(appID: link.gameID, log: log)
    }

    /// Stops a launcher's game, leaving the launcher running.
    public func stopLauncherGame(_ game: Game) async throws {
        guard let link = game.launchedBy else { return }
        let bottle = try bottles.bottle(id: game.bottleID)
        let resolved = resolve(game.recipe, overrides: game.overrides)
        let stack = try selectStack(for: game)
        let env = WineEnvironment.build(prefix: bottles.prefix(of: bottle), wine: stack.wine, graphics: stack.graphics, resolved: resolved)
        switch link.kind {
        case .steam:
            guard let pid = steamGameState(game).pid else { return }
            try? await runner.wineCommand(["taskkill", "/PID", String(pid), "/F"], wine: stack.wine, environment: env, logName: "taskkill")
        case .battlenet:
            let processes = await bottleProcesses()
            let prefix = bottles.prefix(of: bottle)
            guard let folder = gameFolder(of: link) else { return }
            let commands = processes.commands[prefix.path] ?? processes.commands[prefix.standardizedFileURL.path] ?? []
            for name in BattleNetLibrary.runningPrograms(inFolder: folder, commands: commands) {
                try? await runner.wineCommand(["taskkill", "/IM", name, "/F"], wine: stack.wine, environment: env, logName: "taskkill")
            }
        }
    }

    /// Asks the launcher to uninstall a game. Steam asks the player to confirm; Battle.net is
    /// brought up so the player can uninstall it there (it has no way to be asked). Its library
    /// entry goes at the next sync, once the launcher has removed it.
    public func uninstallLauncherGame(_ game: Game) throws {
        guard let link = game.launchedBy else { return }
        switch link.kind {
        case .steam:
            var uninstall = game
            uninstall.recipe.launch?.args = ["steam://uninstall/\(link.gameID)"]
            _ = try launch(uninstall)
        case .battlenet:
            guard let launcher = try? library.game(id: link.launcherID) else { return }
            _ = try launch(launcher)
        }
    }

    // MARK: What's running

    /// What's running in each bottle now. Wine's own processes carry `WINEPREFIX`; the Windows
    /// programs they start don't show it (Wine replaces their visible environment and detaches
    /// them from their parent), so those are placed by their working folder, which Wine keeps
    /// inside the bottle's `drive_c` (`lsof`, a few milliseconds).
    public func bottleProcesses() async -> BottleProcesses {
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-axE", "-ww", "-o", "pid=,command="]) else { return BottleProcesses() }
        var processes = Self.bottleProcesses(psOutput: result.output)
        let unplaced = Self.unplacedWindowsPrograms(psOutput: result.output)
        guard !unplaced.isEmpty,
              let folders = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/lsof"),
                                                         arguments: ["-a", "-d", "cwd", "-Fpn", "-p", unplaced.keys.map(String.init).joined(separator: ",")]) else { return processes }
        for (pid, folder) in Self.workingFolders(lsofOutput: folders.output) {
            guard let command = unplaced[pid], let prefix = Self.prefix(ofFolder: folder) else { continue }
            processes.commands[prefix, default: []].append(command)
        }
        return processes
    }

    /// The prefix a folder inside a bottle's `drive_c` belongs to.
    static func prefix(ofFolder folder: String) -> String? {
        guard let range = folder.range(of: "/drive_c") else { return nil }
        let after = folder[range.upperBound...]
        guard after.isEmpty || after.hasPrefix("/") else { return nil }
        return String(folder[..<range.lowerBound])
    }

    /// From `lsof -Fpn` output: each process's working folder.
    static func workingFolders(lsofOutput: String) -> [Int: String] {
        var folders: [Int: String] = [:]
        var pid: Int?
        for line in lsofOutput.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid { folders[pid] = String(line.dropFirst()) }
        }
        return folders
    }

    /// From `ps -E` output (`pid command environment`): Windows programs without a WINEPREFIX
    /// to place them by, as `C:\…` commands.
    static func unplacedWindowsPrograms(psOutput: String) -> [Int: String] {
        var programs: [Int: String] = [:]
        for line in psOutput.split(separator: "\n").map(String.init) {
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "), let pid = Int(trimmed[..<space]) else { continue }
            let rest = String(trimmed[trimmed.index(after: space)...])
            guard !rest.contains(" WINEPREFIX="), let command = windowsCommand(rest) else { continue }
            programs[pid] = command
        }
        return programs
    }

    /// A Windows program's command as `C:\…`: Wine shows some as `C:\…` and others as the Mac
    /// path inside `drive_c`. Nil for anything else.
    static func windowsCommand(_ text: String) -> String? {
        if text.hasPrefix("C:\\") || text.hasPrefix("c:\\") { return commandOnly(text) }
        guard let range = text.range(of: "/drive_c/") else { return nil }
        let command = commandOnly(String(text[range.upperBound...]))
        // The program's path (with spaces) up to ".exe", then its arguments.
        guard let exe = command.range(of: ".exe", options: .caseInsensitive) else { return nil }
        let path = command[..<exe.upperBound].replacingOccurrences(of: "/", with: "\\")
        return "C:\\" + path + command[exe.upperBound...]
    }

    /// A ps line without the environment that follows the command.
    static func commandOnly(_ text: String) -> String {
        let environment = try? NSRegularExpression(pattern: " [A-Za-z_][A-Za-z0-9_]*=")
        let end = environment?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { Range($0.range, in: text) }?.lowerBound ?? text.endIndex
        return String(text[..<end])
    }

    /// The prefixes of bottles whose Wine is running now (a wineserver is up for them).
    public func activeBottlePrefixes() async -> Set<String> {
        await bottleProcesses().active
    }

    /// From `ps -E` output (`[pid] command environment`): the commands of processes carrying a
    /// WINEPREFIX, by it, and the prefixes with a wineserver. Paths may contain spaces; the
    /// environment starts at the first ` NAME=` after them.
    static func bottleProcesses(psOutput: String) -> BottleProcesses {
        var processes = BottleProcesses()
        let environment = try? NSRegularExpression(pattern: " [A-Za-z_][A-Za-z0-9_]*=")
        for raw in psOutput.split(separator: "\n").map(String.init) {
            // A leading pid (from `-o pid=,command=`) isn't part of the command.
            var line = String(raw.drop(while: { $0 == " " }))
            if let space = line.firstIndex(of: " "), Int(line[..<space]) != nil { line = String(line[line.index(after: space)...]) }
            guard let prefixRange = line.range(of: " WINEPREFIX=") else { continue }
            let rest = String(line[prefixRange.upperBound...])
            let end = environment?.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)).flatMap { Range($0.range, in: rest) }?.lowerBound ?? rest.endIndex
            let prefix = String(rest[..<end])
            let command = windowsCommand(line) ?? commandOnly(line)
            processes.commands[prefix, default: []].append(command)
            let program = commandOnly(line).split(separator: " ").first.map(String.init) ?? line
            if program.hasSuffix("/wineserver") { processes.active.insert(prefix) }
        }
        return processes
    }

    /// From `ps -E` output: the WINEPREFIX of every running wineserver.
    static func activePrefixes(psOutput: String) -> Set<String> {
        bottleProcesses(psOutput: psOutput).active
    }

    /// Whether `game`'s bottle has Wine running (for a launcher: whether it's up).
    public func isBottleActive(_ game: Game, active: Set<String>) -> Bool {
        guard let bottle = try? bottles.bottle(id: game.bottleID) else { return false }
        let prefix = bottles.prefix(of: bottle)
        return active.contains(prefix.path) || active.contains(prefix.standardizedFileURL.path)
    }
}

extension DistillerEngine {
    /// The launcher entry behind a game: itself for a launcher, its launcher for a launcher's game.
    public func launcherEntry(for game: Game) -> Game? {
        if let link = game.launchedBy { return try? library.game(id: link.launcherID) }
        return isLauncher(game) ? game : nil
    }

    /// After Distiller started Steam (for itself or a game): once Steam's interface is up (its
    /// web helper runs in the bottle), sends the player's links (Small Mode). Steam opens its
    /// main window when it has finished signing in, which would replace Small Mode, so they're
    /// sent again over the first minute. Gives up after `timeout` (Steam updating itself, or
    /// not signed in yet).
    public func applyLauncherOptionsAfterStart(for game: Game, timeout: Duration = .seconds(240)) async {
        guard let launcher = launcherEntry(for: game), launcherKind(of: launcher) == .steam,
              let links = launcher.launcherOptions?.steamLinksAfterStart, !links.isEmpty,
              let clientExe = resolve(launcher.recipe, overrides: launcher.overrides).launch?.exe,
              let bottle = try? bottles.bottle(id: launcher.bottleID) else { return }
        let prefix = bottles.prefix(of: bottle)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let processes = await bottleProcesses()
            let commands = processes.commands[prefix.path] ?? processes.commands[prefix.standardizedFileURL.path] ?? []
            if commands.contains(where: { $0.lowercased().contains("steamwebhelper.exe") }) {
                var waited = 0
                for at in [5, 15, 30, 60] {
                    try? await Task.sleep(for: .seconds(at - waited))
                    waited = at
                    for link in links {
                        _ = try? run(program: clientExe, arguments: [link], inBottle: launcher.bottleID)
                    }
                }
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Before Distiller starts Steam: the player's Friends status, written where Steam saves
    /// its own (`localconfig.vdf`, each signed-in account's `FriendStoreLocalPrefs_<account>`,
    /// `ePersonaState`), so Steam starts in it. Only while Steam isn't running (it writes the
    /// file itself when it quits). Accounts that haven't signed in yet have nothing to change.
    func applySteamFriendsStatus(for launcher: Game) {
        guard let state = launcher.launcherOptions?.steamPersonaState,
              let clientExe = resolve(launcher.recipe, overrides: launcher.overrides).launch?.exe,
              let bottle = try? bottles.bottle(id: launcher.bottleID),
              let steam = SteamLibrary.steamFolder(clientExe: clientExe, root: bottles.root(of: bottle)) else { return }
        let userdata = steam.appendingPathComponent("userdata", isDirectory: true)
        for account in (try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil)) ?? [] {
            let file = account.appendingPathComponent("config/localconfig.vdf")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let updated = SteamLibrary.settingPersonaState(state, in: text), updated != text else { continue }
            try? updated.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Saves how the player wants a launcher started (nil options: as the launcher left it).
    public func setLauncherOptions(_ options: LauncherOptions?, for launcherID: String) throws {
        var launcher = try library.game(id: launcherID)
        launcher.launcherOptions = options?.isEmpty == true ? nil : options
        try library.upsert(launcher)
    }
}
