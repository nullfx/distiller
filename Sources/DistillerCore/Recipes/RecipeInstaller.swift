import Foundation
import Security

public struct InstallProgress: Sendable {
    public var step: Int
    public var total: Int
    public var message: String

    public init(step: Int, total: Int, message: String) {
        self.step = step
        self.total = total
        self.message = message
    }
}

/// A folder the player chose for a `user_folder` step.
public struct UserFolderSource: Sendable, Equatable {
    public var url: URL
    /// Link the folder into the bottle instead of copying it. Saves time and disk space for
    /// a large game on another drive, but the game then writes into the original folder.
    public var linkInPlace: Bool

    public init(url: URL, linkInPlace: Bool = false) {
        self.url = url
        self.linkInPlace = linkInPlace
    }
}

/// What the player supplied for a recipe's `user_file` and `user_folder` steps, by step id.
public struct UserSupplied: Sendable, Equatable {
    public var files: [String: URL]
    public var folders: [String: UserFolderSource]

    public init(files: [String: URL] = [:], folders: [String: UserFolderSource] = [:]) {
        self.files = files
        self.folders = folders
    }
}

/// Applies a resolved recipe to a new bottle: Windows version, registry, graphics DLLs,
/// winetricks, then the recipe's own install steps in order.
public final class RecipeInstaller: @unchecked Sendable {
    let runner: WineRunner
    let bottles: BottleStore
    let components: ComponentStore

    /// The number of progress steps `configurePrefix` reports: three, then one per winetricks
    /// component (`InstallPlan.configureTasks`).
    public static func configureStepCount(for resolved: ResolvedRecipe) -> Int {
        InstallPlan.configureTasks(resolved).count
    }

    public init(runner: WineRunner, bottles: BottleStore, components: ComponentStore) {
        self.runner = runner
        self.bottles = bottles
        self.components = components
    }

    public func install(
        _ resolved: ResolvedRecipe,
        in bottle: Bottle,
        wine: InstalledComponent,
        graphics: InstalledComponent?,
        supplied: UserSupplied,
        cancellation: InstallCancellation? = nil,
        progress: @escaping @Sendable (InstallProgress) -> Void
    ) async throws {
        // Step 1, creating the bottle, is the engine's (`InstallPlan.tasks`).
        let total = InstallPlan.tasks(for: resolved).count
        let configured = Self.configureStepCount(for: resolved)
        try await configurePrefix(resolved, in: bottle, wine: wine, graphics: graphics, cancellation: cancellation) { step, message in
            progress(InstallProgress(step: 1 + step, total: total, message: message))
        }
        try await runSteps(resolved.install, in: bottle, resolved: resolved, wine: wine, graphics: graphics, supplied: supplied, cancellation: cancellation) { index, message in
            progress(InstallProgress(step: 1 + configured + index, total: total, message: message))
        }
    }

    /// The prefix-wide settings: Windows version, registry, graphics DLLs and winetricks.
    /// Safe to run again on an existing bottle after the recipe changes; winetricks skips
    /// verbs that are already installed.
    public func configurePrefix(
        _ resolved: ResolvedRecipe,
        in bottle: Bottle,
        wine: InstalledComponent,
        graphics: InstalledComponent?,
        cancellation: InstallCancellation? = nil,
        progress: @escaping @Sendable (Int, String) -> Void
    ) async throws {
        let prefix = bottles.prefix(of: bottle)
        let env = WineEnvironment.build(prefix: prefix, wine: wine, graphics: graphics, resolved: resolved)
        let titles = InstallPlan.configureTasks(resolved).map(\.title)

        try cancellation?.check()
        progress(1, titles[0])
        try await runner.setWindowsVersion(resolved.windowsVersion, wine: wine, environment: env)

        try cancellation?.check()
        progress(2, titles[1])
        var registry = resolved.registry
        registry.append(RegistryEdit(
            key: "HKCU\\Software\\Wine\\Mac Driver",
            values: ["RetinaMode": .string(resolved.retina ? "y" : "n")]
        ))
        try await runner.importRegistry(registry, prefix: prefix, wine: wine, environment: env)

        try cancellation?.check()
        progress(3, titles[2])
        if let graphics {
            try GraphicsPlacer.installPrefixDLLs(graphics, prefix: prefix)
        }

        // One component at a time, so the player sees which one is running (some, such as
        // .NET Framework, take half an hour or more).
        if !resolved.winetricks.isEmpty {
            guard let winetricks = components.winetricks() else { throw DistillerError.componentNotFound("winetricks") }
            for (index, verb) in resolved.winetricks.enumerated() {
                try cancellation?.check()
                progress(4 + index, titles[3 + index])
                try await runner.runWinetricks([verb], winetricks: winetricks, wine: wine, environment: env)
            }
        }
    }

