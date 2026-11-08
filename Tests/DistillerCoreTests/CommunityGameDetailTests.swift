import XCTest
@testable import DistillerCommunity
@testable import DistillerCore

final class CommunityGameDetailTests: XCTestCase {
    /// `Fixtures/game-detail.json` is distiller-recipes' `games/example-dx11-game.json`, made by
    /// `scripts/build_index.py --include-examples`, so the model can't drift from the builder.
    func testDecodesBuilderOutput() throws {
        let detail = try JSONDecoder().decode(CommunityGameDetail.self, from: Data(contentsOf: fixtureURL("game-detail", "json")))
        XCTAssertEqual(detail.slug, "example-dx11-game")
        let recipe = try XCTUnwrap(detail.recipe("d3dmetal"))
        XCTAssertEqual(recipe.path, "recipes/example-dx11-game/d3dmetal.yaml")
        XCTAssertEqual(recipe.recipe?.stack.graphics, .d3dmetal)
        XCTAssertEqual(recipe.reports.count, 3)
        let report = try XCTUnwrap(recipe.reports.first)
        XCTAssertEqual(report.tier, .gold)
        XCTAssertEqual(report.fpsAverage, 58)
        XCTAssertEqual(report.hardwareKey, "M3-Pro-18gpu-18gb-macos27")
        XCTAssertEqual(report.notes, "Example only.")
        XCTAssertNotNil(detail.recipe("dxmt-low-memory")?.recipe)
    }

    func testOddEntriesDontHideTheRest() throws {
        let json = #"""
        {"slug":"a-game","title":"A Game","recipes":[
          {"id":"good","path":"recipes/a-game/good.yaml","recipe":{"nonsense":true},
           "reports":[{"tier":"mythic","date":"2026-11-01"},{"tier":"silver","fps_avg":"fast"},42]}
        ]}
        """#
        let recipe = try XCTUnwrap(JSONDecoder().decode(CommunityGameDetail.self, from: Data(json.utf8)).recipe("good"))
        XCTAssertNil(recipe.recipe, "A recipe that doesn't decode is left out, not the page")
        XCTAssertEqual(recipe.reports.count, 2)
        XCTAssertNil(recipe.reports[0].tier, "Unknown ratings are shown as unrated")
        XCTAssertEqual(recipe.reports[1].tier, .silver)
        XCTAssertNil(recipe.reports[1].fpsAverage)
    }

    func testDescribesMacsLikeTheWebsite() {
        XCTAssertEqual(CatalogueText.hardware("M3-Pro-18gpu-36gb-macos27"), "M3 Pro · 18-core GPU · 36 GB · macOS 27")
        XCTAssertEqual(CatalogueText.hardware("M1-Base-8gpu-8gb-macos26"), "M1 · 8-core GPU · 8 GB · macOS 26")
        XCTAssertEqual(CatalogueText.hardware("something-else"), "something-else")
        XCTAssertEqual(CatalogueText.hardware("M3-Pro-xgpu-36gb-macos27"), "M3-Pro-xgpu-36gb-macos27")
    }

    func testSummarisesARecipe() throws {
        let detail = try JSONDecoder().decode(CommunityGameDetail.self, from: Data(contentsOf: fixtureURL("game-detail", "json")))
        let recipe = try XCTUnwrap(detail.recipe("d3dmetal")?.recipe)
        let lines = Dictionary(uniqueKeysWithValues: CatalogueText.settings(of: recipe).map { ($0.label, $0.value) })
        XCTAssertEqual(lines["Graphics"], "D3DMetal")
        XCTAssertEqual(lines["Windows version"], "Windows 10")
        XCTAssertEqual(lines["Winetricks"], "vcrun2022, d3dcompiler_47")
        XCTAssertEqual(lines["DLL overrides"], "xinput1_3=builtin")
        XCTAssertEqual(lines["Environment"], "MTL_HUD_ENABLED=0")
        XCTAssertEqual(lines["Arguments"], "-windowed")
        XCTAssertEqual(CatalogueText.settings(of: recipe).first?.label, "Wine")
    }

    func testOnlyFollowsHTTPSLinks() {
        XCTAssertEqual(CatalogueText.safeLink("https://www.example.com/")?.host, "www.example.com")
        XCTAssertNil(CatalogueText.safeLink("http://example.com"))
        XCTAssertNil(CatalogueText.safeLink("javascript:alert(1)"))
        XCTAssertNil(CatalogueText.safeLink("file:///etc/passwd"))
        XCTAssertNil(CatalogueText.safeLink(nil))
    }

    func testRefusesUnexpectedPaths() async throws {
        let client = CommunityClient(paths: DistillerPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), storage: StorageSettings()))
        let game = try JSONDecoder().decode(IndexGame.self, from: Data(#"{"slug":"a-game","title":"A Game","recipes":[],"detail":"../secrets.json"}"#.utf8))
        await XCTAssertThrowsErrorAsync(try await client.fetchDetail(for: game))
        await XCTAssertThrowsErrorAsync(try await client.fetchRecipeText(path: "recipes/../index.json"))
        await XCTAssertThrowsErrorAsync(try await client.fetchRecipeText(path: "scripts/build_index.py"))
    }
}

