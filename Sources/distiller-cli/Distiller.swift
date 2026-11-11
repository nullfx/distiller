import ArgumentParser
import Foundation
import DistillerCommunity
import DistillerCore

@main
struct Distiller: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "distiller",
        abstract: "Install and run Windows games on macOS with Wine.",
        discussion: "Set DISTILLER_HOME to keep test data away from your real library.",
        version: DistillerVersion.current,
        subcommands: [
            HardwareCommand.self,
            SetupCommand.self,
            ComponentsCommand.self,
            BottlesCommand.self,
            RunCommand.self,
            RecipeCommand.self,
            InstallCommand.self,
            GamesCommand.self,
            LaunchCommand.self,
            CommunityCommand.self,
            GitHubCommand.self,
            StorageCommand.self,
            McpCommand.self,
            AssistantCommand.self,
            LogsCommand.self,
            AppCommand.self,
        ]
    )
}

extension ComponentKind: ExpressibleByArgument {}
extension CPUArch: ExpressibleByArgument {}
extension GraphicsBackend: ExpressibleByArgument {}
extension GraphicsPlacement: ExpressibleByArgument {}
extension PlayabilityTier: ExpressibleByArgument {}

func makeEngine() throws -> DistillerEngine {
    try DistillerEngine()
}

/// A game in the library by its ID, with a hint about where IDs come from when there's none.
func findGame(_ id: String, in engine: DistillerEngine) throws -> Game {
    do {
        return try engine.library.game(id: id)
    } catch DistillerError.gameNotFound {
        throw ValidationError("There's no game in the library with the ID \(id). Run `distiller games` to list the games and their IDs.")
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

/// Waits for a launched process, so the CLI stays alive while a game or program runs.
func waitForExit(_ start: (@escaping @Sendable (Int32) -> Void) throws -> Process) async throws -> Int32 {
    try await withCheckedThrowingContinuation { continuation in
        do {
            _ = try start { status in continuation.resume(returning: status) }
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - hw

struct HardwareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hw", abstract: "Show this Mac's hardware fingerprint.")

    @Flag(help: "Print JSON instead of text.")
    var json = false

    func run() throws {
        let hardware = HardwareProbe.current()
        if json {
            try printJSON(hardware)
            return
        }
        print("""
        Chip:       \(hardware.chip) (\(hardware.chipFamily), \(hardware.chipTier))
        CPU cores:  \(hardware.performanceCores) performance + \(hardware.efficiencyCores) efficiency
        GPU cores:  \(hardware.gpuCores.map(String.init) ?? "unknown")
        Memory:     \(hardware.memoryGB) GB
        macOS:      \(hardware.macOS)
        Rosetta:    \(hardware.rosetta ? "available" : "not available (install with: softwareupdate --install-rosetta)")
        Report key: \(hardware.hardwareKey)
        """)
    }
}

// MARK: - components

struct ComponentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "components",
        abstract: "Manage Wine builds, graphics layers and winetricks.",
        subcommands: [List.self, Check.self, Update.self, Use.self, Clean.self, Updates.self, Import.self, ImportGPTK.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List installed components.")

        func run() throws {
            let engine = try makeEngine()
            let components = engine.components.installed()
            let active = Set(engine.components.activeComponents().map(\.id))
            if components.isEmpty {
                print("No components yet. Import a Wine build with: distiller components import <folder> --kind wine …")
                return
            }
            for component in components {
                let extra = component.manifest.family ?? component.manifest.provides?.rawValue ?? ""
                let state = active.contains(component.id) ? "active" : ""
                print("\(component.manifest.kind.rawValue)\t\(component.id)\t\(component.manifest.arch.rawValue)\t\(extra)\t\(component.manifest.displayName)\t\(state)")
            }
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import a folder or archive as a component.",
            discussion: """
            Examples:
              distiller components import ~/Downloads/wine-11.0 --kind wine --id winehq --family winehq --version 11.0
              distiller components import ~/Downloads/winetricks --kind winetricks --id winetricks --version 20260125 --arch universal
              distiller components import ~/Downloads/dxmt --kind graphics --id dxmt --version 0.70 --provides dxmt --placement wine_lib
            """
        )

        @Argument(help: "A folder, or a .tar.xz, .tar.gz or .zip archive.")
        var source: String

        @Option(help: "wine, graphics or winetricks.")
        var kind: ComponentKind

        @Option(help: "A short identifier, such as winehq or dxmt.")
        var id: String

        @Option(help: "The component's version.")
        var version: String

        @Option(help: "x86_64, arm64 or universal.")
        var arch: CPUArch = .x86_64

        @Option(help: "For Wine builds: crossover, winehq or gptk.")
        var family: String?

        @Option(help: "For graphics layers: d3dmetal, dxmt, dxvk or wined3d.")
        var provides: GraphicsBackend?

        @Option(help: "For graphics layers: wine_lib or prefix_dlls.")
        var placement: GraphicsPlacement?

        @Option(help: "Path of the main executable inside the component, if not standard.")
        var executable: String?

        @Option(help: "Expected SHA-256 of an archive.")
        var sha256: String?

        @Option(help: "Display name.")
        var name: String?

        func run() async throws {
            let engine = try makeEngine()
            let manifest = ComponentManifest(
                id: id,
                kind: kind,
                version: version,
                displayName: name ?? "\(id) \(version)",
                arch: arch,
                family: family,
                provides: provides,
                placement: placement,
                executable: executable ?? (kind == .winetricks ? "winetricks" : nil),
                sha256: sha256
            )
            let url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let installed: InstalledComponent
            if isDirectory.boolValue {
                installed = try engine.components.importDirectory(url, manifest: manifest)
            } else {
                installed = try await engine.components.installArchive(url, manifest: manifest)
            }
            print("Imported \(installed.id) to \(installed.directory.path)")
        }
    }

    struct ImportGPTK: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-gptk",
            abstract: "Import D3DMetal from your Game Porting Toolkit download."
        )

        @Argument(help: "The GPTK .dmg, its mounted volume, or a folder copied from it.")
        var path: String

        func run() async throws {
            print(GPTKImporter.licenseNotice)
            let engine = try makeEngine()
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let component = try await GPTKImporter.importGPTK(from: url, into: engine.components)
            print("Imported \(component.id).")
        }
    }
}

// MARK: - bottles

struct BottlesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottles",
        abstract: "List and create bottles.",
        subcommands: [List.self, Create.self, BottleDrives.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List bottles.")

        func run() throws {
            let engine = try makeEngine()
            let bottles = engine.bottles.list()
            if bottles.isEmpty { print("No bottles yet. Create one with: distiller bottles create <name>") }
            for bottle in bottles {
                print("\(bottle.id)\t\(bottle.wine)\t\(bottle.name)")
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create an empty bottle.")

        @Argument(help: "A name for the bottle.")
        var name: String

        @Option(help: "Wine build to use, as id or id@version. Defaults to the first installed.")
        var wine: String?

        func run() async throws {
            let engine = try makeEngine()
            print("Creating \(name). The first bottle for a Wine build takes a minute while Wine sets up a template.")
            let bottle = try await engine.createBottle(name: name, wineID: wine)
            print("Created \(bottle.id) at \(engine.bottles.root(of: bottle).path)")
        }
    }
}

// MARK: - run

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a program in a bottle and wait for it to exit.",
        discussion: "Phase 0 test: distiller run <bottle-id> notepad"
    )

    @Argument(help: "The bottle ID, from 'distiller bottles'.")
    var bottle: String

    @Argument(help: "A program: a name Wine knows (notepad, winecfg, regedit) or a path.")
    var program: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed to the program.")
    var arguments: [String] = []

    func run() async throws {
        let engine = try makeEngine()
        let status = try await waitForExit { onExit in
            try engine.run(program: program, arguments: arguments, inBottle: bottle, onExit: onExit)
        }
        print("\(program) exited with status \(status). Log: \(engine.runner.latestLog(named: "run-\(bottle)")?.path ?? "none")")
    }
}