    /// Runs install steps in order. `progress` gets the 1-based index of each step.
    public func runSteps(
        _ steps: [InstallStep],
        in bottle: Bottle,
        resolved: ResolvedRecipe?,
        wine: InstalledComponent,
        graphics: InstalledComponent?,
        supplied: UserSupplied,
        cancellation: InstallCancellation? = nil,
        progress: @escaping @Sendable (Int, String) -> Void = { _, _ in }
    ) async throws {
        let root = bottles.root(of: bottle)
        let prefix = bottles.prefix(of: bottle)
        let env = WineEnvironment.build(prefix: prefix, wine: wine, graphics: graphics, resolved: resolved)
        let gameProgram = resolved?.launch.flatMap { try? BottlePath.resolve($0.exe, in: root) }
        for (index, step) in steps.enumerated() {
            try cancellation?.check()
            progress(index + 1, InstallPlan.step(step).title)
            if case .runWindows(let run) = step, run.wait ?? true {
                // Don't wait for a launcher or the game that the installer leaves running.
                let program = try BottlePath.resolve(run.path, in: root)
                try await runner.runWindowsProgram(program, arguments: run.args ?? [], wine: wine, environment: env, wait: false)
                let runner = self.runner
                let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
                let exited = try await runner.waitForServer(wine: wine, environment: env) {
                    guard let gameProgram, FileManager.default.fileExists(atPath: gameProgram.followingSymlinks.path) else { return false }
                    let running = (try? await runner.runningPrograms(wine: wine, environment: env)) ?? []
                    return Self.programStartedByInstaller(CommunityCheckSession.programs(from: running, driveC: driveC), gameProgram: gameProgram) != nil
                }
                if !exited, let gameProgram {
                    progress(index + 1, "The installer left \(gameProgram.deletingLastPathComponent().lastPathComponent) running; the install is done")
                }
                continue
            }
            try await perform(step, root: root, prefix: prefix, wine: wine, environment: env, supplied: supplied)
        }
    }

    /// A program the installer started from the game's own folder (its launcher, or the game),
    /// which may keep running after the install. Programs in that folder that install or
    /// uninstall things don't count, and nor do programs in its subfolders (often runtimes'
    /// installers).
    static func programStartedByInstaller(_ running: [ProgramInBottle], gameProgram: URL) -> ProgramInBottle? {
        let folder = gameProgram.deletingLastPathComponent().standardizedFileURL.path.lowercased()
        let installerWords = ["setup", "install", "unins", "redist", "dxsetup", "vcredist", "update", "patch"]
        return running.first { candidate in
            let url = candidate.program.url.standardizedFileURL
            let name = url.lastPathComponent.lowercased()
            return url.deletingLastPathComponent().path.lowercased() == folder
                && !installerWords.contains { name.contains($0) }
        }
    }

