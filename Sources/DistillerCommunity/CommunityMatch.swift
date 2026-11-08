import Foundation
import DistillerCore

/// How a game in the library stands against the community catalogue.
public enum CommunityStatus: String, Equatable, Sendable {
    /// Installed from a recipe file or the community, rather than built here. Nothing to share.
    case notAuthored
    /// There's no catalogue to compare with yet (never downloaded, or offline).
    case unknown
    /// The catalogue has no entry for this game.
    case newGame
    /// The catalogue has the game, but not this recipe.
    case newRecipe
    /// The catalogue has this recipe, with different settings.
    case changed
    /// Submitted as it is now; the pull request hasn't reached the catalogue yet.
    case inReview
    /// The catalogue has this recipe as it is now.
    case published

    /// Whether the library should suggest submitting the game.
    public var canShare: Bool {
        switch self {
        case .newGame, .newRecipe, .changed: return true
        case .notAuthored, .unknown, .inReview, .published: return false
        }
    }
}

public enum CommunityMatch {
    /// The catalogue entry for a game's recipe, when the catalogue has one.
    public static func indexRecipe(for game: Game, in index: CommunityIndex) -> IndexRecipe? {
        index.games.first { $0.slug == game.recipe.game.slug }?.recipes.first { $0.id == game.recipe.id }
    }

    /// Compares a game with the catalogue.
    ///
    /// - Parameters:
    ///   - index: the catalogue, or nil when it hasn't been downloaded.
    ///   - published: the catalogue's copy of this recipe, when it has one and it has been
    ///     downloaded. Without it, a recipe the catalogue lists can't be told apart from a
    ///     changed one, so the answer is `.unknown`.
    public static func status(of game: Game, in index: CommunityIndex?, published: Recipe?) -> CommunityStatus {
        guard game.isAuthored else { return .notAuthored }
        guard let index else { return .unknown }
        // What a submission would send: the community-checked recipe when it's current.
        let candidate = CommunityCheck.fingerprint(CommunityCheck.recipeToSubmit(for: game) ?? game.recipe)
        let inReview = game.submission?.recipeFingerprint == candidate

        guard let entry = index.games.first(where: { $0.slug == game.recipe.game.slug }) else {
            return inReview ? .inReview : .newGame
        }
        guard entry.recipes.contains(where: { $0.id == game.recipe.id }) else {
            return inReview ? .inReview : .newRecipe
        }
        guard let published else { return .unknown }
        if CommunityCheck.fingerprint(published) == candidate { return .published }
        return inReview ? .inReview : .changed
    }
}