// MARK: - recipe

struct RecipeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recipe",
        abstract: "Create, check and submit recipes.",
        subcommands: [
            Validate.self, Resolve.self, RecipeInspect.self, RecipeCreate.self, RecipePrograms.self,
            RecipeSetLaunch.self, RecipeEdit.self, RecipeReload.self, RecipeRunInstaller.self, RecipeCheckLink.self, RecipeCheckSignature.self, RecipeCommunityCheck.self, RecipeSubmit.self,
        ]
    )

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check that recipe files are valid and safe.")

        @Argument(help: "One or more recipe .yaml files.")
        var files: [String]

        func run() throws {
            var failures = 0
            for file in files {
                do {
                    let recipe = try RecipeLoader.load(from: URL(fileURLWithPath: file))
                    print("ok      \(file)  (\(recipe.game.slug)/\(recipe.id))")
                } catch {
                    failures += 1
                    print("invalid \(file): \(error.localizedDescription)")
                }
            }
            if failures > 0 { throw ExitCode(1) }
        }
    }

    struct Resolve: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the settings a recipe resolves to on this Mac.")

        @Argument(help: "A recipe .yaml file.")
        var file: String

        func run() throws {
            let recipe = try RecipeLoader.load(from: URL(fileURLWithPath: file))
            let hardware = HardwareProbe.current()
            let resolved = RecipeResolver.resolve(recipe, for: hardware)
            print("Resolved for \(hardware.hardwareKey):")
            try printJSON(resolved)
        }
    }
}

