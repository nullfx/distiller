import Foundation
import DistillerCore

/// Launchers in the library (Steam, Battle.net): the games they install get entries of their own
/// (`syncLauncherGames`), Play starts them through the launcher, and their running state comes
/// from the launcher (Steam's log) or the bottle's processes (Battle.net), not the program
/// Distiller started: launchers hand launches over, or restart themselves. A launcher's own
/// entry counts as running while its bottle's Wine is up.
extension AppModel {
    /// Adds and removes launchers' games, and refreshes which are running. Called on every
    /// reload, and every few seconds while there's a launcher.
    func refreshLaunchers() {
        guard let engine else { return }
        let sync = engine.syncLauncherGames()
        if !sync.isEmpty {
            games = engine.library.load()
            refreshLibraryState()
            var notes: [String] = []
            for kind in LauncherKind.allCases {
                let added = sync.added.filter { $0.launchedBy?.kind == kind }.map(\.title)
                let removed = sync.removed.filter { $0.launchedBy?.kind == kind }.map(\.title)
                if !added.isEmpty { notes.append("\(Self.list(added)) \(added.count == 1 ? "was" : "were") installed in \(kind.displayName) and added to your library.") }
                if !removed.isEmpty { notes.append("\(Self.list(removed)) \(removed.count == 1 ? "was" : "were") uninstalled in \(kind.displayName) and removed from your library.") }
            }
            showLibraryNotice(notes.joined(separator: " "))
        }
        if launcherTimer == nil, !engine.launchers(in: games).isEmpty {
            launcherTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    await self?.refreshLauncherRunning()
                }
            }
        }
    }

    /// Which launcher entries are running now.
    func refreshLauncherRunning() async {
        guard let engine else { return }
        if Date().timeIntervalSince(lastLauncherSync) > 15 {
            lastLauncherSync = Date()
            refreshLaunchers()
        }
        let processes = await engine.bottleProcesses()
        var now: Set<String> = []
        for game in games {
            // A game counts as running only while its bottle's Wine is up (a log left by a
            // launcher stopped mid-game would otherwise say "running").
            guard engine.isBottleActive(game, active: processes.active) else { continue }
            if game.launchedBy != nil {
                if engine.launcherGameState(game, processes: processes).running { now.insert(game.id) }
            } else if engine.isLauncher(game) {
                now.insert(game.id)
            }
        }
        // A launcher's game Distiller started: once the launcher reports it running, track it;
        // when it stops, the session is over.
        for (id, started) in launcherLaunching {
            if now.contains(id) {
                launcherLaunching[id] = nil
                launcherSessions[id] = started
            } else if Date().timeIntervalSince(started) > 180 {
                launcherLaunching[id] = nil       // never started (the player cancelled in the launcher)
            }
        }
        for (id, started) in launcherSessions where !now.contains(id) {
            launcherSessions[id] = nil
            if let game = games.first(where: { $0.id == id }) { finishedLauncherGame(game, started: started) }
        }
        if now != launcherRunning { launcherRunning = now }
    }

    /// How the player wants a launcher started (Steam's view and Friends status).
    func setLauncherOptions(_ options: LauncherOptions, for launcher: Game) {
        guard let engine else { return }
        do {
            try engine.setLauncherOptions(options, for: launcher.id)
            games = engine.library.load()
            if gameInWorkshop?.id == launcher.id { gameInWorkshop = try? engine.library.game(id: launcher.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isLauncher(_ game: Game) -> Bool {
        engine?.isLauncher(game) ?? false
    }

    func launcherKind(of game: Game) -> LauncherKind? {
        engine?.launcherKind(of: game)
    }

    /// Whether a launcher or launcher's game counts as running (or is starting).
    func isLauncherActive(_ game: Game) -> Bool {
        launcherRunning.contains(game.id) || launcherLaunching[game.id] != nil
    }

    func launchLauncherGame(_ game: Game) {
        guard let engine else { return }
        Task {
            do {
                if (try? engine.pendingWineMove(for: game)) != nil { try await prepareWineMove(for: game) }
                // Starts the launcher if it isn't running (with the player's start options);
                // otherwise hands the launch to it.
                let startingLauncher = !engine.isBottleActive(game, active: await engine.activeBottlePrefixes())
                _ = try engine.launch(game, startingLauncher: startingLauncher)
                launcherLaunching[game.id] = Date()
                if startingLauncher { Task { await engine.applyLauncherOptionsAfterStart(for: game) } }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopLauncherGame(_ game: Game) {
        guard let engine else { return }
        perform("Stopping \(game.title)…") {
            try await engine.stopLauncherGame(game)
        }
    }

    /// Asks the launcher to uninstall the game; its entry goes once the launcher has removed it.
    func uninstallLauncherGame(_ game: Game) {
        guard let engine, let link = game.launchedBy else { return }
        do {
            try engine.uninstallLauncherGame(game)
            switch link.kind {
            case .steam:
                showLibraryNotice("Steam asks you to confirm uninstalling \(game.title). It leaves your library once Steam has removed it.")
            case .battlenet:
                showLibraryNotice("Uninstall \(game.title) in Battle.net: on its page, the gear next to Play ▸ Uninstall. It leaves your library once Battle.net has removed it.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishedLauncherGame(_ game: Game, started: Date) {
        guard let engine else { return }
        let seconds = Date().timeIntervalSince(started)
        var updated = (try? engine.library.game(id: game.id)) ?? game
        updated.lastPlayedAt = Date()
        updated.secondsPlayed += seconds
        try? engine.library.upsert(updated)
        reload()
        if seconds > 120 { gameToReport = updated }
    }

    /// Shows a notice over the library for a few seconds (longer for longer notices).
    func showLibraryNotice(_ text: String) {
        libraryNotice = text
        libraryNoticeTask?.cancel()
        libraryNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(20, 8 + Double(text.count) / 25)))
            guard !Task.isCancelled else { return }
            self?.libraryNotice = nil
        }
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
        games.filter { $0.launchedBy == nil }
    }

    /// The games a launcher installed, A to Z.
    func launcherGames(_ launcher: Game) -> [Game] {
        games.filter { $0.launchedBy?.launcherID == launcher.id }
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
