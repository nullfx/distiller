import Foundation

/// Per-game versions: a game (its bottle) follows the active version of each component, or
/// stays on one the player chose. Staying keeps a working game as it is when others update,
/// at the risk of missing fixes or breaking with newer recipes; Wine can only stay on a build
/// the bottle can still use (the one it's on, or newer: Wine can't move a bottle back).
public struct GameVersions: Sendable {
    public struct Choice: Sendable {
        public var kind: ComponentKind
        /// The version the game uses now (what it stays on, or the active one).
        public var current: InstalledComponent?
        /// The version it stays on, or nil when it follows the active version.
        public var stayOn: String?
        /// The versions it could stay on.
        public var options: [InstalledComponent]
        /// The active version, which "follow" means.
        public var active: InstalledComponent?
    }

    public var wine: Choice
    /// Nil when the game uses WineD3D, which is part of Wine.
    public var graphics: Choice?
    public var winetricks: Choice
}

extension DistillerEngine {
    public func versions(for game: Game) throws -> GameVersions {
        let bottle = try bottles.bottle(id: game.bottleID)
        let resolved = resolve(game.recipe, overrides: game.overrides)
        let installed = components.installed()
        let active = components.activeComponents()
        let made = BottleWine(bottle.wine)
        let original = installed.first { $0.manifest.kind == .wine && $0.manifest.id == made.id }

        let wineOptions = components.wineCandidates(for: resolved.runner)
            .filter { Self.wine($0, canOpen: bottle, madeBy: original) }
            .sorted { VersionNumber($0.manifest.version) > VersionNumber($1.manifest.version) }
        let wineCurrent = try? chooseWine(for: resolved, bottle: bottle)
        let wine = GameVersions.Choice(
            kind: .wine, current: wineCurrent, stayOn: bottle.stayOn?.wine, options: wineOptions,
            active: wineOptions.first { candidate in active.contains { $0.id == candidate.id } } ?? wineOptions.first
        )

        var graphics: GameVersions.Choice?
        if resolved.graphics != .wined3d {
            let options = installed
                .filter { $0.manifest.kind == .graphics && $0.manifest.provides == resolved.graphics }
                .sorted { VersionNumber($0.manifest.version) > VersionNumber($1.manifest.version) }
            let kept = bottle.stayOn?.graphics.flatMap { id in options.contains { $0.id == id } ? id : nil }
            graphics = GameVersions.Choice(
                kind: .graphics, current: try? graphicsLayer(resolved.graphics, for: bottle), stayOn: kept,
                options: options, active: components.graphicsLayer(resolved.graphics)
            )
        }

        let winetricksOptions = installed.filter { $0.manifest.kind == .winetricks }
            .sorted { VersionNumber($0.manifest.version) > VersionNumber($1.manifest.version) }
        let winetricksCurrent = bottle.stayOn?.winetricks.flatMap { id in winetricksOptions.first { $0.id == id } } ?? components.winetricks()
        let winetricks = GameVersions.Choice(
            kind: .winetricks, current: winetricksCurrent, stayOn: bottle.stayOn?.winetricks,
            options: winetricksOptions, active: components.winetricks()
        )
        return GameVersions(wine: wine, graphics: graphics, winetricks: winetricks)
    }

    /// Keeps `game` on `component`, or (nil) lets it follow the active version of `kind`.
    public func setStayOn(_ kind: ComponentKind, _ component: InstalledComponent?, for game: Game) throws {
        var bottle = try bottles.bottle(id: game.bottleID)
        if let component {
            guard component.manifest.kind == kind else {
                throw DistillerError.setupFailed("\(component.manifest.displayName) isn't a \(kind.displayName.lowercased()) component.")
            }
            if kind == .wine {
                let made = BottleWine(bottle.wine)
                let original = components.installed().first { $0.manifest.kind == .wine && $0.manifest.id == made.id }
                guard Self.wine(component, canOpen: bottle, madeBy: original) else {
                    throw DistillerError.bottleNeedsItsWine(
                        "\(game.title)'s bottle has already run with \(made.id) \(made.version), and Wine can't move a bottle back to an older or different kind of build. It can stay on \(made.version) or a newer build of the same kind."
                    )
                }
            }
        }
        var stayOn = bottle.stayOn ?? Bottle.StayOn()
        stayOn[kind] = component?.id
        bottle.stayOn = stayOn.isEmpty ? nil : stayOn
        try bottles.save(bottle)
    }
}
