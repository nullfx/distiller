import AppKit
import Foundation
import UniformTypeIdentifiers
import DistillerCommunity
import DistillerCore

/// First-run setup, building recipes, and submitting them to the community repository.
extension AppModel {
    private static let setupDismissedKey = "setupAssistantDismissed"

    // MARK: Setup

    func checkEnvironment(showIfNeeded: Bool = false) {
        guard let setup else { return }
        let report = setup.check()
        environment = report
        if showIfNeeded, !report.isReady, !UserDefaults.standard.bool(forKey: Self.setupDismissedKey) {
            isShowingSetup = true
        }
    }

    func dismissSetup() {
        if environment?.isReady != true {
            UserDefaults.standard.set(true, forKey: Self.setupDismissedKey)
        }
        isShowingSetup = false
    }

    func install(_ item: SetupItem, wineSource: WineSource = .recommended) {
        guard let setup else { return }
        perform("Installing \(item.displayName)…") {
            defer { self.checkEnvironment() }
            switch item {
            case .rosetta:
                try await setup.installRosetta()
            case .wine:
                self.busyMessage = "Looking up the latest \(wineSource.displayName)…"
                let release = try await setup.latestRelease(of: wineSource)
                let size = release.size.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""
                self.busyMessage = "Downloading \(wineSource.displayName) \(release.version)\(size)…"
                try await setup.installWine(release)
            case .winetricks:
                try await setup.installWinetricks()
            case .cabextract:
                try await setup.installCabextract()
            case .d3dmetal:
                NSWorkspace.shared.open(EnvironmentSetup.gptkDownloadPage)
            case .dxmt, .dxvk:
                guard let backend = item.graphicsBackend, let source = GraphicsLayerSource.source(for: backend) else { return }
                self.busyMessage = "Looking up the latest \(source.displayName)…"
                let release = try await setup.latestRelease(of: source)
                let size = release.size.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""
                self.busyMessage = "Downloading \(source.displayName) \(release.version)\(size)…"
                try await setup.installGraphicsLayer(release)
            }
        }
    }

    /// Installs everything missing that can be installed without the player's help, in order.
    func installAllMissing(wineSource: WineSource = .recommended) {
        guard let setup else { return }
        perform("Setting up…") {
            defer { self.checkEnvironment() }
            for item in setup.check().missing where item.canInstallAutomatically {
                self.busyMessage = "Installing \(item.displayName)…"
                switch item {
                case .rosetta: try await setup.installRosetta()
                case .wine: try await setup.installWine(try await setup.latestRelease(of: wineSource))
                case .winetricks: try await setup.installWinetricks()
                case .cabextract:
                    // Optional, and impossible without Homebrew: don't fail the whole run for it.
                    if EnvironmentSetup.findTool("brew") != nil { try await setup.installCabextract() }
                case .d3dmetal: break
                case .dxmt, .dxvk:
                    if let backend = item.graphicsBackend { try await setup.installGraphicsLayer(backend) }
                }
            }
        }
    }

    // MARK: Building recipes

    func inspect(executable: URL) async -> GameInspection {
        let graphics = engine?.components.availableGraphics() ?? [.wined3d]
        return await Task.detached { GameInspector.inspect(executable: executable, installedGraphics: graphics) }.value
    }

    func programs(inFolder folder: URL) async -> [DiscoveredProgram] {
        await Task.detached { ProgramFinder.find(in: folder) }.value
    }

    func programs(for game: Game) async -> [ProgramInBottle] {
        guard let engine else { return [] }
        return await Task.detached { (try? engine.discoverPrograms(for: game)) ?? [] }.value
    }

    /// The runner a new recipe should ask for: the family of the newest installed Wine,
    /// at least its major version.
    var defaultRunner: RunnerRequirement {
        guard let wine = engine?.components.newestWine() else { return RunnerRequirement(family: "any") }
        let major = VersionNumber(wine.manifest.version).parts.first.map { "\($0).0" }
        return RunnerRequirement(family: wine.manifest.family ?? "any", minVersion: major)
    }

    var availableGraphics: Set<GraphicsBackend> {
        engine?.components.availableGraphics() ?? [.wined3d]
    }

