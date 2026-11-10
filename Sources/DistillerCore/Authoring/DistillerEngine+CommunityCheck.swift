import Foundation

/// How a community check session ended.
public enum CommunityCheckOutcome: Sendable {
    /// The game reached its login screen or menu. `program` starts the game (it becomes the
    /// recipe's launch program); `screenshots` are the player's captures, in order.
    case works(program: ProgramInBottle, screenshots: [Data])
    /// It didn't get that far.
    case doesNotWork
    /// The player stopped the check.
    case cancelled
}

/// How the community check talks to the player. The app shows its capture panel, the CLI
/// prompts; tests answer directly.
public struct CommunityCheckPrompts: Sendable {
    /// Called once the installer has started. The session lasts until this returns: the
    /// player follows the installer, starts or chooses the game (which may already be running,
    /// started by the installer itself), captures screenshots and says whether it works.
    public var session: @Sendable (CommunityCheckSession) async -> CommunityCheckOutcome
    /// For an installer with only a download page: the player downloads it from the page and
    /// this returns the file, or nil to cancel the check. The file isn't changed or removed.
    public var obtainInstaller: @Sendable (PageDownloadRequest) async -> URL?

    public init(
        obtainInstaller: @escaping @Sendable (PageDownloadRequest) async -> URL? = { _ in nil },
        session: @escaping @Sendable (CommunityCheckSession) async -> CommunityCheckOutcome
    ) {
        self.obtainInstaller = obtainInstaller
        self.session = session
    }
}

/// A community check in progress: the test bottle with the recipe's settings and its
/// installer running. Many installers start a launcher, an updater or the game itself and
/// never "finish", so nothing waits for the installer: the player decides when the game is
/// running, from what's running in the bottle or by starting an installed program.
public final class CommunityCheckSession: @unchecked Sendable {
    public let title: String
    public let startedAt: Date
    /// The program the player's own recipe launches (such as "Game.exe"), to suggest.
    public let suggestedProgramName: String?

    let driveC: URL
    let wine: InstalledComponent
    let environment: [String: String]
    let runner: WineRunner
    private let installer: Process
    private let lock = NSLock()
    private var started: [Process] = []

    init(title: String, startedAt: Date, suggestedProgramName: String?, driveC: URL, wine: InstalledComponent,
         environment: [String: String], runner: WineRunner, installer: Process) {
        self.title = title
        self.startedAt = startedAt
        self.suggestedProgramName = suggestedProgramName
        self.driveC = driveC
        self.wine = wine
        self.environment = environment
        self.runner = runner
        self.installer = installer
    }

    /// True while the installer's own process is running.
    public var installerIsRunning: Bool { installer.isRunning }

    /// The Windows programs running in the test bottle now, not counting Wine's own, that
    /// could be the game: whatever the installer started (a launcher, the game) and anything
    /// the player started. Empty if Wine can't be asked.
    public func runningPrograms() async -> [ProgramInBottle] {
        let running = (try? await runner.runningPrograms(wine: wine, environment: environment)) ?? []
        return Self.programs(from: running, driveC: driveC)
    }

    /// The programs installed on drive C:, most likely game first, and the one to suggest.
    public func installedPrograms() -> (programs: [ProgramInBottle], suggested: ProgramInBottle?) {
        let programs = ProgramFinder.find(in: driveC).map { program in
            ProgramInBottle(program: program, windowsPath: BottlePath.windowsPath(relativeComponents: program.relativePath.split(separator: "/").map(String.init)))
        }
        let suggested = programs.first { $0.program.name.lowercased() == suggestedProgramName?.lowercased() } ?? programs.first
        return (programs, suggested)
    }

    /// Starts an installed program in the test bottle.
    public func start(_ program: ProgramInBottle) throws {
        let process = try runner.launch(
            program: program.program.url.path, arguments: [], wine: wine, environment: environment,
            workingDirectory: program.program.url.deletingLastPathComponent(),
            logName: "check-\(program.program.url.deletingPathExtension().lastPathComponent)"
        )
        lock.withLock { started.append(process) }
    }

