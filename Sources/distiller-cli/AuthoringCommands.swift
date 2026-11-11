import ArgumentParser
import Foundation
import DistillerCommunity
import DistillerCore

// MARK: - setup

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Check what Distiller needs and install what's missing.",
        subcommands: [Status.self, Install.self],
        defaultSubcommand: Status.self
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show what's installed.")

        func run() throws {
            let report = EnvironmentSetup(engine: try makeEngine()).check()
            for status in report.items {
                let mark = status.isInstalled ? "ok     " : (status.item.isRequired ? "missing" : "absent ")
                print("\(mark) \(status.item.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(status.detail)")
            }
            print(report.isReady ? "Ready to run games." : "Not ready yet. Run: distiller setup install --all")
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install Rosetta, Wine, winetricks, cabextract, DXMT or DXVK.",
            discussion: "D3DMetal can't be downloaded for you; import it with: distiller components import-gptk <GPTK .dmg>"
        )

        @Argument(help: "rosetta, wine, winetricks, cabextract, dxmt or dxvk.")
        var items: [String] = []

        @Flag(help: "Install everything that's missing.")
        var all = false

        @Option(help: "Wine build: wine-staging or wine-devel.")
        var wineBuild: String = WineSource.recommended.id

        func run() async throws {
            let setup = EnvironmentSetup(engine: try makeEngine())
            guard let source = WineSource.all.first(where: { $0.id == wineBuild }) else {
                throw ValidationError("--wine-build must be one of \(WineSource.all.map(\.id).joined(separator: ", ")).")
            }
            var wanted: [SetupItem] = []
            if all {
                wanted = setup.check().missing.filter(\.canInstallAutomatically)
            }
            for name in items {
                guard let item = SetupItem(rawValue: name), item.canInstallAutomatically else {
                    throw ValidationError("Can't install \(name). Choose from rosetta, wine, winetricks, cabextract, dxmt, dxvk.")
                }
                if !wanted.contains(item) { wanted.append(item) }
            }
            if wanted.isEmpty {
                print("Nothing to install.")
                return
            }
            for item in wanted {
                print("Installing \(item.displayName)…")
                switch item {
                case .rosetta: try await setup.installRosetta()
                case .wine:
                    let release = try await setup.latestRelease(of: source)
                    print("  \(release.assetName)")
                    let component = try await setup.installWine(release)
                    print("  Installed \(component.id)")
                case .winetricks:
                    print("  Installed \(try await setup.installWinetricks().id)")
                case .cabextract: try await setup.installCabextract()
                case .d3dmetal: break
                case .dxmt, .dxvk:
                    guard let backend = item.graphicsBackend, let source = GraphicsLayerSource.source(for: backend) else { break }
                    let release = try await setup.latestRelease(of: source)
                    print("  \(release.assetName)")
                    print("  Installed \(try await setup.installGraphicsLayer(release).id)")
                }
            }
        }
    }
}

// MARK: - recipe authoring

struct RecipeInspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Suggest recipe settings for a Windows program."
    )

    @Argument(help: "The game's .exe.")
    var exe: String

    func run() throws {
        let engine = try makeEngine()
        let url = URL(fileURLWithPath: (exe as NSString).expandingTildeInPath)
        let inspection = GameInspector.inspect(executable: url, installedGraphics: engine.components.availableGraphics())
        for finding in inspection.findings { print("- \(finding)") }
        print("Graphics:   \(inspection.suggestedGraphics.rawValue)")
        print("Windows:    \(inspection.suggestedWindowsVersion)")
        let hints = inspection.suggestedWinetricks + GameInspector.redistributableHints(in: url.deletingLastPathComponent())
        print("Winetricks: \(hints.isEmpty ? "none" : Array(NSOrderedSet(array: hints)).compactMap { $0 as? String }.joined(separator: ", "))")
    }
}

