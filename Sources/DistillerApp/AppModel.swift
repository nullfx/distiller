import AppKit
import Foundation
import Observation
import DistillerCommunity
import DistillerCore

@MainActor
@Observable
final class AppModel {
    private(set) var engine: DistillerEngine?
    private(set) var community: CommunityClient?
    private(set) var setup: EnvironmentSetup?
    let tokenStore: GitHubTokenStore = KeychainTokenStore()

    var hardware: HardwareProfile? { engine?.hardware }
    var games: [Game] = []
    var bottles: [Bottle] = []
    var components: [InstalledComponent] = []
    var index: CommunityIndex?
    /// The catalogue's copies of recipes the player has built too, by repository path, so the
    /// library can tell whether theirs differs. See AppModel+CommunityStatus.swift.
    var publishedRecipes: [String: Recipe] = [:]
    var publishedRecipeFetches: Set<String> = []
    var running: [String: Process] = [:]
    /// Storage locations on drives that aren't connected. See AppModel+Storage.swift.
    var unavailableStorage: [UnavailableStorage] = []
    /// Whether each game can be played now, and its icon. See AppModel+Library.swift.
    var availability: [String: GameAvailability] = [:]
    var icons: [String: NSImage] = [:]
    /// The launch program each game's icon was last read from, so it's read again only when that changes.
    var iconSources: [String: String] = [:]

    // Navigation, and links from the catalogue website. See AppModel+Links.swift.
    var sidebarSelection: SidebarItem? = .library
    var communityQuery = ""
    /// The Community tab's navigation: the slugs of the game pages open, innermost last.
    var communityPath: [String] = []
    /// The Community list's genre, graphics layer, rating and order, like the website's.
    var communityFilter = CatalogueFilter()
    var pendingLink: DistillerLink?
    var linkInstall: LinkInstallRequest?

    /// Shown in the status bar while long work runs.
    var busyMessage: String?
    var errorMessage: String?
    /// What the Logs folder holds (Settings ▸ Storage ▸ Logs), and the last cleanup's result.
    var logUsage: LogCleaner.Usage?
    var logCleanupMessage: String?
    var isImportingRecipe = false
    /// Set after a play session, to offer a compatibility report.
    var gameToReport: Game?

    // Component updates. See AppModel+ComponentUpdates.swift.
    var componentUpdates: [ComponentUpdate] = []
    var componentCheckFailures: [String: String] = [:]
    var isCheckingForUpdates = false
    var hasCheckedComponentsThisSession = false
    var componentUpdateTimer: Task<Void, Never>?
    /// The active version of each component, and old versions nothing needs, as of the last reload.
    var activeComponentIDs: Set<String> = []
    var unusedComponents: [InstalledComponent] = []
    var componentUpdateMessage: String?
    /// Distiller's own update (Settings ▸ Updates). See AppModel+AppUpdate.swift.
    var appUpdate: AppRelease?
    var appUpdateStatus: String?
    var isInstallingAppUpdate = false
    /// Set when an automatic check finds a version not announced before; shows an alert.
    var appUpdateToAnnounce: AppRelease?
    /// `settings.json`'s update mode and last check, kept here so views update when they change.
    var componentUpdateMode: ComponentUpdateMode = .ask
    var lastComponentCheck: Date?

    // Setup, recipe building and submission. See AppModel+Authoring.swift.
    var environment: EnvironmentReport?
    var isShowingSetup = false
    var isCreatingRecipe = false
    var gameInWorkshop: Game?
    var gameToSubmit: Game?
    /// The signed-in GitHub account, remembered between launches so it shows while offline.
    var githubUser: GitHubUser?
    var githubLogin: String? { githubUser?.login }
    var isSignedInToGitHub: Bool { githubUser != nil }
    /// The account's picture, downloaded once per sign-in. See AppModel+Authoring.swift.
    var githubAvatar: NSImage?
    var signInCode: DeviceCode?
    var signInTask: Task<Void, Never>?

