import Foundation
import DistillerCore

/// A game's catalogue entry (`games/<slug>.yaml` in the community repository), filled in by
/// the player the first time a recipe for the game is submitted. Matches
/// `distiller-recipes/schema/game.schema.json`; keep the two in sync.
public struct GameDetails: Equatable, Sendable {
    public static let genres = [
        "action", "adventure", "arcade", "card", "casual", "fighting", "mmo", "platformer", "puzzle",
        "racing", "rpg", "shooter", "simulation", "sports", "strategy", "survival", "tool", "other",
    ]

    public var slug: String
    public var title: String
    public var publisher: String?
    public var developer: String?
    public var releaseYear: Int?
    public var genres: [String]
    public var description: String
    public var website: String?
    public var installer: PublicInstaller?

    public init(
        slug: String, title: String, publisher: String? = nil, developer: String? = nil, releaseYear: Int? = nil,
        genres: [String] = [], description: String = "", website: String? = nil, installer: PublicInstaller? = nil
    ) {
        self.slug = slug
        self.title = title
        self.publisher = publisher
        self.developer = developer
        self.releaseYear = releaseYear
        self.genres = genres
        self.description = description
        self.website = website
        self.installer = installer
    }

    /// Starting values from the recipe's own game block.
    public init(from recipe: Recipe) {
        self.init(
            slug: recipe.game.slug, title: recipe.game.title, publisher: recipe.game.publisher,
            website: recipe.game.website, installer: recipe.game.installer
        )
    }

    /// What would make the game file invalid, in plain language.
    public var problems: [String] {
        var problems: [String] = []
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { problems.append("Add a short description of the game, in your own words.") }
        if text.count > 1000 { problems.append("The description is longer than 1,000 characters.") }
        if let year = releaseYear, !(1970...2100).contains(year) { problems.append("The release year should be between 1970 and 2100.") }
        if genres.count > 6 { problems.append("Choose up to six genres.") }
        if let unknown = genres.first(where: { !Self.genres.contains($0) }) { problems.append("\(unknown) isn't one of the catalogue's genres.") }
        if let website, !website.isEmpty, !website.hasPrefix("https://") { problems.append("The website must start with https://.") }
        return problems
    }
}

/// `games/<slug>.yaml` as written. The year is an `Int` so PyYAML reads it as a number.
struct GameFile: Encodable {
    var schema = 1
    var slug: String
    var title: String
    var publisher: String?
    var developer: String?
    var releaseYear: Int?
    var genres: [String]?
    var description: String
    var website: String?
    var installer: PublicInstaller?

    init(_ details: GameDetails) {
        func clean(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        slug = details.slug
        title = details.title
        publisher = clean(details.publisher)
        developer = clean(details.developer)
        releaseYear = details.releaseYear
        genres = details.genres.isEmpty ? nil : details.genres
        description = details.description.trimmingCharacters(in: .whitespacesAndNewlines)
        website = clean(details.website)
        installer = details.installer
    }

    enum CodingKeys: String, CodingKey {
        case schema, slug, title, publisher, developer, genres, description, website, installer
        case releaseYear = "release_year"
    }
}

/// Where and how a submission will go, worked out before anything is sent.
public struct SubmissionTarget: Equatable, Sendable {
    /// The signed-in user can push to the community repository, so the branch goes there
    /// directly instead of to a fork.
    public var isMaintainer: Bool
    /// The repository already has `games/<slug>.yaml`; otherwise the submission adds it.
    public var gameExists: Bool
    /// The repository already has this recipe, so the submission revises it.
    public var recipeExists: Bool
    /// Whether the user may revise it: a maintainer, or one of the recipe's authors.
    public var canRevise: Bool

    public init(isMaintainer: Bool, gameExists: Bool, recipeExists: Bool, canRevise: Bool) {
        self.isMaintainer = isMaintainer
        self.gameExists = gameExists
        self.recipeExists = recipeExists
        self.canRevise = canRevise
    }
}

/// The pictures that go with a submission, as saved by the community check
/// (`CommunityMedia`): the game's icon (PNG) and up to three screenshots of the test run
/// (JPEG), cover first.
public struct SubmissionMedia: Equatable, Sendable {
    public var icon: Data?
    public var screenshots: [Data]

    public init(icon: Data? = nil, screenshots: [Data] = []) {
        self.icon = icon
        self.screenshots = Array(screenshots.prefix(CommunityMedia.maxSharedScreenshots))
    }
}
