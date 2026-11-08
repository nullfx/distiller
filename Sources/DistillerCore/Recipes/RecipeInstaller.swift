import Foundation

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

    /// The number of progress steps `configurePrefix` reports.
    public static let configureStepCount = 4

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
        progress: @escaping @Sendable (InstallProgress) -> Void
    ) async throws {
        let total = Self.configureStepCount + resolved.install.count
        try await configurePrefix(resolved, in: bottle, wine: wine, graphics: graphics) { step, message in
            progress(InstallProgress(step: step, total: total, message: message))
        }
        try await runSteps(resolved.install, in: bottle, resolved: resolved, wine: wine, graphics: graphics, supplied: supplied) { index, message in
            progress(InstallProgress(step: Self.configureStepCount + index, total: total, message: message))
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
        progress: @escaping @Sendable (Int, String) -> Void
    ) async throws {
        let prefix = bottles.prefix(of: bottle)
        let env = WineEnvironment.build(prefix: prefix, wine: wine, graphics: graphics, resolved: resolved)

        progress(1, "Setting the Windows version to \(resolved.windowsVersion)")
        try await runner.setWindowsVersion(resolved.windowsVersion, wine: wine, environment: env)

        progress(2, "Applying registry settings")
        var registry = resolved.registry
        registry.append(RegistryEdit(
            key: "HKCU\\Software\\Wine\\Mac Driver",
            values: ["RetinaMode": .string(resolved.retina ? "y" : "n")]
        ))
        try await runner.importRegistry(registry, prefix: prefix, wine: wine, environment: env)

        progress(3, "Placing \(resolved.graphics.displayName) files")
        if let graphics {
            try GraphicsPlacer.installPrefixDLLs(graphics, prefix: prefix)
        }

        progress(4, resolved.winetricks.isEmpty ? "No winetricks needed" : "Installing \(resolved.winetricks.joined(separator: ", "))")
        if !resolved.winetricks.isEmpty {
            guard let winetricks = components.winetricks() else { throw DistillerError.componentNotFound("winetricks") }
            try await runner.runWinetricks(resolved.winetricks, winetricks: winetricks, wine: wine, environment: env)
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
        progress: @escaping @Sendable (Int, String) -> Void = { _, _ in }
    ) async throws {
        let root = bottles.root(of: bottle)
        let prefix = bottles.prefix(of: bottle)
        let env = WineEnvironment.build(prefix: prefix, wine: wine, graphics: graphics, resolved: resolved)
        for (index, step) in steps.enumerated() {
            progress(index + 1, Self.describe(step))
            try await perform(step, root: root, prefix: prefix, wine: wine, environment: env, supplied: supplied)
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
            try await Downloader.download(url, sha256: download.sha256, to: BottlePath.resolve(download.to, in: root))

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

    static func describe(_ step: InstallStep) -> String {
        switch step {
        case .download(let download): return "Downloading \(URL(string: download.url)?.lastPathComponent ?? download.url)"
        case .extract(let extract): return "Extracting \(extract.archive)"
        case .winetricks(let verbs): return "Installing \(verbs.joined(separator: ", "))"
        case .registry(let edit): return "Setting \(edit.key)"
        case .dllOverride: return "Setting DLL overrides"
        case .copy(let copy): return "Copying \(copy.from)"
        case .runWindows(let run): return "Running \(run.path)"
        case .userFile(let file): return "Copying your file for \(file.id)"
        case .userFolder(let folder): return "Adding your folder for \(folder.id)"
        }
    }
}
