import Foundation

/// How the Community list is narrowed and ordered, like the website's games page
/// (`filterGames`, `sortGames` and `facets` in `site/assets/catalogue-data.js`).
public struct CatalogueFilter: Equatable, Sendable {
    /// Nil means any.
    public var genre: String?
    public var graphics: String?
    /// Games rated at least this well. Nil means any rating, including unrated.
    public var minimumTier: PlayabilityTier?
    public var sort: CatalogueSort = .title

    public init(genre: String? = nil, graphics: String? = nil, minimumTier: PlayabilityTier? = nil, sort: CatalogueSort = .title) {
        self.genre = genre
        self.graphics = graphics
        self.minimumTier = minimumTier
        self.sort = sort
    }

    /// True when anything narrows the list (the order doesn't).
    public var isNarrowing: Bool { genre != nil || graphics != nil || minimumTier != nil }
}

public enum CatalogueSort: String, CaseIterable, Identifiable, Sendable {
    case title, rating, updated

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .rating: return "Rating"
        case .updated: return "Recently Reported"
        }
    }
}

public enum CatalogueBrowser {
    /// The genres and graphics layers the games use, for the filter menus.
    public static func facets(_ games: [IndexGame]) -> (genres: [String], graphics: [String]) {
        (Set(games.flatMap { $0.genres ?? [] }).sorted(), Set(games.flatMap { $0.graphics ?? [] }).sorted())
    }

    /// The games that match every word of the search and every filter, in the chosen order.
    public static func games(_ games: [IndexGame], query: String, filter: CatalogueFilter) -> [IndexGame] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let minimum = filter.minimumTier.map(rank) ?? -.infinity
        let matching = games.filter { game in
            let text = [game.title, game.publisher, game.developer, game.description].compactMap { $0 }.joined(separator: " ").lowercased()
            guard words.allSatisfy(text.contains) else { return false }
            if let genre = filter.genre, !(game.genres ?? []).contains(genre) { return false }
            if let graphics = filter.graphics, !(game.graphics ?? []).contains(graphics) { return false }
            return rank(game.summary?.tier) >= minimum
        }
        return sorted(matching, by: filter.sort)
    }

    static func sorted(_ games: [IndexGame], by sort: CatalogueSort) -> [IndexGame] {
        let byTitle: (IndexGame, IndexGame) -> Bool = { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        switch sort {
        case .title:
            return games.sorted(by: byTitle)
        case .rating:
            return games.sorted { a, b in
                let (ra, rb) = (rank(a.summary?.tier), rank(b.summary?.tier))
                return ra != rb ? ra > rb : byTitle(a, b)
            }
        case .updated:
            return games.sorted { a, b in
                let (ua, ub) = (a.updated ?? "", b.updated ?? "")
                return ua != ub ? ua > ub : byTitle(a, b)
            }
        }
    }

    /// Platinum 4 … Borked 0; unrated below all of them.
    static func rank(_ tier: PlayabilityTier?) -> Double { tier?.score ?? -1 }
}

extension CatalogueText {
    /// "mmo" → "MMO", "action" → "Action".
    public static func genre(_ genre: String) -> String {
        ["mmo": "MMO", "rpg": "RPG"][genre] ?? genre.prefix(1).uppercased() + genre.dropFirst()
    }
}