// MARK: - install, games, launch

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a game from a recipe file.",
        discussion: """
            Supply files and folders the recipe asks for with --file <id>=<path> and --folder <id>=<path>, \
            for example --file installer=~/Downloads/setup.exe. A file the recipe has you download from \
            its publisher's page (user_download) is asked for if you don't give it: download it in your \
            browser, then enter its path. Distiller checks it's the file the recipe expects.
            """
    )

    @Argument(help: "A recipe .yaml file.")
    var recipe: String

    @Option(name: .customLong("file"), help: "A file for a user_file or user_download step, as id=path.")
    var files: [String] = []

    @Option(name: .customLong("folder"), help: "A folder for a user_folder step, as id=path.")
    var folderArguments: [String] = []

    @Flag(help: "Link user_folder folders instead of copying them.")
    var link = false

    func run() async throws {
        let engine = try makeEngine()
        let loaded = try RecipeLoader.load(from: URL(fileURLWithPath: recipe))
        var userFiles: [String: URL] = [:]
        for entry in files {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ValidationError("--file takes id=path, but got \(entry).") }
            userFiles[parts[0]] = URL(fileURLWithPath: (parts[1] as NSString).expandingTildeInPath)
        }
        var folders: [String: UserFolderSource] = [:]
        for entry in folderArguments {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ValidationError("--folder takes id=path, but got \(entry).") }
            folders[parts[0]] = UserFolderSource(url: URL(fileURLWithPath: (parts[1] as NSString).expandingTildeInPath), linkInPlace: link)
        }
        for (download, request) in RecipeInstaller.pageDownloads(in: loaded) {
            if let given = userFiles[download.id] {
                try RecipeInstaller.checkPageDownload(given, for: download)
                continue
            }
            guard let file = askForPageDownload(request, check: { try RecipeInstaller.checkPageDownload($0, for: download) }) else {
                throw DistillerError.setupFailed("Cancelled. Download it from \(request.page.absoluteString), then pass --file \(download.id)=<path>.")
            }
            userFiles[download.id] = file
        }
        printInstallPlan(InstallPlan.tasks(for: engine.resolve(loaded)))
        let game = try await engine.install(recipe: loaded, supplied: UserSupplied(files: userFiles, folders: folders), progress: printInstallProgress)
        print("Installed \(game.title). Start it with: distiller launch \(game.id)")
    }
}