    func perform(
        _ step: InstallStep,
        root: URL,
        prefix: URL,
        wine: InstalledComponent,
        environment: [String: String],
        supplied: UserSupplied
    ) async throws {
        let fileManager = FileManager.default
        switch step {
        case .download(let download):
            guard let url = URL(string: download.url) else { throw DistillerError.insecureURL(download.url) }
            let destination = try BottlePath.resolve(download.to, in: root)
            if let signer = download.signer {
                try await Downloader.download(url, signer: signer, to: destination)
            } else if let sha256 = download.sha256 {
                try await Downloader.download(url, sha256: sha256, to: destination)
            } else {
                throw DistillerError.invalidRecipe("The download \(download.url) has neither a sha256 nor a signer.")
            }

        case .extract(let extract):
            let archive = try BottlePath.resolve(extract.archive, in: root)
            let destination = try BottlePath.resolve(extract.to, in: root)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let result = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xf", archive.path, "-C", destination.path]
            )
            guard result.status == 0 else {
                throw DistillerError.processFailed(command: "Extracting \(extract.archive)", status: result.status, logFile: nil)
            }

        case .winetricks(let verbs):
            guard let winetricks = components.winetricks() else { throw DistillerError.componentNotFound("winetricks") }
            try await runner.runWinetricks(verbs, winetricks: winetricks, wine: wine, environment: environment)

        case .registry(let edit):
            try await runner.importRegistry([edit], prefix: prefix, wine: wine, environment: environment)

        case .dllOverride(let overrides):
            let edit = RegistryEdit(key: "HKCU\\Software\\Wine\\DllOverrides", values: overrides.mapValues { .string($0) })
            try await runner.importRegistry([edit], prefix: prefix, wine: wine, environment: environment)

        case .copy(let copy):
            let source = try BottlePath.resolve(copy.from, in: root)
            let destination = try BottlePath.resolve(copy.to, in: root)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try APFSClone.replaceItem(at: destination, withCloneOf: source)

        case .runWindows(let run):
            let program = try BottlePath.resolve(run.path, in: root)
            try await runner.runWindowsProgram(
                program, arguments: run.args ?? [], wine: wine, environment: environment, wait: run.wait ?? true
            )

        case .userFile(let file):
            guard let source = supplied.files[file.id] else { throw DistillerError.missingUserFile(file.prompt) }
            let destination = try BottlePath.resolve(file.to, in: root)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try APFSClone.replaceItem(at: destination, withCloneOf: source)

        case .userDownload(let download):
            guard let source = supplied.files[download.id] else { throw DistillerError.missingUserFile(download.prompt) }
            try Self.verify(source, sha256: download.sha256, signer: download.signer)
            let destination = try BottlePath.resolve(download.to, in: root)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try APFSClone.replaceItem(at: destination, withCloneOf: source)

        case .userFolder(let folder):
            guard let source = supplied.folders[folder.id] else { throw DistillerError.missingUserFile(folder.prompt) }
            let destination = try BottlePath.resolve(folder.to, in: root)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if source.linkInPlace {
                if fileManager.fileExists(atPath: destination.path) || APFSClone.isSymlink(destination) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.createSymbolicLink(at: destination, withDestinationURL: source.url)
                // A folder on another drive also gets that drive mapped (D:, E:, …), so the
                // game runs from, and sees, its real drive.
                try DriveMapper.mapVolume(of: source.url, in: root.appendingPathComponent("prefix", isDirectory: true))
            } else {
                try APFSClone.replaceItem(at: destination, withCloneOf: source.url)
            }
        }
    }

    /// The files a recipe's steps ask the player to download from a publisher's page.
    public static func pageDownloads(in recipe: Recipe) -> [(step: InstallStep.UserDownload, request: PageDownloadRequest)] {
        (recipe.install ?? []).compactMap { step in
            guard case .userDownload(let download) = step, let page = URL(string: download.page) else { return nil }
            return (download, PageDownloadRequest(id: download.id, title: recipe.game.title, prompt: download.prompt, page: page))
        }
    }

    /// Checks a file the player downloaded for `download` before installing, so a wrong file
    /// is caught while they're still on the page.
    public static func checkPageDownload(_ file: URL, for download: InstallStep.UserDownload) throws {
        try verify(file, sha256: download.sha256, signer: download.signer)
    }

    /// Checks a file the player downloaded the way a recipe download is checked.
    static func verify(_ file: URL, sha256: String?, signer: String?, anchors: [SecCertificate]? = nil) throws {
        if let sha256 {
            try Checksum.verify(file, expected: sha256)
        } else if let signer {
            do {
                _ = try Authenticode.verify(file, expectedSigner: signer, anchors: anchors)
            } catch {
                throw DistillerError.invalidRecipe("\(file.lastPathComponent) can't be trusted: \(error.localizedDescription)")
            }
        } else {
            throw DistillerError.invalidRecipe("\(file.lastPathComponent) has nothing to be checked against.")
        }
    }
}
