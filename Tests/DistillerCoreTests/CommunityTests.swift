import XCTest
@testable import DistillerCommunity
@testable import DistillerCore

final class CommunityTests: XCTestCase {
    /// Decodes the index produced by distiller-recipes/scripts/build_index.py, so the Swift
    /// models and the Python builder can't drift apart unnoticed.
    func loadIndex() throws -> CommunityIndex {
        try JSONDecoder().decode(CommunityIndex.self, from: Data(contentsOf: fixtureURL("index", "json")))
    }

    func testDecodesBuilderOutput() throws {
        let index = try loadIndex()
        XCTAssertEqual(index.schema, 2)
        let game = try XCTUnwrap(index.games.first { $0.slug == "example-dx11-game" })
        let recipe = try XCTUnwrap(game.recipes.first { $0.id == "d3dmetal" })
        XCTAssertEqual(recipe.summary.reports, 3)
        XCTAssertEqual(recipe.byHardware[Macs.m3Pro.hardwareKey]?.tier, .platinum)
        // Schema 2: the game's details from games/<slug>.yaml and its summary.
        XCTAssertEqual(game.publisher, "Example Studio")
        XCTAssertEqual(game.releaseYear, 2021)
        XCTAssertEqual(game.genres, ["action", "rpg"])
        XCTAssertEqual(game.detail, "games/example-dx11-game.json")
        XCTAssertEqual(game.summary?.reports, 4)
        XCTAssertEqual(game.graphics, ["d3dmetal", "dxmt"])
        XCTAssertEqual(game.description?.hasSuffix("\n"), false)
        // Pictures, published next to the index.
        XCTAssertEqual(game.icon, "media/example-dx11-game/icon.png")
        XCTAssertEqual(recipe.screenshots, ["media/example-dx11-game/d3dmetal/1.jpg", "media/example-dx11-game/d3dmetal/2.jpg"])
        XCTAssertEqual(recipe.cover, "media/example-dx11-game/d3dmetal/1.jpg")
        let repository = CommunityRepository(owner: "nullfx", name: "distiller-recipes")
        XCTAssertEqual(repository.mediaURL(game.icon)?.absoluteString, "https://nullfx.github.io/distiller-recipes/media/example-dx11-game/icon.png")
        XCTAssertNil(repository.mediaURL("recipes/x.yaml"), "Only pictures")
        XCTAssertNil(repository.mediaURL("media/../index.json"))
        XCTAssertNil(index.games.first { $0.slug == "example-legacy-dx9-game" }?.icon)
    }

    func testDecodesSchemaOneIndex() throws {
        let old = #"{"schema":1,"generated_at":"2026-11-06T00:00:00Z","repository":"https://github.com/x/y","games":[{"slug":"a-game","title":"A Game","recipes":[]}]}"#
        let index = try JSONDecoder().decode(CommunityIndex.self, from: Data(old.utf8))
        XCTAssertEqual(index.games.first?.title, "A Game")
        XCTAssertNil(index.games.first?.summary)
    }

    func testRankingPrefersReportsFromMatchingMacs() throws {
        let game = try XCTUnwrap(try loadIndex().games.first { $0.slug == "example-dx11-game" })

        let forM1 = RecipeRanker.rank(game.recipes, for: Macs.m1Air)
        XCTAssertEqual(forM1.first?.recipe.id, "dxmt-low-memory")
        XCTAssertEqual(forM1.first?.evidence, "1 report from Macs like yours")

        // d3dmetal: two platinum/gold reports on this exact Mac (3.5, full weight) and one
        // silver on an M1 (2, quarter weight): (3.5×2 + 2×0.25) / 2.25 ≈ 3.33, so Gold.
        let forM3 = RecipeRanker.rank(game.recipes, for: Macs.m3Pro)
        XCTAssertEqual(forM3.first?.recipe.id, "d3dmetal")
        XCTAssertEqual(forM3.first?.score ?? 0, 3.333, accuracy: 0.01)
        XCTAssertEqual(forM3.first?.tier, .gold)
    }

    func testTierRoundingMatchesBuilder() {
        XCTAssertEqual(PlayabilityTier(score: 3.5), .platinum)
        XCTAssertEqual(PlayabilityTier(score: 2.49), .silver)
        XCTAssertEqual(PlayabilityTier(score: 0), .borked)
    }

    func testReportURLPrefillsIssueForm() throws {
        let client = CommunityClient(
            repository: CommunityRepository(owner: "someone", name: "distiller-recipes"),
            paths: DistillerPaths(root: FileManager.default.temporaryDirectory)
        )
        let url = client.reportURL(
            gameSlug: "example-dx11-game", recipeID: "d3dmetal", hardware: Macs.m3Pro, tier: .gold,
            averageFPS: 57.6, wineVersion: "crossover@24.0.7", graphicsVersion: nil, notes: "Fine"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(components.path, "/someone/distiller-recipes/issues/new")
        XCTAssertEqual(items["template"], "report.yml")
        XCTAssertEqual(items["tier"], "gold")
        XCTAssertEqual(items["fps_avg"], "58")
        XCTAssertEqual(items["gpu_cores"], "18")
        XCTAssertEqual(items["rosetta"], "true")
        XCTAssertNil(items["graphics_version"])
    }
}
