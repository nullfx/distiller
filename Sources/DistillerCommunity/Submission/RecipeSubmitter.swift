import Foundation
import Yams
import DistillerCore

/// A compatibility report sent alongside a recipe, in the format of `schema/report.schema.json`.
public struct ReportDraft: Equatable, Sendable {
    public var tier: PlayabilityTier
    public var averageFPS: Double?
    public var notes: String
    public var wineVersion: String?
    public var graphicsVersion: String?

    public init(tier: PlayabilityTier, averageFPS: Double? = nil, notes: String = "", wineVersion: String? = nil, graphicsVersion: String? = nil) {
        self.tier = tier
        self.averageFPS = averageFPS
        self.notes = notes
        self.wineVersion = wineVersion
        self.graphicsVersion = graphicsVersion
    }
}

/// One problem found before submitting. Errors block the submission; warnings don't.
public struct SubmissionIssue: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public var id: String { message }
}

/// What the community repository will see, and the checks run before it's sent.
public enum SubmissionPlan {
    public static func recipePath(_ recipe: Recipe) -> String {
        "recipes/\(recipe.game.slug)/\(recipe.id).yaml"
    }

    /// `reports/<game>/<recipe>/<login>-<yyyymmdd>.yaml`, a valid report file name.
    public static func reportPath(_ recipe: Recipe, login: String, date: Date) -> String {
        let user = RecipeDraft.makeSlug(login)
        return "reports/\(recipe.game.slug)/\(recipe.id)/\(user)-\(dayStamp(date).replacingOccurrences(of: "-", with: "")).yaml"
    }

    /// "recipe/<game>/<recipe>", with "-update" for a revision of a merged recipe and "-2" and
    /// so on when the name is taken.
    public static func branchName(_ recipe: Recipe, isUpdate: Bool = false, attempt: Int = 1) -> String {
        let base = "recipe/\(recipe.game.slug)/\(recipe.id)\(isUpdate ? "-update" : "")"
        return attempt <= 1 ? base : "\(base)-\(attempt)"
    }

    public static func gamePath(_ slug: String) -> String { "games/\(slug).yaml" }

    /// The game's icon in the catalogue: one per game, added with its first recipe.
    public static func iconPath(_ slug: String) -> String { "media/\(slug)/icon.png" }

    /// The recipe's nth screenshot (1-based; 1 is the cover), from its community check.
    public static func screenshotPath(_ recipe: Recipe, number: Int) -> String {
        "media/\(recipe.game.slug)/\(recipe.id)/\(number).jpg"
    }

    public static func gameYAML(_ details: GameDetails) throws -> String {
        "# \(details.title). Added from Distiller.\n" + (try YAMLEncoder().encode(GameFile(details)))
    }

    /// The recipe as submitted: the player's GitHub login added to `authors`.
    public static func prepared(_ recipe: Recipe, login: String) -> Recipe {
        var recipe = recipe
        var authors = recipe.authors ?? []
        if !authors.contains(where: { $0.caseInsensitiveCompare(login) == .orderedSame }) {
            authors.append(login)
        }
        recipe.authors = authors
        return recipe
    }

    public static func recipeYAML(_ recipe: Recipe) throws -> String {
        "# \(recipe.game.title): \(recipe.name ?? recipe.id). Submitted from Distiller.\n" + (try RecipeLoader.encode(recipe))
    }