struct GamesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "games",
        abstract: "List the games in your library.",
        subcommands: [List.self, GameLinkFolder.self, GameIconCommand.self, GameVersionsCommand.self, GameRestoreCommand.self, GameRebuildCommand.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the games in your library.")

        func run() throws {
            let engine = try makeEngine()
            let games = engine.library.load()
            if games.isEmpty { print("Your library is empty. Add a game with: distiller install <recipe.yaml>") }
            for game in games {
                let note = engine.availability(of: game).reason.map { "\t(can't play: \($0))" } ?? ""
                print("\(game.id)\t\(game.recipe.game.slug)/\(game.recipe.id)\t\(game.title)\(note)")
            }
        }
    }
}

struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "launch", abstract: "Start a game and wait for it to exit.")

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    @Flag(help: "For this launch only: log DLL loads, exceptions and Wine errors, and show Apple's Metal HUD while the game draws with Metal. Nothing is saved to the recipe.")
    var diagnose = false

    @Option(name: .customLong("dll"), help: "For this launch only, override a DLL, such as nvapi64=disabled or d3dcompiler_47=native. Repeat for more.")
    var dlls: [String] = []

    // .unconditional: game arguments start with "-", which would otherwise read as an option.
    @Option(parsing: .unconditional, help: "For this launch only, use these program arguments instead of the recipe's (one string; \"\" for none).")
    var args: String?

    @Option(help: "For this launch only, use this graphics layer: d3dmetal, dxmt, dxvk or wined3d.")
    var graphics: GraphicsBackend?

    func run() async throws {
        let engine = try makeEngine()
        let entry = try findGame(game, in: engine)
        var launched = entry
        if let graphics {
            var overrides = launched.overrides ?? LocalOverrides()
            overrides.graphics = graphics
            launched.overrides = overrides
            print("For this launch only, graphics: \(graphics.displayName)")
        }
        if let args {
            var overrides = launched.overrides ?? LocalOverrides()
            overrides.args = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            launched.overrides = overrides
            print("For this launch only, arguments: \(overrides.args!.isEmpty ? "(none)" : overrides.args!.joined(separator: " "))")
        }
        if !dlls.isEmpty {
            var extra: [String: String] = [:]
            for item in dlls {
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw ValidationError("Use --dll name=value, such as nvapi64=disabled.") }
                extra[parts[0]] = parts[1]
            }
            try RecipePolicy.checkDLLOverrides(extra)
            var overrides = launched.overrides ?? LocalOverrides()
            overrides.dllOverrides = (overrides.dllOverrides ?? [:]).merging(extra) { _, new in new }
            launched.overrides = overrides
            print("For this launch only: \(extra.keys.sorted().map { "\($0)=\(extra[$0]!)" }.joined(separator: ", "))")
        }
        if diagnose {
            var overrides = launched.overrides ?? LocalOverrides()
            overrides.env = (overrides.env ?? [:]).merging(DiagnosticLaunch.environment) { _, diagnostic in diagnostic }
            launched.overrides = overrides
            print("Diagnostic launch: Wine logs DLL loads, exceptions and errors; the Metal HUD appears if the game draws with Metal.")
        }
        if let point = try await engine.prepareWineMove(for: launched, progress: { print($0) }) {
            print("Saved a restore point (\(RestorePoint.describe(point.fromWine))). If the game doesn't work: distiller games restore \(entry.id) --rollback")
        }
        let resolved = engine.resolve(launched.recipe, overrides: launched.overrides)
        print("Starting \(entry.title) with \(resolved.graphics.displayName).")
        for note in resolved.appliedOverlayNotes { print("  Tuned for this Mac: \(note)") }
        let started = Date()
        let status = try await waitForExit { onExit in try engine.launch(launched, onExit: onExit) }
        var updated = entry
        updated.lastPlayedAt = Date()
        updated.secondsPlayed += Date().timeIntervalSince(started)
        try engine.library.upsert(updated)
        print("\(entry.title) exited with status \(status). Log: \(engine.runner.latestLog(named: entry.id)?.path ?? "none")")
    }
}

// MARK: - community