struct RecipeCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a recipe, a bottle for it, and install the game.",
        discussion: """
        Examples:
          distiller recipe create --title "Example Game" --folder ~/Games/Example --exe Example.exe
          distiller recipe create --title "Example Game" --installer ~/Downloads/setup_example.exe
          distiller recipe create --title "Example Game" --manual --graphics wined3d
        Add --dry-run to print the recipe without installing.
        """
    )

    @Option(help: "The game's title.")
    var title: String

    @Option(help: "A game folder already on this Mac.")
    var folder: String?

    @Option(help: "With --folder: the program to launch, relative to the folder.")
    var exe: String?

    @Flag(help: "With --folder: link the folder instead of copying it.")
    var link = false

    @Option(help: "A Windows installer (.exe or .msi).")
    var installer: String?

    @Flag(help: "An empty bottle; install things yourself afterwards.")
    var manual = false

    @Option(help: "Game ID (defaults to one made from the title).")
    var slug: String?

    @Option(help: "Recipe ID (defaults to the graphics layer).")
    var id: String?

    @Option(help: "d3dmetal, dxmt, dxvk or wined3d (defaults to what the program suggests).")
    var graphics: GraphicsBackend?

    @Option(help: "Winetricks verbs, comma-separated (adds to the suggestions).")
    var winetricks: String?

    @Option(help: "Windows version, such as win10.")
    var windows: String?

    @Flag(help: "Print the recipe and stop.")
    var dryRun = false

    func run() async throws {
        let engine = try makeEngine()
        let sources = [folder != nil, installer != nil, manual].filter { $0 }.count
        guard sources == 1 else { throw ValidationError("Choose exactly one of --folder, --installer or --manual.") }

        var draft: RecipeDraft
        var supplied = UserSupplied()
        let wine = engine.components.newestWine()
        let runner = RunnerRequirement(
            family: wine?.manifest.family ?? "any",
            minVersion: wine.flatMap { VersionNumber($0.manifest.version).parts.first.map { "\($0).0" } }
        )
        if let folder {
            let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
            let programs = ProgramFinder.find(in: url)
            guard let program = exe ?? programs.first?.relativePath else {
                throw ValidationError("No .exe was found in \(url.path). Pass --exe.")
            }
            draft = RecipeDraft(source: .folder(url), title: title, slug: slug, recipeID: id, runner: runner)
            draft.launchProgram = program
            let inspection = GameInspector.inspect(
                executable: url.appendingPathComponent(program), installedGraphics: engine.components.availableGraphics()
            )
            draft.apply(inspection)
            for verb in GameInspector.redistributableHints(in: url) where !draft.winetricks.contains(verb) {
                draft.winetricks.append(verb)
            }
            supplied.folders[RecipeDraft.folderStepID] = UserFolderSource(url: url, linkInPlace: link)
        } else if let installer {
            let url = URL(fileURLWithPath: (installer as NSString).expandingTildeInPath)
            draft = RecipeDraft(source: .installer(url), title: title, slug: slug, recipeID: id, runner: runner)
            supplied.files[RecipeDraft.installerStepID] = url
        } else {
            draft = RecipeDraft(source: .manual, title: title, slug: slug, recipeID: id, runner: runner)
        }
        if let graphics {
            draft.graphics = graphics
            if id == nil { draft.recipeID = graphics.rawValue }
        }
        if let windows { draft.windowsVersion = windows }
        for verb in (winetricks ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !verb.isEmpty {
            if !draft.winetricks.contains(verb) { draft.winetricks.append(verb) }
        }

        let recipe = draft.makeRecipe()
        try RecipeLoader.validate(recipe)
        if dryRun {
            print(try RecipeLoader.encode(recipe))
            return
        }
        printInstallPlan(InstallPlan.tasks(for: engine.resolve(recipe)))
        let game = try await engine.create(from: draft, supplied: supplied, progress: printInstallProgress)
        print("Created \(game.title) (\(game.id)).")
        if game.recipe.launch == nil {
            print("Choose the program to launch: distiller recipe programs \(game.id), then distiller recipe set-launch \(game.id) '<C:\\path>'")
        } else {
            print("Start it with: distiller launch \(game.id)")
        }
        print("Recipe file: \(try engine.recipeFileURL(for: game).path)")
    }
}

struct RecipePrograms: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "programs", abstract: "List programs in a game's bottle.")

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    func run() throws {
        let engine = try makeEngine()
        for entry in try engine.discoverPrograms(for: try findGame(game, in: engine)) {
            print("\(entry.windowsPath)\t\(ByteCountFormatter.string(fromByteCount: entry.program.size, countStyle: .file))")
        }
    }
}

struct RecipeSetLaunch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-launch", abstract: "Set the program a game's recipe launches.")

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    @Argument(help: #"A Windows path such as 'C:\Games\Example\Game.exe'."#)
    var exe: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments for the program.")
    var arguments: [String] = []

    func run() async throws {
        let engine = try makeEngine()
        let entry = try findGame(game, in: engine)
        var recipe = entry.recipe
        recipe.launch = LaunchSpec(exe: exe, args: arguments.isEmpty ? recipe.launch?.args : arguments)
        try await engine.updateRecipe(recipe, for: entry)
        print("Saved. Start it with: distiller launch \(entry.id)")
    }
}

struct RecipeEdit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Print the path of a game's editable recipe.yaml (then run 'distiller recipe reload')."
    )

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    func run() throws {
        let engine = try makeEngine()
        print(try engine.writeRecipeFile(for: try findGame(game, in: engine)).path)
    }
}

struct RecipeReload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reload", abstract: "Apply an edited recipe.yaml to its game.")

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    func run() async throws {
        let engine = try makeEngine()
        let updated = try await engine.reloadRecipeFile(for: try findGame(game, in: engine)) { progress in
            print("[\(progress.step)/\(progress.total)] \(progress.message)")
        }
        print("Reloaded \(updated.title).")
    }
}

