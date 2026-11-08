import Foundation

/// The player's answer while the game runs in the community check.
public struct CommunityCheckAnswer: Sendable {
    /// The game reached its login screen or menu.
    public var works: Bool
    /// Captures of the game's window the player took while it ran (any image format), in order.
    public var screenshots: [Data]

    public init(works: Bool, screenshots: [Data] = []) {
        self.works = works
        self.screenshots = screenshots
    }

    public static let doesNotWork = CommunityCheckAnswer(works: false)
}

/// How the community check talks to the player. The app answers with dialogs, the CLI with
/// prompts; tests answer directly.
public struct CommunityCheckPrompts: Sendable {
    /// Picks the installed program to launch. `suggested` matches the player's own recipe
    /// when possible. Return nil to cancel.
    public var chooseProgram: @Sendable (_ programs: [ProgramInBottle], _ suggested: ProgramInBottle?) async -> ProgramInBottle?
    /// Asked while the game is running: did it reach its login screen or menu? `programName`
    /// is the launched program's file name (such as "Game.exe"), for finding its window to
    /// capture a screenshot.
    public var confirmRunning: @Sendable (_ title: String, _ programName: String) async -> CommunityCheckAnswer

    public init(
        chooseProgram: @escaping @Sendable ([ProgramInBottle], ProgramInBottle?) async -> ProgramInBottle?,
        confirmRunning: @escaping @Sendable (String, String) async -> CommunityCheckAnswer
    ) {
        self.chooseProgram = chooseProgram
        self.confirmRunning = confirmRunning
    }
}

extension DistillerEngine {
    public static let communityCheckBottleSuffix = " (community check)"
    /// Written in a check's bottle while the check runs: the process running it, or "kept"
    /// when the player asked to keep the bottle (`keepBottle`).
    static let communityCheckOwnerFile = "community-check.pid"

