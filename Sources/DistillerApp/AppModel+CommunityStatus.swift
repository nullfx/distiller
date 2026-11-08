import Foundation
import DistillerCommunity
import DistillerCore

/// Whether each game the player built is in the community catalogue, and as it is now.
extension AppModel {
    func communityStatus(for game: Game) -> CommunityStatus {
        let published = index
            .flatMap { CommunityMatch.indexRecipe(for: game, in: $0) }
            .flatMap { publishedRecipes[$0.path] }
        return CommunityMatch.status(of: game, in: index, published: published)
    }

    /// Whether the library should show the "share with the community" badge for a game.
    func suggestsSharing(_ game: Game) -> Bool {
        !game.isJustForMe && communityStatus(for: game).canShare
    }

    /// Downloads the catalogue at launch without a status message or an error alert:
    /// offline, the cached copy (if any) stays.
    func refreshCommunityQuietly() async {
        guard let community else { return }
        if let fresh = try? await community.refreshIndex() {
            index = fresh
            forgetPublishedRecipes()
        }
        loadMissingPublishedRecipes()
    }

    /// The catalogue changed, so its copies of recipes may have too.
    func forgetPublishedRecipes() {
        publishedRecipes = [:]
        publishedRecipeFetches = []
        loadMissingPublishedRecipes()
    }

    /// Fetches the catalogue's copy of each built recipe it lists, once per catalogue download.
    func loadMissingPublishedRecipes() {
        guard let community, let index else { return }
        var wanted: [String: IndexRecipe] = [:]
        for game in games where game.isAuthored {
            if let entry = CommunityMatch.indexRecipe(for: game, in: index), !publishedRecipeFetches.contains(entry.path) {
                wanted[entry.path] = entry
            }
        }
        guard !wanted.isEmpty else { return }
        publishedRecipeFetches.formUnion(wanted.keys)
        Task {
            for (path, entry) in wanted {
                if let recipe = try? await community.fetchRecipe(entry) { publishedRecipes[path] = recipe }
            }
        }
    }

    /// "Just for me" recipes aren't suggested for the community.
    func setJustForMe(_ justForMe: Bool, for game: Game) {
        guard let engine else { return }
        do {
            var updated = (try? engine.library.game(id: game.id)) ?? game
            updated.justForMe = justForMe ? true : nil
            try engine.library.upsert(updated)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