    public static func reportYAML(_ report: ReportDraft, recipe: Recipe, hardware: HardwareProfile, date: Date) throws -> String {
        let file = ReportFile(
            schema: 1,
            game: recipe.game.slug,
            recipe: recipe.id,
            tier: report.tier.rawValue,
            // Whole frames: Yams writes some doubles as "6e+1", which YAML 1.1 readers take as text.
            fpsAvg: report.averageFPS.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1000 ? Int($0.rounded()) : nil },
            hardware: .init(
                chip: String(hardware.chip.prefix(60)),
                chipFamily: hardware.chipFamily,
                chipTier: hardware.chipTier,
                gpuCores: hardware.gpuCores,
                memoryGB: hardware.memoryGB,
                macos: hardware.macOS,
                rosetta: hardware.rosetta
            ),
            components: (report.wineVersion == nil && report.graphicsVersion == nil)
                ? nil : .init(wine: report.wineVersion, graphics: report.graphicsVersion),
            date: dayStamp(date),
            notes: report.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(report.notes.prefix(2000))
        )
        return try YAMLEncoder().encode(file)
    }

    public static func pullRequestTitle(_ recipe: Recipe, isUpdate: Bool) -> String {
        "\(isUpdate ? "Update" : "Add") recipe: \(recipe.game.title) (\(recipe.id))"
    }

    public static func pullRequestBody(_ recipe: Recipe, hardware: HardwareProfile, report: ReportDraft?, media: SubmissionMedia = SubmissionMedia()) -> String {
        var lines = [
            "## What this changes",
            "",
            "\(recipe.forkedFrom == nil ? "New recipe" : "A fork of `\(recipe.forkedFrom!)`") for **\(recipe.game.title)** (`\(recipe.game.slug)/\(recipe.id)`), submitted from Distiller.",
            "",
            "- Graphics: \(recipe.stack.graphics.displayName)",
            "- Wine: \(recipe.stack.runner.family)\(recipe.stack.runner.minVersion.map { " \($0) or later" } ?? "")",
            "- Made on: \(hardware.summary)",
        ]
        if let report {
            lines.append("- Includes a compatibility report: **\(report.tier.displayName)**\(report.averageFPS.map { ", about \(Int($0.rounded())) FPS" } ?? "")")
        }
        if !media.screenshots.isEmpty {
            let paths = media.screenshots.indices.map { "`\(screenshotPath(recipe, number: $0 + 1))`" }
            lines.append("- Includes \(paths.count == 1 ? "a screenshot" : "\(paths.count) screenshots") from the community check: \(paths.joined(separator: ", "))")
        }
        if media.icon != nil {
            lines.append("- Includes the game's icon, if the catalogue has none yet: `\(iconPath(recipe.game.slug))`")
        }
        if let notes = recipe.notes, !notes.isEmpty {
            lines += ["", "> " + notes.replacingOccurrences(of: "\n", with: "\n> ")]
        }
        lines += [
            "",
            "## Checklist",
            "",
            "- [x] Distiller validated the recipe before submitting it.",
            "- [ ] `python scripts/build_index.py --check` passes (the Validate check runs it).",
            "- [x] Every `download` step points at an official source and has the correct `sha256`.",
            "- [x] `game.installer.url` is the publisher's official installer, and the recipe installs from it.",
            "- [x] Distiller's community check passed: it installed the game from that installer in a fresh bottle and the game reached its login or menu.",
            "- [x] Any screenshot is the contributor's own capture of the community check, made by Distiller.",
            "- [x] I agree to license my contribution under this repository's MIT license (pictures in `media/` stay the publisher's).",
        ]
        return lines.joined(separator: "\n")
    }

    /// Checks beyond `RecipeLoader.validate` that matter for a shared recipe.
    public static func issues(for game: Game, recipe: Recipe, repository: CommunityRepository) -> [SubmissionIssue] {
        var issues: [SubmissionIssue] = []
        func error(_ message: String) { issues.append(SubmissionIssue(severity: .error, message: message)) }
        func warning(_ message: String) { issues.append(SubmissionIssue(severity: .warning, message: message)) }

        if !repository.isConfiguredForSubmissions {
            error(GitHubError.notConfigured.errorDescription ?? "Submitting isn't set up.")
        }
        do {
            try RecipeLoader.validate(recipe)
        } catch {
            issues.append(SubmissionIssue(severity: .error, message: error.localizedDescription))
        }
        if recipe.launch == nil {
            error("Choose the program to launch before sharing the recipe.")
        }
        // Shared recipes install from the publisher's official installer, and Distiller has to
        // prove that works (the community check) before anything is submitted.
        if game.recipe.game.installer == nil {
            error("Add the game's official public installer (its download link from the publisher). Shared recipes install from it.")
        } else if game.communityCheck == nil {
            error("Run the community check: Distiller installs the game from its public installer in a fresh bottle and starts it, to prove the recipe works for other players.")
        } else if !CommunityCheck.isCurrent(game) {
            error("The recipe changed since its community check passed. Run the check again.")
        }
        if recipe.game.slug.hasPrefix("example-") {
            error("Game slugs starting with \"example-\" are reserved for the repository's samples.")
        }
        if let installer = recipe.game.installer, (recipe.install ?? []).contains(where: { step in
            if case .download(let download) = step { return download.url != installer.url }
            return false
        }) {
            error("Shared recipes may only download the game's official installer (game.installer.url).")
        }
        if game.lastPlayedAt == nil {
            warning("You haven't played the game with this recipe yet. Launch it at least once so you know it works.")
        }
        if (recipe.notes ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            warning("Add notes for other players: which version of the game you used and anything that needed fixing.")
        }
        return issues
    }

    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// The report file format. Field order matches the schema's examples.
