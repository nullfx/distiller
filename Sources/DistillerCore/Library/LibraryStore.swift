import Foundation

/// A game in the player's library: the recipe it was installed from, its bottle,
/// and the player's local overrides.
public struct Game: Codable, Identifiable, Equatable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var bottleID: String
    public var recipe: Recipe
    public var overrides: LocalOverrides?
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var secondsPlayed: Double
    /// True when the player built this game's recipe in Distiller rather than installing
    /// a recipe file or a community recipe. Authored recipes can be edited and submitted.
    public var authored: Bool?
    /// The community pull request for this recipe, once submitted.
    public var submission: RecipeSubmission?
    /// The latest passing community check: the shareable recipe was installed from the public
    /// installer in a fresh bottle and the game ran. Submitting needs one that still matches.
    public var communityCheck: CommunityCheckResult?
    /// The player keeps this recipe for themselves, so the library doesn't suggest sharing it.
    public var justForMe: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, recipe, overrides, authored, submission
        case communityCheck = "community_check"
        case justForMe = "just_for_me"
        case bottleID = "bottle_id"
        case addedAt = "added_at"
        case lastPlayedAt = "last_played_at"
        case secondsPlayed = "seconds_played"
    }

    public init(
        id: String,
        title: String,
        bottleID: String,
        recipe: Recipe,
        overrides: LocalOverrides? = nil,
        addedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        secondsPlayed: Double = 0,
        authored: Bool? = nil,
        submission: RecipeSubmission? = nil,
        communityCheck: CommunityCheckResult? = nil,
        justForMe: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.bottleID = bottleID
        self.recipe = recipe
        self.overrides = overrides
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.secondsPlayed = secondsPlayed
        self.authored = authored
        self.submission = submission
        self.communityCheck = communityCheck
        self.justForMe = justForMe
    }

    public var isAuthored: Bool { authored == true }
    public var isJustForMe: Bool { justForMe == true }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A recipe the player sent to the community repository as a pull request.
public struct RecipeSubmission: Codable, Equatable, Sendable {
    /// "owner/name" of the repository the pull request was opened against.
    public var repository: String
    public var pullRequest: Int
    public var url: String
    /// "owner/name" of the repository holding the branch (the player's fork, or the community
    /// repository itself for maintainers), and that branch.
    public var fork: String
    public var branch: String
    /// Repository-relative path of the recipe file, such as "recipes/my-game/d3dmetal.yaml".
    public var recipePath: String
    public var submittedAt: Date
    public var updatedAt: Date?
    /// `CommunityCheck.fingerprint` of the recipe as last sent, so the library can tell
    /// whether the player has changed it since.
    public var recipeFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case repository, url, fork, branch
        case pullRequest = "pull_request"
        case recipePath = "recipe_path"
        case submittedAt = "submitted_at"
        case updatedAt = "updated_at"
        case recipeFingerprint = "recipe_fingerprint"
    }

    public init(
        repository: String, pullRequest: Int, url: String, fork: String, branch: String,
        recipePath: String, submittedAt: Date = Date(), updatedAt: Date? = nil, recipeFingerprint: String? = nil
    ) {
        self.repository = repository
        self.pullRequest = pullRequest
        self.url = url
        self.fork = fork
        self.branch = branch
        self.recipePath = recipePath
        self.submittedAt = submittedAt
        self.updatedAt = updatedAt
        self.recipeFingerprint = recipeFingerprint
    }
}

/// The library is a single JSON file. Move to SQLite only if it ever gets slow.
public final class LibraryStore: @unchecked Sendable {
    public let file: URL
    private let lock = NSLock()

    public init(paths: DistillerPaths) {
        self.file = paths.libraryFile
    }

    public func load() -> [Game] {
        lock.lock()
        defer { lock.unlock() }
        return unlockedLoad()
    }

    public func game(id: String) throws -> Game {
        guard let game = load().first(where: { $0.id == id }) else { throw DistillerError.gameNotFound(id) }
        return game
    }

    public func upsert(_ game: Game) throws {
        lock.lock()
        defer { lock.unlock() }
        var games = unlockedLoad()
        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index] = game
        } else {
            games.append(game)
        }
        try unlockedSave(games)
    }

    public func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try unlockedSave(unlockedLoad().filter { $0.id != id })
    }

    private func unlockedLoad() -> [Game] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([Game].self, from: data)) ?? [])
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func unlockedSave(_ games: [Game]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(games).write(to: file, options: .atomic)
    }
}

/// Settings for a launch meant to find out why a game doesn't run. Applied as local
/// overrides for one launch; never saved to a recipe.
public enum DiagnosticLaunch {
    public static let environment: [String: String] = [
        // Errors from every channel, exceptions, module problems, and each DLL as it loads
        // (which shows whether a graphics layer's DLLs were used). fixme lines are mostly noise.
        "WINEDEBUG": "err+all,warn+seh,warn+module,+loaddll,fixme-all",
        // Apple's Metal Performance HUD: visible only when the game presents frames with Metal.
        "MTL_HUD_ENABLED": "1",
    ]
}


/// A passing community check (`DistillerEngine.runCommunityCheck`).
public struct CommunityCheckResult: Codable, Equatable, Sendable {
    public var checkedAt: Date
    /// The shareable recipe that was installed and run. This is what gets submitted.
    public var recipe: Recipe
    /// `CommunityCheck.fingerprint` of the player's own recipe at the time; a later change
    /// to it (other than notes or name) means checking again.
    public var sourceFingerprint: String
    public var installerSHA256: String
    public var hardwareKey: String
    /// "id@version" of the Wine build and graphics layer it ran with.
    public var wine: String
    public var graphics: String?
    /// Whether the check saved the game's icon (in `DistillerPaths.communityMedia/<game id>/`).
    public var hasIcon: Bool?
    /// File names of the screenshots captured during the test run, in the order taken.
    public var captures: [String]?
    /// The captures the player chose to share, in order; the first is the cover. At most
    /// `CommunityMedia.maxSharedScreenshots`.
    public var sharedCaptures: [String]?

    enum CodingKeys: String, CodingKey {
        case recipe, wine, graphics, captures
        case hasIcon = "has_icon"
        case sharedCaptures = "shared_captures"
        case checkedAt = "checked_at"
        case sourceFingerprint = "source_fingerprint"
        case installerSHA256 = "installer_sha256"
        case hardwareKey = "hardware_key"
    }

    public init(
        checkedAt: Date, recipe: Recipe, sourceFingerprint: String, installerSHA256: String, hardwareKey: String, wine: String, graphics: String?,
        hasIcon: Bool? = nil, captures: [String]? = nil, sharedCaptures: [String]? = nil
    ) {
        self.checkedAt = checkedAt
        self.recipe = recipe
        self.sourceFingerprint = sourceFingerprint
        self.installerSHA256 = installerSHA256
        self.hardwareKey = hardwareKey
        self.wine = wine
        self.graphics = graphics
        self.hasIcon = hasIcon
        self.captures = captures
        self.sharedCaptures = sharedCaptures
    }
}