    func start() async {
        guard engine == nil else { return }
        do {
            let engine = try await Task.detached { try DistillerEngine() }.value
            self.engine = engine
            self.community = CommunityClient(paths: engine.paths)
            self.setup = EnvironmentSetup(engine: engine)
            self.index = community?.cachedIndex()
            reload()
            checkEnvironment(showIfNeeded: true)
            // Ask where things go before anything is downloaded or installed.
            if !storageConfirmed { isShowingSetup = true }
            await restoreGitHubSession()
            await refreshCommunityQuietly()
            offerToRemoveOrphanedCheckBottles()
            await handlePendingLink()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Recreates the engine so it picks up new storage locations.
    func restartEngine() {
        do {
            let engine = try DistillerEngine()
            self.engine = engine
            self.community = CommunityClient(paths: engine.paths)
            self.setup = EnvironmentSetup(engine: engine)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reload() {
        guard let engine else { return }
        cleanUpLogsIfDue()
        unavailableStorage = engine.paths.unavailable
        games = engine.library.load()
        refreshLibraryState()
        loadMissingPublishedRecipes()
        bottles = engine.bottles.list()
        components = engine.components.installed()
        activeComponentIDs = Set(engine.components.activeComponents().map(\.id))
        unusedComponents = engine.unusedComponents()
        let settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        componentUpdateMode = settings.effectiveComponentUpdates
        lastComponentCheck = settings.lastComponentCheck
        environment = setup?.check()
        checkForComponentUpdatesIfDue()
    }

    func resolved(_ game: Game) -> ResolvedRecipe? {
        engine?.resolve(game.recipe, overrides: game.overrides)
    }

    /// Runs long work with a status message and turns failures into an alert.
    func perform(_ message: String, _ work: @escaping @MainActor () async throws -> Void) {
        Task {
            busyMessage = message
            defer {
                busyMessage = nil
                reload()
            }
            do {
                try await work()
            } catch is CancellationError {
                // The player stopped it; nothing to report.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Components

    func importGPTK(from url: URL) {
        guard let engine else { return }
        perform("Importing D3DMetal from the Game Porting Toolkit…") {
            _ = try await GPTKImporter.importGPTK(from: url, into: engine.components)
        }
    }

    func importComponent(from url: URL, manifest: ComponentManifest) {
        guard let engine else { return }
        perform("Importing \(manifest.displayName)…") {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                _ = try engine.components.importDirectory(url, manifest: manifest)
            } else {
                _ = try await engine.components.installArchive(url, manifest: manifest)
            }
        }
    }

    func removeComponent(_ component: InstalledComponent) {
        guard let engine else { return }
        perform("Moving \(component.manifest.displayName) to the Trash…") {
            try engine.components.remove(component)
        }
    }

    // MARK: Games

    func addGame(fromRecipeFile url: URL) {
        perform("Reading the recipe…") {
            let recipe = try RecipeLoader.load(from: url)
            try await self.install(recipe)
        }
    }

    func install(_ recipe: Recipe) async throws {
        guard let engine else { return }
        guard let supplied = await askForUserItems(recipe) else { return }
        // Files downloaded from publishers' pages are cloned into the bottle; remove the
        // temporary copies however the install ends.
        let pageDownloads = recipe.install?.compactMap { step -> URL? in
            guard case .userDownload(let download) = step else { return nil }
            return supplied.files[download.id]
        } ?? []
        defer { pageDownloads.forEach(PageDownloadWindow.removeDownload) }
        busyMessage = "Installing \(recipe.game.title)…"
        let session = InstallSession(title: recipe.game.title, tasks: InstallPlan.tasks(for: engine.resolve(recipe)))
        InstallProgressWindow.show(session)
        do {
            _ = try await engine.install(recipe: recipe, supplied: supplied, cancellation: session.cancellation) { progress in
                Task { @MainActor in
                    session.update(progress)
                    self.busyMessage = "Installing \(recipe.game.title): \(progress.message)"
                }
            }
            session.finish(.installed)
        } catch is CancellationError {
            session.finish(.cancelled)
            throw CancellationError()
        } catch {
            session.finish(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Asks for every file and folder the recipe's steps need, and opens the publisher's page
    /// for each file the player downloads there. Returns nil if the player cancels.
    func askForUserItems(_ recipe: Recipe) async -> UserSupplied? {
        var supplied = UserSupplied()
        let pages = Dictionary(RecipeInstaller.pageDownloads(in: recipe).map { ($0.step.id, $0) }, uniquingKeysWith: { first, _ in first })
        for step in recipe.install ?? [] {
            switch step {
            case .userFile(let file):
                guard let url = chooseFile(prompt: file.prompt) else { return nil }
                supplied.files[file.id] = url
            case .userFolder(let folder):
                guard let choice = chooseFolder(prompt: folder.prompt) else { return nil }
                supplied.folders[folder.id] = choice
            case .userDownload(let download):
                guard let page = pages[download.id],
                      let url = await PageDownloadWindow.obtain(page.request, verify: { file in
                          try RecipeInstaller.checkPageDownload(file, for: download)
                      }) else {
                    supplied.files.values.filter { $0.path.contains("/distiller-installer-") }.forEach(PageDownloadWindow.removeDownload)
                    return nil
                }
                supplied.files[download.id] = url
            default:
                continue
            }
        }
        return supplied
    }

    func launch(_ game: Game) {
        guard let engine, running[game.id] == nil else { return }
        let started = Date()
        do {
            let process = try engine.launch(game) { [weak self] _ in
                Task { @MainActor in self?.finished(game, started: started) }
            }
            running[game.id] = process
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(_ game: Game) {
        guard let engine else { return }
        perform("Stopping \(game.title)…") {
            try await engine.stop(game)
        }
    }

    private func finished(_ game: Game, started: Date) {
        running[game.id] = nil
        guard let engine else { return }
        let seconds = Date().timeIntervalSince(started)
        var updated = (try? engine.library.game(id: game.id)) ?? game
        updated.lastPlayedAt = Date()
        updated.secondsPlayed += seconds
        try? engine.library.upsert(updated)
        reload()
        // Only ask for a report after a real session, not a launch that failed at once.
        if seconds > 120 { gameToReport = updated }
    }

    func removeGame(_ game: Game) {
        guard let engine else { return }
        perform("Removing \(game.title)…") {
            try engine.library.remove(id: game.id)
            engine.removeIcons(for: game)
            if let bottle = try? engine.bottles.bottle(id: game.bottleID) {
                try engine.bottles.delete(bottle)
            }
        }
    }

    func showLog(for game: Game) {
        guard let log = engine?.runner.latestLog(named: game.id) else {
            errorMessage = "\(game.title) has no log yet. Logs appear after the first launch."
            return
        }
        NSWorkspace.shared.open(log)
    }

    func revealBottle(id: String) {
        guard let engine, let bottle = try? engine.bottles.bottle(id: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([engine.bottles.root(of: bottle)])
    }

    // MARK: Community

    func refreshCommunity() {
        guard let community else { return }
        perform("Downloading community recipes…") {
            self.index = try await community.refreshIndex()
            self.forgetPublishedRecipes()
        }
    }

    func installFromCommunity(_ recipe: IndexRecipe) {
        guard let community else { return }
        perform("Downloading the recipe…") {
            let loaded = try await community.fetchRecipe(recipe)
            try await self.install(loaded)
        }
    }

    func reportURL(for game: Game, tier: PlayabilityTier, fps: Double?, notes: String) -> URL? {
        guard let engine, let community else { return nil }
        let stack = try? engine.selectStack(for: game)
        return community.reportURL(
            gameSlug: game.recipe.game.slug,
            recipeID: game.recipe.id,
            hardware: engine.hardware,
            tier: tier,
            averageFPS: fps,
            wineVersion: stack.map { $0.wine.manifest.composedFrom?.first ?? $0.wine.id },
            graphicsVersion: stack?.graphics?.id,
            notes: notes
        )
    }

    // MARK: Helpers

    func chooseFile(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A folder, with the choice to use it where it is rather than copy it into the bottle.
    func chooseFolder(prompt: String) -> UserFolderSource? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let linkBox = NSButton(checkboxWithTitle: "Use the folder where it is instead of copying it", target: nil, action: nil)
        linkBox.toolTip = "The game reads and writes its files in that folder, including data it updates when it starts. A folder on another drive is used where it is unless you uncheck this."
        panel.accessoryView = linkBox
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // The box can't follow the selection while the panel is open, so an untouched box
        // means "decide by drive": a folder on another drive than the bottles is used in place.
        let otherDrive = StorageVolume(containing: url)?.root != bottlesVolume?.root
        return UserFolderSource(url: url, linkInPlace: linkBox.state == .on || otherDrive)
    }
}
