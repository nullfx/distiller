import XCTest
@testable import DistillerCommunity

/// The same games and expectations as the website's tests (`site/tests/catalogue-data.test.mjs`),
/// so the app and the site filter and sort alike.
final class CatalogueBrowserTests: XCTestCase {
    let games: [IndexGame] = {
        let json = #"""
        [
          {"slug":"guild-wars-2","title":"Guild Wars 2","publisher":"ArenaNet","genres":["mmo","rpg"],"graphics":["dxvk"],
           "summary":{"tier":"gold","reports":1},"updated":"2026-11-07","recipes":[]},
          {"slug":"another-game","title":"another Game","genres":["puzzle"],"graphics":["d3dmetal"],
           "summary":{"tier":"platinum","reports":3},"updated":"2026-10-01","recipes":[]},
          {"slug":"old-game","title":"Zebra Quest","description":"A quest with zebras.","genres":["rpg"],"graphics":["wined3d"],
           "summary":{"tier":null,"reports":0},"recipes":[]}
        ]
        """#
        return try! JSONDecoder().decode([IndexGame].self, from: Data(json.utf8))
    }()

    func titles(_ query: String = "", _ filter: CatalogueFilter = CatalogueFilter()) -> [String] {
        CatalogueBrowser.games(games, query: query, filter: filter).map(\.title)
    }

    func testFiltersByTextGenreGraphicsAndRating() {
        XCTAssertEqual(titles("guild"), ["Guild Wars 2"])
        XCTAssertEqual(titles("zebras"), ["Zebra Quest"], "Descriptions are searched")
        XCTAssertEqual(titles("arena guild"), ["Guild Wars 2"], "Every word must match")
        XCTAssertEqual(titles("arena puzzle"), [])
        XCTAssertEqual(titles("", CatalogueFilter(genre: "rpg")), ["Guild Wars 2", "Zebra Quest"])
        XCTAssertEqual(titles("", CatalogueFilter(graphics: "d3dmetal")), ["another Game"])
        XCTAssertEqual(titles("", CatalogueFilter(minimumTier: .gold)), ["another Game", "Guild Wars 2"])
        XCTAssertEqual(titles("", CatalogueFilter(minimumTier: .platinum)), ["another Game"])
        let facets = CatalogueBrowser.facets(games)
        XCTAssertEqual(facets.genres, ["mmo", "puzzle", "rpg"])
        XCTAssertEqual(facets.graphics, ["d3dmetal", "dxvk", "wined3d"])
    }

    func testSortsByTitleRatingAndNewestReport() {
        XCTAssertEqual(titles("", CatalogueFilter(sort: .title)), ["another Game", "Guild Wars 2", "Zebra Quest"])
        XCTAssertEqual(titles("", CatalogueFilter(sort: .rating)), ["another Game", "Guild Wars 2", "Zebra Quest"])
        XCTAssertEqual(titles("", CatalogueFilter(sort: .updated)), ["Guild Wars 2", "another Game", "Zebra Quest"])
    }

    func testNamesGenres() {
        XCTAssertEqual(CatalogueText.genre("mmo"), "MMO")
        XCTAssertEqual(CatalogueText.genre("action"), "Action")
        XCTAssertFalse(CatalogueFilter(sort: .rating).isNarrowing)
        XCTAssertTrue(CatalogueFilter(genre: "rpg").isNarrowing)
    }
}