    /// Running programs on drive C: that aren't Wine's own, as programs in the bottle,
    /// once each (a program can run several processes).
    static func programs(from running: [RunningWindowsProgram], driveC: URL) -> [ProgramInBottle] {
        var seen = Set<String>()
        return running.compactMap { process in
            guard !process.isWineSystemProgram else { return nil }
            let windowsPath = process.windowsPath.replacingOccurrences(of: "/", with: "\\")
            guard windowsPath.lowercased().hasPrefix("c:\\"), seen.insert(windowsPath.lowercased()).inserted else { return nil }
            let components = windowsPath.dropFirst(3).split(separator: "\\").map(String.init)
            guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
            let url = components.reduce(driveC) { $0.appendingPathComponent($1) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let program = DiscoveredProgram(relativePath: components.joined(separator: "/"), url: url, size: size, score: 0)
            return ProgramInBottle(program: program, windowsPath: windowsPath)
        }
    }

    func terminateStarted() {
        for process in lock.withLock({ started }) + [installer] where process.isRunning { process.terminate() }
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
    /// starts the installer, and hands over to the player (`CommunityCheckPrompts.session`):
    /// they follow the installer, choose the game's program while it runs (or start it), and
    /// say whether it reached its login or menu. On "yes" the shareable recipe is saved with the
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
        guard let publicInstaller = game.recipe.game.installer else {
            throw DistillerError.invalidRecipe("it has no official public installer. Add its download link or download page (game.installer) first.")
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

        // Get the installer once, to learn its SHA-256 and put it where the recipe expects it:
        // from its direct link, or from the player, who downloads it from the publisher's page.
        let destination: URL
        let installerName: String
        let sha256: String
        var fileName: String?
        if let link = publicInstaller.url {
            guard let url = URL(string: link) else { throw DistillerError.insecureURL(link) }
            installerName = url.lastPathComponent
            destination = try BottlePath.resolve(try Self.installerTarget(publicInstaller, fileName: nil), in: root)
            progress("Downloading \(url.lastPathComponent) from \(url.host ?? "the publisher")")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            sha256 = try await Downloader.download(url, to: destination)
        } else if let pageLink = publicInstaller.page, let page = URL(string: pageLink) {
            progress("Waiting for the installer from \(page.host ?? "the publisher's download page")")
            let request = PageDownloadRequest(
                id: CommunityCheck.installerDownloadID, title: game.title,
                prompt: "Download \(game.title)'s installer from its publisher's download page.", page: page)
            guard let file = await prompts.obtainInstaller(request) else {
                throw DistillerError.setupFailed("The community check was cancelled.")
            }
            fileName = RecipeDraft.windowsSafeName(file.lastPathComponent)
            installerName = file.lastPathComponent
            destination = try BottlePath.resolve(try Self.installerTarget(publicInstaller, fileName: fileName), in: root)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try APFSClone.replaceItem(at: destination, withCloneOf: file)
            sha256 = try Checksum.sha256(of: destination)
        } else {
            throw DistillerError.invalidRecipe("game.installer needs its download link (url) or its download page (page).")
        }
        // An installer that changes with every update is verified by its publisher's signature,
        // which goes in the shared recipe instead of this copy's checksum.
        var signer: String?
        if publicInstaller.updates == true {
            progress("Checking \(installerName)'s publisher signature")
            do {
                signer = try Authenticode.verify(destination).signer
            } catch {
                throw DistillerError.invalidRecipe("the installer is marked as changing with updates, so it's checked by its publisher's signature, but \(installerName) can't be: \(error.localizedDescription)")
            }
        }

        let withoutLaunch = try CommunityCheck.shareableRecipe(from: game.recipe, installerSHA256: sha256, installerSigner: signer, installerFileName: fileName, launchExe: nil)
        let resolved = resolve(withoutLaunch)
        try await applySettings(resolved, in: bottle, stack: stack, progress: progress)

        // Start the installer without waiting for it: from here the player is in charge.
        guard let installerStep = resolved.install.last(where: { if case .runWindows = $0 { return true }; return false }),
              case .runWindows(let run) = installerStep else {
            throw DistillerError.invalidRecipe("couldn't plan the installer run.")
        }
        let prefix = bottles.prefix(of: bottle)
        if let graphics = stack.graphics { try GraphicsPlacer.installPrefixDLLs(graphics, prefix: prefix) }
        let environment = WineEnvironment.build(prefix: prefix, wine: stack.wine, graphics: stack.graphics, resolved: resolved)
        let installerProgram = try RecipeInstaller.onDriveC(BottlePath.resolve(run.path, in: root), prefix: prefix, environment: environment)
        progress("Running the installer. Follow its steps; when the game is running, say so in the Community Check panel.")
        let startedAt = Date().addingTimeInterval(-2)
        let installerProcess = try runner.launch(
            program: installerProgram.path, arguments: run.args ?? [], wine: stack.wine, environment: environment,
            workingDirectory: installerProgram.deletingLastPathComponent(),
            logName: "check-install-\(installerProgram.deletingPathExtension().lastPathComponent)"
        )
        let session = CommunityCheckSession(
            title: game.title, startedAt: startedAt,
            suggestedProgramName: game.recipe.launch.map { ($0.exe.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent },
            driveC: prefix.appendingPathComponent("drive_c", isDirectory: true),
            wine: stack.wine, environment: environment, runner: runner, installer: installerProcess
        )
        let outcome = await prompts.session(session)
        progress("Stopping everything in the test bottle")
        try? await runner.killAll(wine: stack.wine, environment: environment)
        session.terminateStarted()

        let chosen: ProgramInBottle
        let screenshots: [Data]
        switch outcome {
        case .works(let program, let captures):
            chosen = program
            screenshots = captures
        case .doesNotWork:
            throw DistillerError.setupFailed("The community check didn't pass: \(game.title) didn't reach its login or menu. The recipe can't be submitted until it does.")
        case .cancelled:
            throw DistillerError.setupFailed("The community check was cancelled.")
        }
        let shareable = try CommunityCheck.shareableRecipe(from: game.recipe, installerSHA256: sha256, installerSigner: signer, installerFileName: fileName, launchExe: chosen.windowsPath)
        try RecipeLoader.validate(shareable)
        let launchedAt = startedAt

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
        for data in (screenshots + saved.compactMap { try? Data(contentsOf: $0) }).prefix(CommunityMedia.maxCaptures) {
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
            sharedCaptures: captures.isEmpty ? nil : Array(captures.prefix(CommunityMedia.maxSharedScreenshots)),
            installerSigner: signer
        )
        var updated = (try? library.game(id: game.id)) ?? game
        updated.communityCheck = check
        try library.upsert(updated)
        succeeded = true
        if keepBottle { try? "kept".write(to: root.appendingPathComponent(Self.communityCheckOwnerFile), atomically: true, encoding: .utf8) }
        progress(keepBottle ? "Passed. The test bottle is kept at \(root.path)." : "Passed. The test bottle was removed.")
        return updated
    }

    /// Applies the shareable recipe's settings and runs its other install steps (winetricks,
    /// registry, DLL overrides): everything but the installer download, which the check has
    /// already done, and the installer run, which the check starts itself.
    /// Where the installer goes in the bottle (the first of `CommunityCheck.installerSteps`).
    static func installerTarget(_ installer: PublicInstaller, fileName: String?) throws -> String {
        switch try CommunityCheck.installerSteps(installer, sha256: String(repeating: "0", count: 64), fileName: fileName).first {
        case .download(let download)?: return download.to
        case .userDownload(let download)?: return download.to
        default: throw DistillerError.invalidRecipe("couldn't plan the installer download.")
        }
    }

    private func applySettings(_ resolved: ResolvedRecipe, in bottle: Bottle, stack: (wine: InstalledComponent, graphics: InstalledComponent?), progress: @escaping @Sendable (String) -> Void) async throws {
        try await installer.configurePrefix(resolved, in: bottle, wine: stack.wine, graphics: stack.graphics) { _, message in
            progress(message)
        }
        let steps = resolved.install.filter { step in
            switch step {
            case .download, .userDownload, .runWindows: return false
            default: return true
            }
        }
        guard !steps.isEmpty else { return }
        try await installer.runSteps(steps, in: bottle, resolved: resolved, wine: stack.wine, graphics: stack.graphics, supplied: UserSupplied()) { _, message in
            progress(message)
        }
    }
}