    /// Creates the bottle for a draft and installs into it. Returns the new game, or nil on failure
    /// (the error is shown). A game whose install failed stays in the library so it can be fixed.
    func create(from draft: RecipeDraft, supplied: UserSupplied) async -> Game? {
        guard let engine else { return nil }
        busyMessage = "Creating \(draft.title)…"
        defer {
            busyMessage = nil
            reload()
        }
        do {
            return try await engine.create(from: draft, supplied: supplied) { progress in
                Task { @MainActor in self.busyMessage = "\(draft.title): \(progress.message)" }
            }
        } catch {
            errorMessage = error.localizedDescription
            return engine.library.load()
                .filter { $0.isAuthored && $0.recipe.game.slug == draft.slug && $0.recipe.id == draft.recipeID }
                .max { $0.addedAt < $1.addedAt }
        }
    }

    /// Saves an edited recipe for a game, re-applying bottle settings when needed.
    func save(_ recipe: Recipe, for game: Game, forceReconfigure: Bool = false) async -> Bool {
        guard let engine else { return false }
        busyMessage = "Saving \(recipe.game.title)…"
        defer {
            busyMessage = nil
            reload()
        }
        do {
            let updated = try await engine.updateRecipe(recipe, for: game, forceReconfigure: forceReconfigure) { progress in
                Task { @MainActor in self.busyMessage = "Applying settings: \(progress.message)" }
            }
            if gameInWorkshop?.id == game.id { gameInWorkshop = updated }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func runInstaller(for game: Game) {
        guard let engine, let url = chooseFile(prompt: "Choose a Windows installer (.exe or .msi) to run in \(game.title)'s bottle") else { return }
        perform("Running \(url.lastPathComponent)…") {
            let updated = try await engine.runInstaller(url, for: game) { progress in
                Task { @MainActor in self.busyMessage = progress.message }
            }
            if self.gameInWorkshop?.id == game.id { self.gameInWorkshop = updated }
        }
    }

    func runTool(_ tool: WineTool, for game: Game) {
        guard let engine else { return }
        do {
            _ = try engine.runTool(tool, for: game)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealDriveC(of game: Game) {
        guard let engine, let bottle = try? engine.bottles.bottle(id: game.bottleID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([engine.bottles.prefix(of: bottle).appendingPathComponent("drive_c")])
    }

    /// Writes `recipe.yaml` next to the bottle and opens it in the player's YAML editor.
    func openRecipeFile(for game: Game) {
        guard let engine else { return }
        do {
            let url = try engine.writeRecipeFile(for: (try? engine.library.game(id: game.id)) ?? game)
            if !NSWorkspace.shared.open(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadRecipeFile(for game: Game) {
        guard let engine else { return }
        perform("Reloading the recipe file…") {
            let updated = try await engine.reloadRecipeFile(for: game) { progress in
                Task { @MainActor in self.busyMessage = "Applying settings: \(progress.message)" }
            }
            if self.gameInWorkshop?.id == game.id { self.gameInWorkshop = updated }
        }
    }

    /// Saves a copy of the recipe anywhere, for sharing outside GitHub.
    func exportRecipe(for game: Game) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(game.recipe.game.slug)-\(game.recipe.id).yaml"
        panel.allowedContentTypes = [.yaml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RecipeLoader.encode(game.recipe).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: GitHub

    var repository: CommunityRepository { community?.repository ?? .default }

    private static let githubUserKey = "githubUser"

    func restoreGitHubSession() async {
        guard let token = tokenStore.load() else {
            setGitHubUser(nil)
            return
        }
        // Show the remembered account straight away; refresh it when GitHub answers.
        if githubUser == nil, let data = UserDefaults.standard.data(forKey: Self.githubUserKey) {
            githubUser = try? JSONDecoder().decode(GitHubUser.self, from: data)
        }
        do {
            setGitHubUser(try await GitHubAPI(token: token).currentUser())
        } catch GitHubError.http(let status, _) where status == 401 {
            // The token was revoked on GitHub.
            try? tokenStore.delete()
            setGitHubUser(nil)
        } catch {
            // Offline: keep the token and the remembered account, and try again later.
        }
    }

    private func setGitHubUser(_ user: GitHubUser?) {
        if user?.avatarURL != githubUser?.avatarURL || user == nil { githubAvatar = nil }
        githubUser = user
        if user != nil, githubAvatar == nil { loadGitHubAvatar() }
        if let user, let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: Self.githubUserKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.githubUserKey)
        }
    }

    /// The account's picture at a given size in points (GitHub serves it at twice that, for Retina).
    func githubAvatarURL(points: Int) -> URL? {
        guard let url = githubUser?.avatarURL, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: String(points * 2))]
        return components.url
    }

    private func loadGitHubAvatar() {
        guard let url = githubAvatarURL(points: 64) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data),
                  githubUser?.avatarURL != nil else { return }
            githubAvatar = image
        }
    }

    /// The picture clipped to a circle at a fixed size. Toolbar menus draw their label as a plain
    /// image, ignoring SwiftUI clipping and frames, so the shape has to be in the image itself.
    func roundGitHubAvatar(points: CGFloat) -> NSImage? {
        guard let avatar = githubAvatar else { return nil }
        return NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            avatar.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    func openGitHubProfile() {
        guard let user = githubUser else { return }
        NSWorkspace.shared.open(user.profileURL ?? URL(string: "https://github.com/\(user.login)")!)
    }

    func signInToGitHub() {
        guard repository.isConfiguredForSubmissions else {
            errorMessage = GitHubError.notConfigured.errorDescription
            return
        }
        signInTask?.cancel()
        let flow = GitHubDeviceFlow(clientID: repository.oauthClientID)
        signInTask = Task {
            do {
                let code = try await flow.start()
                signInCode = code
                let token = try await flow.waitForToken(code)
                try tokenStore.save(token)
                setGitHubUser(try await GitHubAPI(token: token).currentUser())
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            signInCode = nil
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signInCode = nil
    }

    func signOutOfGitHub() {
        try? tokenStore.delete()
        setGitHubUser(nil)
    }

    func copyCodeAndOpenGitHub(_ code: DeviceCode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
        NSWorkspace.shared.open(code.verificationURI)
    }

    func submissionIssues(for game: Game) -> [SubmissionIssue] {
        SubmissionPlan.issues(for: game, recipe: CommunityCheck.recipeToSubmit(for: game) ?? game.recipe, repository: repository)
    }

    /// Submits a game's recipe as a pull request and records it on the game.
    /// Where a submission would go (maintainer branch or fork; new game, new recipe or revision).
    func submissionTarget(for game: Game) async -> Result<SubmissionTarget, Error> {
        guard let token = tokenStore.load() else { return .failure(GitHubError.notSignedIn) }
        let recipe = CommunityCheck.recipeToSubmit(for: game) ?? game.recipe
        do {
            return .success(try await RecipeSubmitter(repository: repository, token: token).target(for: recipe))
        } catch {
            return .failure(error)
        }
    }

    /// The icon and the screenshots the game's community check saved, while the check is current.
    func communityCheckPictures(for game: Game) -> (icon: URL?, captures: [(name: String, url: URL)]) {
        guard let engine, CommunityCheck.isCurrent(game) else { return (nil, []) }
        return (engine.communityCheckIcon(for: game), engine.communityCheckCaptures(for: game))
    }

    /// Which captures to share, cover first.
    func setSharedScreenshots(_ names: [String], for game: Game) {
        guard let engine else { return }
        do {
            try engine.setSharedScreenshots(names, for: game)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submit(_ game: Game, report: ReportDraft?, details: GameDetails? = nil, includeIcon: Bool = true) async -> Bool {
        guard let engine, let token = tokenStore.load() else {
            errorMessage = GitHubError.notSignedIn.errorDescription
            return false
        }
        let submitter = RecipeSubmitter(repository: repository, token: token)
        busyMessage = "Submitting \(game.title)…"
        defer {
            busyMessage = nil
            reload()
        }
        do {
            let current = (try? engine.library.game(id: game.id)) ?? game
            // Only the recipe the community check installed and ran is ever submitted.
            guard let recipe = CommunityCheck.recipeToSubmit(for: current) else {
                errorMessage = "Run the community check first (or again, if the recipe changed since it passed)."
                return false
            }
            let media = SubmissionMedia(
                icon: includeIcon ? communityCheckPictures(for: current).icon.flatMap { try? Data(contentsOf: $0) } : nil,
                screenshots: engine.sharedCommunityScreenshots(for: current).compactMap { try? Data(contentsOf: $0) }
            )
            let submission = try await submitter.submit(
                recipe, report: report, hardware: engine.hardware, previous: current.submission, game: details, media: media
            ) { message in
                Task { @MainActor in self.busyMessage = message }
            }
            var updated = current
            updated.submission = submission
            try engine.library.upsert(updated)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func submissionStatus(for submission: RecipeSubmission) async -> SubmissionStatus? {
        let submitter = RecipeSubmitter(repository: repository, token: tokenStore.load() ?? "")
        return try? await submitter.status(of: submission)
    }

    /// The Wine and graphics versions a game runs with, for reports.
    func componentVersions(for game: Game) -> (wine: String?, graphics: String?) {
        guard let engine, let stack = try? engine.selectStack(for: game) else {
            return (nil, nil)
        }
        return (stack.wine.manifest.composedFrom?.first ?? stack.wine.id, stack.graphics?.id)
    }
}
