import AppKit
import Foundation
import DistillerCommunity
import DistillerCore

/// A catalogue recipe a `distiller://install` link asked for, waiting for the player to confirm.
struct LinkInstallRequest: Identifiable {
    let game: IndexGame
    let recipe: IndexRecipe
    var id: String { "\(game.slug)/\(recipe.id)" }
}

/// `distiller://` links from the catalogue website (DistillerLink). A link only names a
/// catalogue game and recipe: Distiller looks them up in the catalogue itself, and installing
/// always waits for the player to confirm.
extension AppModel {
    func open(_ url: URL) {
        guard let link = DistillerLink(url: url) else {
            errorMessage = "Distiller can't open \(url.absoluteString). Links from the catalogue look like distiller://install?game=…&recipe=…"
            return
        }
        // Links that start Distiller arrive before the engine is ready; handle them after start().
        guard engine != nil else {
            pendingLink = link
            return
        }
        Task { await handle(link) }
    }

    func handlePendingLink() async {
        guard let link = pendingLink else { return }
        pendingLink = nil
        await handle(link)
    }

    private func handle(_ link: DistillerLink) async {
        NSApp.activate()
        switch link {
        case .showGame(let slug):
            guard let game = await catalogueGame(slug) else { return }
            showCommunityPage(game)
        case .install(let slug, let recipeID):
            guard let game = await catalogueGame(slug) else { return }
            guard let recipe = game.recipes.first(where: { $0.id == recipeID }) else {
                errorMessage = "The community catalogue has \(game.title), but no recipe called “\(recipeID)”. It may have been renamed or not be published yet."
                return
            }
            showCommunityPage(game)
            linkInstall = LinkInstallRequest(game: game, recipe: recipe)
        }
    }

    /// Opens a game's page in Community.
    func showCommunityPage(_ game: IndexGame) {
        sidebarSelection = .community
        communityQuery = ""
        communityPath = [game.slug]
    }

    /// The catalogue entry for a slug, downloading the catalogue again if it isn't there yet
    /// (a recipe merged since the last download).
    private func catalogueGame(_ slug: String) async -> IndexGame? {
        if let game = index?.games.first(where: { $0.slug == slug }) { return game }
        if let community {
            busyMessage = "Looking up \(slug) in the community catalogue…"
            if let fresh = try? await community.refreshIndex() {
                index = fresh
                forgetPublishedRecipes()
            }
            busyMessage = nil
        }
        if let game = index?.games.first(where: { $0.slug == slug }) { return game }
        errorMessage = index == nil
            ? "Distiller couldn't download the community catalogue to look up \(slug). Check your connection and try the link again."
            : "The community catalogue has no game called “\(slug)”. It may not be published yet."
        return nil
    }

    /// Games in the library installed from this catalogue recipe.
    func installedCopies(of request: LinkInstallRequest) -> [Game] {
        games.filter { $0.recipe.game.slug == request.game.slug && $0.recipe.id == request.recipe.id }
    }
}