struct ReportFile: Encodable {
    var schema: Int
    var game: String
    var recipe: String
    var tier: String
    var fpsAvg: Int?
    var hardware: Hardware
    var components: Components?
    var date: String
    var notes: String?

    struct Hardware: Encodable {
        var chip: String
        var chipFamily: String
        var chipTier: String
        var gpuCores: Int?
        var memoryGB: Int
        var macos: String
        var rosetta: Bool
        enum CodingKeys: String, CodingKey {
            case chip, macos, rosetta
            case chipFamily = "chip_family"
            case chipTier = "chip_tier"
            case gpuCores = "gpu_cores"
            case memoryGB = "memory_gb"
        }
    }

    struct Components: Encodable {
        var wine: String?
        var graphics: String?
    }

    enum CodingKeys: String, CodingKey {
        case schema, game, recipe, tier, hardware, components, date, notes
        case fpsAvg = "fps_avg"
    }
}

/// Where a submitted pull request stands.
public struct SubmissionStatus: Equatable, Sendable {
    public enum State: String, Sendable { case open, merged, closed }
    public enum Checks: String, Sendable { case none, pending, passing, failing }

    public var state: State
    public var checks: Checks
    public var url: URL

    public var summary: String {
        switch state {
        case .merged: return "Merged. It appears in Community once the index is rebuilt."
        case .closed: return "Closed without merging."
        case .open:
            switch checks {
            case .none: return "Waiting for review. Checks haven't started; a maintainer may need to approve them."
            case .pending: return "Checks are running."
            case .passing: return "Checks passed. Waiting for a maintainer to review and merge."
            case .failing: return "Checks failed. Open the pull request to see why, fix the recipe and submit again."
            }
        }
    }
}

/// Sends a recipe to the community repository the standard GitHub way: a new branch with
/// one commit (recipe, optional report, and the game's file when it's new), then a pull
/// request. Maintainers' branches go in the community repository itself; everyone else's go
/// in their fork. Nothing is pushed to the base branch. The repository's Validate workflow
/// checks the pull request, a maintainer merges it, and the published index then includes it.
public final class RecipeSubmitter: @unchecked Sendable {
    public let repository: CommunityRepository
    let api: GitHubAPI
    let sleep: @Sendable (Int) async throws -> Void

    public init(
        repository: CommunityRepository,
        token: String,
        session: URLSession = .shared,
        sleep: @escaping @Sendable (Int) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
    ) {
        self.repository = repository
        self.api = GitHubAPI(token: token, session: session)
        self.sleep = sleep
    }

    public func signedInUser() async throws -> GitHubUser {
        try await api.currentUser()
    }

    /// Works out where a submission will go: whether the user maintains the repository (the
    /// branch goes there directly) or works through a fork, whether the game and the recipe
    /// already exist upstream, and whether the user may revise an existing recipe.
    public func target(for recipe: Recipe) async throws -> SubmissionTarget {
        guard repository.isConfiguredForSubmissions else { throw GitHubError.notConfigured }
        let user = try await api.currentUser()
        let upstream = repository.fullName
        let isMaintainer = try await api.repository(upstream)?.canPush ?? false
        let gameExists = try await api.fileExists(upstream, path: SubmissionPlan.gamePath(recipe.game.slug), ref: repository.branch)
        let recipeExists = try await api.fileExists(upstream, path: SubmissionPlan.recipePath(recipe), ref: repository.branch)
        let isAuthor = recipeExists ? try await isPublishedAuthor(of: recipe, login: user.login) : false
        return SubmissionTarget(isMaintainer: isMaintainer, gameExists: gameExists, recipeExists: recipeExists, canRevise: isMaintainer || isAuthor)
    }