struct CommunityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "community",
        abstract: "Browse shared recipes and report results.",
        subcommands: [Refresh.self, Search.self, ReportLink.self]
    )

    struct Refresh: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download the latest recipe index.")

        func run() async throws {
            let engine = try makeEngine()
            let index = try await CommunityClient(paths: engine.paths).refreshIndex()
            print("\(index.games.count) games, \(index.games.reduce(0) { $0 + $1.recipes.count }) recipes (generated \(index.generatedAt)).")
        }
    }

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search the downloaded index, ranked for this Mac.")

        @Argument(help: "Words in the game's title.")
        var query: String

        func run() throws {
            let engine = try makeEngine()
            guard let index = CommunityClient(paths: engine.paths).cachedIndex() else {
                print("No index downloaded yet. Run: distiller community refresh")
                return
            }
            let matches = index.games.filter { $0.title.localizedCaseInsensitiveContains(query) }
            if matches.isEmpty { print("No games match \"\(query)\".") }
            for game in matches {
                print(game.title)
                for ranked in RecipeRanker.rank(game.recipes, for: engine.hardware) {
                    let tier = ranked.tier?.displayName ?? "Unrated"
                    print("  \(ranked.recipe.id)\t\(tier)\t\(ranked.evidence)\t\(ranked.recipe.path)")
                }
            }
        }
    }

    struct ReportLink: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "report-link",
            abstract: "Print a pre-filled GitHub link for reporting how a game ran."
        )

        @Argument(help: "The game ID, from 'distiller games'.")
        var game: String

        @Option(help: "platinum, gold, silver, bronze or borked.")
        var tier: PlayabilityTier

        @Option(help: "Average frames per second, if you measured it.")
        var fps: Double?

        @Option(help: "Anything others should know.")
        var notes: String = ""

        func run() throws {
            let engine = try makeEngine()
            let entry = try findGame(game, in: engine)
            let stack = try? engine.selectStack(for: entry)
            let url = CommunityClient(paths: engine.paths).reportURL(
                gameSlug: entry.recipe.game.slug,
                recipeID: entry.recipe.id,
                hardware: engine.hardware,
                tier: tier,
                averageFPS: fps,
                wineVersion: stack.map { $0.wine.manifest.composedFrom?.first ?? $0.wine.id },
                graphicsVersion: stack?.graphics?.id,
                notes: notes
            )
            print(url.absoluteString)
        }
    }
}

/// Asks for a file the player downloads from a publisher's page in their own browser, until
/// they give one that passes `check` (when given) or cancel (an empty answer, or no terminal).
func askForPageDownload(_ request: PageDownloadRequest, check: ((URL) throws -> Void)?) -> URL? {
    print(request.prompt)
    print("Open the publisher's download page in your browser and download it for Windows:")
    print("  \(request.page.absoluteString)")
    while true {
        print("Path of the downloaded file (drag it here), or Enter to cancel: ", terminator: "")
        guard let line = readLine() else { return nil }
        var path = line.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return nil }
        // Paths dragged into Terminal are quoted or have escaped spaces.
        if path.count > 1, let first = path.first, (first == "'" || first == "\""), path.last == first {
            path = String(path.dropFirst().dropLast())
        }
        path = path.replacingOccurrences(of: "\\ ", with: " ")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
            print("There's no file at \(url.path).")
            continue
        }
        do {
            try check?(url)
            return url
        } catch {
            print("\(url.lastPathComponent) isn't the file the recipe expects: \(error.localizedDescription)")
        }
    }
}

/// Lists an install's steps before it starts, with a note on the slow ones.
func printInstallPlan(_ tasks: [InstallTask]) {
    print("Installing in \(tasks.count) steps:")
    for task in tasks {
        print("  \(task.id). \(task.title)\(task.note.map { _ in " (can take a long time)" } ?? "")")
    }
}

/// Prints each step as it starts, and anything it adds while running.
@Sendable func printInstallProgress(_ progress: InstallProgress) {
    print("[\(progress.step)/\(progress.total)] \(progress.message)")
}