struct RecipeRunInstaller: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-installer",
        abstract: "Run a Windows installer in a game's bottle and add it to the recipe."
    )

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    @Argument(help: "The installer (.exe or .msi).")
    var installer: String

    @Flag(help: "Don't add the installer to the recipe.")
    var noRecord = false

    func run() async throws {
        let engine = try makeEngine()
        let url = URL(fileURLWithPath: (installer as NSString).expandingTildeInPath)
        let entry = try findGame(game, in: engine)
        try await engine.prepareWineMove(for: entry, progress: { print($0) })
        try await engine.runInstaller(url, for: entry, record: !noRecord) { progress in
            print("[\(progress.step)/\(progress.total)] \(progress.message)")
        }
        print(noRecord ? "Done." : "Done, and added to the recipe.")
    }
}

struct RecipeSubmit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit",
        abstract: "Submit a game's recipe to the community repository as a pull request.",
        discussion: "Sign in first with: distiller github login"
    )

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    @Option(help: "Include a report: platinum, gold, silver, bronze or borked.")
    var tier: PlayabilityTier?

    @Option(help: "Average frames per second, for the report.")
    var fps: Double?

    @Option(help: "Notes for the report.")
    var notes: String = ""

    @Option(help: "For a game new to the catalogue: a short description, in your own words.")
    var description: String?

    @Option(help: "For a new game: genres, comma-separated (action, adventure, mmo, rpg, strategy, …).")
    var genres: String?

    @Option(help: "For a new game: its release year.")
    var year: Int?

    @Option(help: "For a new game: its developer.")
    var developer: String?

    @Flag(help: "Confirm the recipe only downloads the publisher's official installer, and that you license it under MIT.")
    var confirm = false

    func run() async throws {
        let engine = try makeEngine()
        let entry = try findGame(game, in: engine)
        let repository = CommunityRepository.default
        let issues = SubmissionPlan.issues(for: entry, recipe: CommunityCheck.recipeToSubmit(for: entry) ?? entry.recipe, repository: repository)
        for issue in issues { print("\(issue.severity.rawValue): \(issue.message)") }
        if issues.contains(where: { $0.severity == .error }) { throw ExitCode(1) }
        guard confirm else {
            throw ValidationError("Add --confirm to agree that the recipe only downloads the publisher's official installer and is MIT licensed.")
        }
        guard let token = KeychainTokenStore().load() else { throw GitHubError.notSignedIn }

        var report: ReportDraft?
        if let tier {
            let stack = try? engine.selectStack(for: entry)
            report = ReportDraft(
                tier: tier, averageFPS: fps, notes: notes,
                wineVersion: stack.map { $0.wine.manifest.composedFrom?.first ?? $0.wine.id },
                graphicsVersion: stack?.graphics?.id
            )
        }
        guard let recipe = CommunityCheck.recipeToSubmit(for: entry) else { throw ExitCode(1) }
        let submitter = RecipeSubmitter(repository: repository, token: token)
        let target = try await submitter.target(for: recipe)
        print(target.isMaintainer ? "You maintain \(repository.fullName): the branch goes there directly." : "Submitting through your fork of \(repository.fullName).")
        var details: GameDetails?
        if !target.gameExists {
            var game = GameDetails(from: recipe)
            game.description = description ?? ""
            game.genres = (genres ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            game.releaseYear = year
            game.developer = developer
            if !game.problems.isEmpty {
                for problem in game.problems { print("game: \(problem)") }
                throw ValidationError("\(recipe.game.title) is new to the catalogue. Add --description (and optionally --genres, --year, --developer).")
            }
            details = game
        }
        let submission = try await submitter.submit(
            recipe, report: report, hardware: engine.hardware, previous: entry.submission, game: details
        ) { print($0) }
        var updated = entry
        updated.submission = submission
        try engine.library.upsert(updated)
        print("Pull request: \(submission.url)")
    }
}

// MARK: - github

struct GitHubCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "github",
        abstract: "Sign in to GitHub to submit recipes.",
        subcommands: [Login.self, Logout.self, Status.self],
        defaultSubcommand: Status.self
    )

    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sign in with a one-time code.")

        func run() async throws {
            let repository = CommunityRepository.default
            guard repository.isConfiguredForSubmissions else { throw GitHubError.notConfigured }
            let flow = GitHubDeviceFlow(clientID: repository.oauthClientID)
            let code = try await flow.start()
            print("Open \(code.verificationURI.absoluteString) and enter the code \(code.userCode)")
            let token = try await flow.waitForToken(code)
            try KeychainTokenStore().save(token)
            print("Signed in as \(try await GitHubAPI(token: token).currentUser().login).")
        }
    }

    struct Logout: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget the saved GitHub token.")
        func run() throws {
            try KeychainTokenStore().delete()
            print("Signed out.")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show who you're signed in as.")
        func run() async throws {
            guard let token = KeychainTokenStore().load() else {
                print("Not signed in. Run: distiller github login")
                return
            }
            print("Signed in as \(try await GitHubAPI(token: token).currentUser().login).")
        }
    }
}