    /// Test bottles left behind by community checks that never finished (the app quit or
    /// crashed mid-check), oldest first. None of them belongs to a game in the library.
    public func orphanedCommunityCheckBottles() -> [Bottle] {
        let used = Set(library.load().map(\.bottleID))
        return bottles.list()
            .filter { $0.name.hasSuffix(Self.communityCheckBottleSuffix) && !used.contains($0.id) && !isClaimed($0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Whether a check bottle is still in use (its check is running) or was kept on purpose.
    func isClaimed(_ bottle: Bottle) -> Bool {
        let file = bottles.root(of: bottle).appendingPathComponent(Self.communityCheckOwnerFile)
        guard let text = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if text == "kept" { return true }
        guard let pid = Int32(text), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Copies the screenshots a game saved in an orphaned check bottle to
    /// `~/Pictures/Distiller/<game title>/` (or `destination`), then deletes the bottle.
    /// Returns the copies. Existing files there are never overwritten.
    @discardableResult
    public func removeOrphanedCommunityCheckBottle(_ bottle: Bottle, rescuingScreenshotsTo destination: URL? = nil) throws -> [URL] {
        guard bottle.name.hasSuffix(Self.communityCheckBottleSuffix), !library.load().contains(where: { $0.bottleID == bottle.id }),
              !isClaimed(bottle) else {
            throw DistillerError.setupFailed("\(bottle.name) isn't a leftover community-check bottle.")
        }
        let title = String(bottle.name.dropLast(Self.communityCheckBottleSuffix.count))
        let folder = destination ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Distiller", isDirectory: true)
            .appendingPathComponent(title.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        var copies: [URL] = []
        let found = InGameScreenshots.find(inPrefix: bottles.prefix(of: bottle), since: bottle.createdAt, limit: 200)
        if !found.isEmpty {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for source in found {
                var target = folder.appendingPathComponent(source.lastPathComponent)
                var number = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(number).\(source.pathExtension)")
                    number += 1
                }
                try FileManager.default.copyItem(at: source, to: target)
                copies.append(target)
            }
        }
        // Deleted outright, like a finished check's bottle: the point is to free the space,
        // and the screenshots are already copied out.
        try FileManager.default.removeItem(at: bottles.root(of: bottle))
        return copies
    }

    /// Proves a recipe works for other players before it's shared: in a new bottle, downloads
    /// the game's official installer (recording its SHA-256), applies the recipe's settings,
    /// runs the installer, finds the installed program, launches it, and asks the player
    /// whether it reached its login or menu. On "yes" the shareable recipe is saved with the
    /// game as its `communityCheck`, along with the program's icon and the screenshots: those
    /// the player captured, then any the game saved itself in the bottle during the run (the
    /// first few are preselected for sharing). The test bottle is removed unless `keepBottle`.
    /// Its name ends in `communityCheckBottleSuffix`, so one left behind by an interrupted check
    /// can be found later (`orphanedCommunityCheckBottles`).
    @discardableResult
    public func runCommunityCheck(
        for game: Game,
        prompts: CommunityCheckPrompts,
        keepBottle: Bool = false,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Game {
        try paths.requireAvailable(.bottles)
        try paths.requireAvailable(.wine)
        guard let publicInstaller = game.recipe.game.installer, let url = URL(string: publicInstaller.url) else {
            throw DistillerError.invalidRecipe("it has no official public installer. Add its download link (game.installer.url) first.")
        }
        try RecipeLoader.validate(game.recipe)

        // The stack comes from the recipe's settings; the bottle is new, so any suitable Wine.
        let settingsOnly = try CommunityCheck.shareableRecipe(from: game.recipe, installerSHA256: String(repeating: "0", count: 64), launchExe: nil)
        let stack = try selectStack(for: resolve(settingsOnly))

        progress("Creating a test bottle")
        let bottle = try await bottles.makeBottle(name: game.title + Self.communityCheckBottleSuffix, wine: stack.wine, runner: runner)
        let root = bottles.root(of: bottle)
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: root.appendingPathComponent(Self.communityCheckOwnerFile), atomically: true, encoding: .utf8)
        var succeeded = false
        defer {
            if !keepBottle || !succeeded { try? FileManager.default.removeItem(at: root) }
        }

        // Download once, to learn the installer's SHA-256 and put it where the recipe expects it.
        let downloadTarget: String
        if case .download(let download)? = try CommunityCheck.installerSteps(publicInstaller, sha256: String(repeating: "0", count: 64)).first {
            downloadTarget = download.to
        } else {
            throw DistillerError.invalidRecipe("couldn't plan the installer download.")
        }
        progress("Downloading \(url.lastPathComponent) from \(url.host ?? "the publisher")")
        let destination = try BottlePath.resolve(downloadTarget, in: root)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sha256 = try await Downloader.download(url, to: destination)

        let withoutLaunch = try CommunityCheck.shareableRecipe(from: game.recipe, installerSHA256: sha256, launchExe: nil)
        let resolved = resolve(withoutLaunch)
        try await installShareable(resolved, in: bottle, stack: stack, progress: progress)

        progress("Looking for the installed program")
        let driveC = bottles.prefix(of: bottle).appendingPathComponent("drive_c", isDirectory: true)
        let programs = ProgramFinder.find(in: driveC).map { program in
            ProgramInBottle(program: program, windowsPath: BottlePath.windowsPath(relativeComponents: program.relativePath.split(separator: "/").map(String.init)))
        }
        guard !programs.isEmpty else {
            throw DistillerError.invalidRecipe("the installer finished, but no Windows program was found in the test bottle.")
        }
        let wanted = game.recipe.launch.map { ($0.exe.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased() }
        let suggested = programs.first { $0.program.name.lowercased() == wanted } ?? programs.first
        guard let chosen = await prompts.chooseProgram(programs, suggested) else {
            throw DistillerError.setupFailed("The community check was cancelled.")
        }

        let shareable = try CommunityCheck.shareableRecipe(from: game.recipe, installerSHA256: sha256, launchExe: chosen.windowsPath)
        try RecipeLoader.validate(shareable)
        let trial = Game(id: bottle.id, title: game.title, bottleID: bottle.id, recipe: shareable)

        progress("Starting \(game.title)")
        let launchedAt = Date().addingTimeInterval(-2)
        let process = try launch(trial)
        let answer = await prompts.confirmRunning(game.title, chosen.program.name)
        progress("Stopping \(game.title)")
        try? await stop(trial)
        if process.isRunning { process.terminate() }
        guard answer.works else {
            throw DistillerError.setupFailed("The community check didn't pass: \(game.title) didn't reach its login or menu. The recipe can't be submitted until it does.")
        }

        // The pictures that go with the submission: the installed program's icon, and the
        // screenshots from this run. Earlier ones are replaced, so they always match the check.
        let media = communityMediaFolder(for: game)
        try? FileManager.default.removeItem(at: media)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let icon = PEIcon.ico(fromExecutable: chosen.program.url).flatMap(CommunityMedia.icon(from:))
        if let icon { try icon.write(to: media.appendingPathComponent(CommunityMedia.iconFile), options: .atomic) }
        // Distiller's captures first, then any the game saved itself during the run.
        let saved = InGameScreenshots.find(
            inPrefix: bottles.prefix(of: bottle), programFolder: chosen.program.url.deletingLastPathComponent(), since: launchedAt
        )
        var captures: [String] = []
        for data in (answer.screenshots + saved.compactMap { try? Data(contentsOf: $0) }).prefix(CommunityMedia.maxCaptures) {
            guard let jpeg = CommunityMedia.screenshot(from: data) else { continue }
            let name = CommunityMedia.captureFile(captures.count + 1)
            try jpeg.write(to: media.appendingPathComponent(name), options: .atomic)
            captures.append(name)
        }

        let check = CommunityCheckResult(
            checkedAt: Date(),
            recipe: shareable,
            sourceFingerprint: CommunityCheck.fingerprint(game.recipe),
            installerSHA256: sha256,
            hardwareKey: hardware.hardwareKey,
            wine: stack.wine.manifest.composedFrom?.first ?? stack.wine.id,
            graphics: stack.graphics?.id,
            hasIcon: icon != nil ? true : nil,
            captures: captures.isEmpty ? nil : captures,
            sharedCaptures: captures.isEmpty ? nil : Array(captures.prefix(CommunityMedia.maxSharedScreenshots))
        )
        var updated = (try? library.game(id: game.id)) ?? game
        updated.communityCheck = check
        try library.upsert(updated)
        succeeded = true
        if keepBottle { try? "kept".write(to: root.appendingPathComponent(Self.communityCheckOwnerFile), atomically: true, encoding: .utf8) }
        progress(keepBottle ? "Passed. The test bottle is kept at \(root.path)." : "Passed. The test bottle was removed.")
        return updated
    }

    /// Applies the shareable recipe's settings and runs its install steps, skipping the
    /// download, which the check has already done.
    private func installShareable(_ resolved: ResolvedRecipe, in bottle: Bottle, stack: (wine: InstalledComponent, graphics: InstalledComponent?), progress: @escaping @Sendable (String) -> Void) async throws {
        try await installer.configurePrefix(resolved, in: bottle, wine: stack.wine, graphics: stack.graphics) { _, message in
            progress(message)
        }
        let steps = resolved.install.filter { step in
            if case .download = step { return false }
            return true
        }
        progress("Running the installer. Follow its steps if it asks you anything.")
        try await installer.runSteps(steps, in: bottle, resolved: resolved, wine: stack.wine, graphics: stack.graphics, supplied: UserSupplied()) { _, message in
            progress(message)
        }
    }
}
