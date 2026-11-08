import Foundation
import XCTest
@testable import DistillerCommunity
@testable import DistillerCore

final class CommunityMatchTests: XCTestCase {
    static let installerSHA = String(repeating: "ab", count: 32)

    /// The player's own recipe for "Real Game", with a passing community check.
    func makeGame() throws -> Game {
        var draft = RecipeDraft(source: .folder(URL(fileURLWithPath: "/Games/Real Game")), title: "Real Game")
        draft.launchProgram = "Game.exe"
        draft.publicInstallerURL = "https://cdn.example-publisher.com/RealGameSetup.exe"
        let recipe = draft.makeRecipe()
        let shared = try CommunityCheck.shareableRecipe(from: recipe, installerSHA256: Self.installerSHA, launchExe: "C:\\Program Files\\Real Game\\Game.exe")
        var game = Game(id: "g", title: "Real Game", bottleID: "g", recipe: recipe, authored: true)
        game.communityCheck = CommunityCheckResult(
            checkedAt: Date(), recipe: shared, sourceFingerprint: CommunityCheck.fingerprint(recipe),
            installerSHA256: Self.installerSHA, hardwareKey: "M3-Pro-18gpu-18gb-macos27", wine: "wine-staging@11.21", graphics: nil
        )
        return game
    }

    func index(slug: String, recipeIDs: [String]) throws -> CommunityIndex {
        let recipes = recipeIDs.map { id in
            #"{"id":"\#(id)","path":"recipes/\#(slug)/\#(id).yaml","graphics":"d3dmetal","runner_family":"any","summary":{"reports":0},"by_hardware":{}}"#
        }
        let json = #"{"schema":2,"generated_at":"2026-11-07T00:00:00Z","repository":"https://github.com/x/y","games":[{"slug":"\#(slug)","title":"T","recipes":[\#(recipes.joined(separator: ","))]}]}"#
        return try JSONDecoder().decode(CommunityIndex.self, from: Data(json.utf8))
    }

    /// The catalogue's copy, as it comes back from YAML.
    func published(_ game: Game) throws -> Recipe {
        let recipe = try XCTUnwrap(CommunityCheck.recipeToSubmit(for: game))
        return try RecipeLoader.decode(yaml: RecipeLoader.encode(recipe))
    }

    func testNotAuthoredAndNoIndex() throws {
        var game = try makeGame()
        XCTAssertEqual(CommunityMatch.status(of: game, in: nil, published: nil), .unknown)
        game.authored = nil
        XCTAssertEqual(CommunityMatch.status(of: game, in: try index(slug: "other", recipeIDs: []), published: nil), .notAuthored)
        XCTAssertFalse(CommunityStatus.notAuthored.canShare)
    }

    func testNewGameAndNewRecipe() throws {
        let game = try makeGame()
        XCTAssertEqual(CommunityMatch.status(of: game, in: try index(slug: "another-game", recipeIDs: ["d3dmetal"]), published: nil), .newGame)
        XCTAssertEqual(CommunityMatch.status(of: game, in: try index(slug: "real-game", recipeIDs: ["dxvk"]), published: nil), .newRecipe)
        XCTAssertTrue(CommunityStatus.newGame.canShare)
        XCTAssertTrue(CommunityStatus.newRecipe.canShare)
    }

    func testPublishedSurvivesYAMLAndIgnoresAuthors() throws {
        let game = try makeGame()
        let catalogue = try index(slug: "real-game", recipeIDs: ["d3dmetal"])
        XCTAssertNotNil(CommunityMatch.indexRecipe(for: game, in: catalogue))
        // Without the catalogue's copy, a listed recipe can't be compared yet.
        XCTAssertEqual(CommunityMatch.status(of: game, in: catalogue, published: nil), .unknown)
        var copy = try published(game)
        copy.authors = ["someone"]
        XCTAssertEqual(CommunityMatch.status(of: game, in: catalogue, published: copy), .published)
        XCTAssertFalse(CommunityStatus.published.canShare)
    }

    func testChangedSettings() throws {
        let game = try makeGame()
        var copy = try published(game)
        copy.env = (copy.env ?? [:]).merging(["DXVK_ASYNC": "1"]) { $1 }
        XCTAssertEqual(CommunityMatch.status(of: game, in: try index(slug: "real-game", recipeIDs: ["d3dmetal"]), published: copy), .changed)
        XCTAssertTrue(CommunityStatus.changed.canShare)
    }

    func testInReviewUntilTheRecipeChanges() throws {
        var game = try makeGame()
        let submitted = try XCTUnwrap(CommunityCheck.recipeToSubmit(for: game))
        game.submission = RecipeSubmission(
            repository: "x/y", pullRequest: 7, url: "https://github.com/x/y/pull/7", fork: "me/y", branch: "recipe/real-game-d3dmetal",
            recipePath: "recipes/real-game/d3dmetal.yaml", recipeFingerprint: CommunityCheck.fingerprint(submitted)
        )
        let catalogue = try index(slug: "another-game", recipeIDs: [])
        XCTAssertEqual(CommunityMatch.status(of: game, in: catalogue, published: nil), .inReview)
        XCTAssertFalse(CommunityStatus.inReview.canShare)
        // Changing the recipe afterwards makes it worth submitting again.
        game.recipe.notes = "Only notes changed."
        XCTAssertEqual(CommunityMatch.status(of: game, in: catalogue, published: nil), .inReview, "Notes aren't settings")
        game.recipe.env = (game.recipe.env ?? [:]).merging(["DXVK_HUD": "fps"]) { $1 }
        XCTAssertEqual(CommunityMatch.status(of: game, in: catalogue, published: nil), .newGame)
    }

    func testJustForMeRoundTrips() throws {
        var game = try makeGame()
        game.justForMe = true
        let decoded = try JSONDecoder().decode(Game.self, from: JSONEncoder().encode(game))
        XCTAssertTrue(decoded.isJustForMe)
    }

    func testDecodesGitHubUserPicture() throws {
        let json = #"{"login":"octo","name":null,"avatar_url":"https://avatars.githubusercontent.com/u/1?v=4","html_url":"https://github.com/octo"}"#
        let user = try JSONDecoder().decode(GitHubUser.self, from: Data(json.utf8))
        XCTAssertEqual(user.avatarURL?.absoluteString, "https://avatars.githubusercontent.com/u/1?v=4")
        XCTAssertEqual(user.profileURL?.absoluteString, "https://github.com/octo")
    }
}