    /// Whether `login` is among the authors of the recipe as published in the community
    /// repository. The player's own copy doesn't count: anyone could add themselves to it.
    func isPublishedAuthor(of recipe: Recipe, login: String) async throws -> Bool {
        guard let text = try await api.fileText(repository.fullName, path: SubmissionPlan.recipePath(recipe), ref: repository.branch),
              let published = try? RecipeLoader.decode(yaml: text) else { return false }
        return (published.authors ?? []).contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }

    /// Submits `recipe` as a pull request. Maintainers (who can push to the community
    /// repository) get a new branch there; everyone else gets one on their fork. Nothing is
    /// ever pushed to the base branch. The commit adds `games/<slug>.yaml` from `game` when
    /// the repository doesn't have the game yet. A recipe that already exists upstream is
    /// revised (an "-update" branch) when the user is a maintainer or one of its authors.
    /// With `previous` (an earlier submission whose pull request is still open), the new
    /// version is pushed to the same branch, which updates that pull request.
    public func submit(
        _ recipe: Recipe,
        report: ReportDraft?,
        hardware: HardwareProfile,
        previous: RecipeSubmission?,
        game: GameDetails? = nil,
        media: SubmissionMedia = SubmissionMedia(),
        date: Date = Date(),
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> RecipeSubmission {
        guard repository.isConfiguredForSubmissions else { throw GitHubError.notConfigured }
        let upstream = repository.fullName
        let base = repository.branch

        progress("Checking your GitHub account")
        let user = try await api.currentUser()
        let recipe = SubmissionPlan.prepared(recipe, login: user.login)
        try RecipeLoader.validate(recipe)
        let recipePath = SubmissionPlan.recipePath(recipe)
        let isMaintainer = try await api.repository(upstream)?.canPush ?? false

        var files: [String: RepositoryFile] = [recipePath: .text(try SubmissionPlan.recipeYAML(recipe))]
        if let report {
            files[SubmissionPlan.reportPath(recipe, login: user.login, date: date)] =
                .text(try SubmissionPlan.reportYAML(report, recipe: recipe, hardware: hardware, date: date))
        }
        let gamePath = SubmissionPlan.gamePath(recipe.game.slug)
        if try await !api.fileExists(upstream, path: gamePath, ref: base) {
            guard let game, game.problems.isEmpty else { throw GitHubError.gameDetailsNeeded(slug: recipe.game.slug) }
            files[gamePath] = .text(try SubmissionPlan.gameYAML(game))
        }
        // The icon is the game's, so it's only added when the catalogue has none; the
        // screenshots belong to this recipe and replace any earlier ones (extra old ones are removed).
        let iconPath = SubmissionPlan.iconPath(recipe.game.slug)
        if let icon = media.icon, try await !api.fileExists(upstream, path: iconPath, ref: base) {
            files[iconPath] = .binary(icon)
        }
        if !media.screenshots.isEmpty {
            for (offset, screenshot) in media.screenshots.enumerated() {
                files[SubmissionPlan.screenshotPath(recipe, number: offset + 1)] = .binary(screenshot)
            }
            for number in stride(from: media.screenshots.count + 1, through: CommunityMedia.maxSharedScreenshots, by: 1) {
                let path = SubmissionPlan.screenshotPath(recipe, number: number)
                if try await api.fileExists(upstream, path: path, ref: base) { files[path] = .delete }
            }
        }

        // An open pull request from an earlier submission: push to its branch again.
        if let previous, previous.repository == upstream, previous.recipePath == recipePath,
           let pull = try? await api.pullRequest(upstream, number: previous.pullRequest), pull.state == "open",
           let head = try await api.branchHead(previous.fork, branch: previous.branch) {
            progress("Updating your pull request")
            let commit = try await commit(files, onto: head, in: previous.fork, message: "Update \(recipePath)")
            try await api.updateBranch(previous.fork, branch: previous.branch, sha: commit)
            var result = previous
            result.updatedAt = date
            result.recipeFingerprint = CommunityCheck.fingerprint(recipe)
            return result
        }

        let isUpdate = try await api.fileExists(upstream, path: recipePath, ref: base)
        if isUpdate, !isMaintainer {
            // Checked against the published recipe; `recipe` already has the login added.
            guard try await isPublishedAuthor(of: recipe, login: user.login) else { throw GitHubError.recipeExists(path: recipePath) }
        }

        // Maintainers branch in the community repository itself; others in their fork.
        let target: String
        if isMaintainer {
            target = upstream
        } else {
            progress("Preparing your copy of \(upstream)")
            target = try await ensureFork(of: upstream, login: user.login)
            _ = await api.mergeUpstream(fork: target, branch: base)
        }
        guard let parent = try await api.branchHead(upstream, branch: base) else {
            throw GitHubError.invalidResponse("\(upstream) has no \(base) branch.")
        }
        var branch = SubmissionPlan.branchName(recipe, isUpdate: isUpdate)
        var attempt = 1
        while try await api.branchHead(target, branch: branch) != nil {
            attempt += 1
            branch = SubmissionPlan.branchName(recipe, isUpdate: isUpdate, attempt: attempt)
        }
        guard branch != base else { throw GitHubError.invalidResponse("refusing to push to \(base).") }

        progress(isUpdate ? "Committing the revised recipe" : "Committing the recipe")
        let commit = try await commit(files, onto: parent, in: target, message: "\(isUpdate ? "Update" : "Add") \(recipePath)")
        try await api.createBranch(target, branch: branch, sha: commit)

        progress("Opening the pull request")
        let head = isMaintainer ? branch : "\(target.split(separator: "/").first.map(String.init) ?? user.login):\(branch)"
        let pull = try await api.createPullRequest(
            upstream,
            title: SubmissionPlan.pullRequestTitle(recipe, isUpdate: isUpdate),
            head: head,
            base: base,
            body: SubmissionPlan.pullRequestBody(recipe, hardware: hardware, report: report, media: media)
        )
        return RecipeSubmission(
            repository: upstream, pullRequest: pull.number, url: pull.htmlURL, fork: target, branch: branch,
            recipePath: recipePath, submittedAt: date, recipeFingerprint: CommunityCheck.fingerprint(recipe)
        )
    }

    public func status(of submission: RecipeSubmission) async throws -> SubmissionStatus {
        let pull = try await api.pullRequest(submission.repository, number: submission.pullRequest)
        let state: SubmissionStatus.State = pull.merged == true ? .merged : (pull.state == "open" ? .open : .closed)
        let runs = (try? await api.checkRuns(submission.repository, sha: pull.head.sha)) ?? []
        let checks: SubmissionStatus.Checks
        if runs.isEmpty {
            checks = .none
        } else if runs.contains(where: { $0.status != "completed" }) {
            checks = .pending
        } else if runs.allSatisfy({ ["success", "neutral", "skipped"].contains($0.conclusion ?? "") }) {
            checks = .passing
        } else {
            checks = .failing
        }
        return SubmissionStatus(state: state, checks: checks, url: URL(string: pull.htmlURL) ?? repository.webURL)
    }

    // MARK: Steps

    /// The player's fork of `upstream`, created if needed and waited for until it's usable.
    func ensureFork(of upstream: String, login: String) async throws -> String {
        let upstreamName = String(upstream.split(separator: "/").last ?? "")
        if let existing = try await api.repository("\(login)/\(upstreamName)"),
           existing.fork, existing.parent?.fullName.caseInsensitiveCompare(upstream) == .orderedSame {
            return existing.fullName
        }
        let fork = try await api.createFork(of: upstream)
        for _ in 0..<30 {
            if try await api.branchHead(fork.fullName, branch: fork.defaultBranch) != nil {
                return fork.fullName
            }
            try await sleep(2)
        }
        throw GitHubError.forkNotReady(fork.fullName)
    }

    func commit(_ files: [String: RepositoryFile], onto parent: String, in repository: String, message: String) async throws -> String {
        let baseTree = try await api.treeOfCommit(repository, sha: parent)
        let tree = try await api.createTree(repository, baseTree: baseTree, files: files)
        return try await api.createCommit(repository, message: message, tree: tree, parents: [parent])
    }
}
