import Foundation

/// A `distiller://` link, as the catalogue website uses for its "Install in Distiller" and
/// "Open in Distiller" buttons. Links only ever name a catalogue game and recipe; the app
/// looks them up in the community catalogue itself and always asks before installing.
///
///     distiller://install?game=guild-wars-2&recipe=dxvk
///     distiller://game/guild-wars-2
public enum DistillerLink: Equatable, Sendable {
    /// Install a catalogue recipe (after the player confirms).
    case install(game: String, recipe: String)
    /// Show a game in the Community tab.
    case showGame(String)

    public static let scheme = "distiller"

    /// Catalogue slugs and recipe ids: lowercase letters, digits and hyphens, as the
    /// recipes repository's schemas require.
    static func isSlug(_ text: String) -> Bool {
        guard (2...64).contains(text.count), let first = text.unicodeScalars.first,
              CharacterSet.lowercaseLetters.union(.decimalDigits).contains(first) else { return false }
        return text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// Nil for anything that isn't a well-formed Distiller link.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        func query(_ name: String) -> String? {
            let values = (components.queryItems ?? []).filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        switch components.host?.lowercased() {
        case "install":
            guard path.isEmpty, let game = query("game"), let recipe = query("recipe"),
                  Self.isSlug(game), Self.isSlug(recipe) else { return nil }
            self = .install(game: game, recipe: recipe)
        case "game":
            guard path.count == 1, Self.isSlug(path[0]) else { return nil }
            self = .showGame(path[0])
        default:
            return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .install(let game, let recipe):
            components.host = "install"
            components.queryItems = [URLQueryItem(name: "game", value: game), URLQueryItem(name: "recipe", value: recipe)]
        case .showGame(let game):
            components.host = "game"
            components.path = "/\(game)"
        }
        return components.url!
    }
}
