import Foundation
import DistillerCore

/// Steam in the library: games Steam installs get entries of their own (`syncSteamGames`), Play
/// starts them through Steam, and their running state comes from Steam's own log rather than
/// the program Distiller started (Steam hands the launch over, or restarts itself). Steam's
/// entry counts as running while its bottle's Wine is up.
extension AppModel {
    /// Adds and removes Steam games, and refreshes which Steam entries are running. Called on
    /// every reload, and every few seconds while there's a Steam bottle.
    func refreshSteam() {
        guard let engine else { return }
        let sync = engine.syncSteamGames()
        if !sync.isEmpty {
            games = engine.library.load()
            refreshLibraryState()
            var notes: [String] = []
            if !sync.added.isEmpty { notes.append("\(Self.list(sync.added.map(\.title))) \(sync.added.count == 1 ? "was" : "were") installed in Steam and added to your library.") }
            if !sync.removed.isEmpty { notes.append("\(Self.list(sync.removed.map(\.title))) \(sync.removed.count == 1 ? "was" : "were") uninstalled in Steam and removed from your library.") }
            libraryNotice = notes.joined(separator: " ")
        }
        let launchers = engine.steamLaunchers(in: games)
        if steamTimer == nil, !launchers.isEmpty {
            steamTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    await self?.refreshSteamRunning()
                }
            }
        }
    }

    /// Which Steam entries are running now, from Steam's log (games) and its bottle (Steam).
    func refreshSteamRunning() async {
        guard let engine else { return }
        if Date().timeIntervalSince(lastSteamSync) > 15 {
            lastSteamSync = Date()
            refreshSteam()
        }
        let active = await engine.activeBottlePrefixes()
        var now: Set<String> = []
        for game in games {
            // A game counts as running only while its bottle's Wine is up and Steam's log says
            // so (a log left by a Steam that was stopped mid-game would otherwise say "running").
            guard engine.isBottleActive(game, active: active) else { continue }
            if game.steam != nil {
                if engine.steamGameState(game).running { now.insert(game.id) }
            } else if engine.isSteamLauncher(game) {
                now.insert(game.id)
            }
        }
        // A Steam game Distiller started: once Steam reports it running, track it by the log;
        // when the log says it stopped, the session is over.
        for (id, started) in steamLaunching {
            if now.contains(id) {
                steamLaunching[id] = nil
                steamSessions[id] = started
            } else if Date().timeIntervalSince(started) > 180 {
                steamLaunching[id] = nil       // never started (the player cancelled in Steam)
            }
        }
        for (id, started) in steamSessions where !now.contains(id) {
            steamSessions[id] = nil
            if let game = games.first(where: { $0.id == id }) { finishedSteamGame(game, started: started) }
        }
        if now != steamRunning { steamRunning = now }
    }

    func isSteamLauncher(_ game: Game) -> Bool {
        engine?.isSteamLauncher(game) ?? false
    }

    /// Whether a Steam entry counts as running (or is starting).
    func isSteamActive(_ game: Game) -> Bool {
        steamRunning.contains(game.id) || steamLaunching[game.id] != nil
    }

    func launchSteamGame(_ game: Game) {
        guard let engine else { return }
        Task {
            do {
                if (try? engine.pendingWineMove(for: game)) != nil { try await prepareWineMove(for: game) }
                // Starts Steam if it isn't running; otherwise hands the launch to it and exits.
                _ = try engine.launch(game)
                steamLaunching[game.id] = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopSteamGame(_ game: Game) {
        guard let engine else { return }
        perform("Stopping \(game.title)…") {
            try await engine.stopSteamGame(game)
        }
    }

    /// Asks Steam to uninstall the game; its entry goes once Steam has removed it.
    func uninstallSteamGame(_ game: Game) {
        guard let engine else { return }
        do {
            try engine.uninstallSteamGame(game)
            libraryNotice = "Steam asks you to confirm uninstalling \(game.title). It leaves your library once Steam has removed it."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishedSteamGame(_ game: Game, started: Date) {
        guard let engine else { return }
        let seconds = Date().timeIntervalSince(started)
        var updated = (try? engine.library.game(id: game.id)) ?? game
        updated.lastPlayedAt = Date()
        updated.secondsPlayed += seconds
        try? engine.library.upsert(updated)
        reload()
        if seconds > 120 { gameToReport = updated }
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

// MARK: Launchers in the library

extension AppModel {
    static let collapsedLaunchersKey = "CollapsedLaunchers"

    /// Games and launchers, without the games launchers installed (they show under their launcher).
    var topLevelGames: [Game] {
        games.filter { $0.steam == nil }
    }

    /// The games a launcher installed, A to Z.
    func launcherGames(_ launcher: Game) -> [Game] {
        games.filter { $0.steam?.launcherID == launcher.id }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Whether a launcher's games are shown (open unless the player closed it; remembered).
    func isExpanded(_ launcher: Game) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: Self.collapsedLaunchersKey) ?? []).contains(launcher.id)
    }

    func setExpanded(_ launcher: Game, _ expanded: Bool) {
        var collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedLaunchersKey) ?? [])
        if expanded { collapsed.remove(launcher.id) } else { collapsed.insert(launcher.id) }
        UserDefaults.standard.set(Array(collapsed).sorted(), forKey: Self.collapsedLaunchersKey)
        launcherExpansionChanged.toggle()
    }
}
