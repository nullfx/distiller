import Foundation
import XCTest
@testable import DistillerCore

/// A game follows the active version of each component, or stays on one the player chose.
final class GameVersionTests: XCTestCase {
    var root: URL!
    var engine: DistillerEngine!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-versions-\(UUID().uuidString)")
        engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func add(_ id: String, _ version: String, kind: ComponentKind, provides: GraphicsBackend? = nil) throws -> InstalledComponent {
        let manifest = ComponentManifest(
            id: id, kind: kind, version: version, displayName: "\(id) \(version)", arch: .x86_64,
            family: kind == .wine ? "winehq" : nil, provides: provides, placement: provides == nil ? nil : .prefixDLLs,
            source: "https://example.com/download"
        )
        let directory = engine.components.directory(for: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try engine.components.writeManifest(manifest, in: directory)
        return InstalledComponent(manifest: manifest, directory: directory)
    }

    /// A game in a bottle that last ran with `wine`.
    func game(wine: String, graphics: GraphicsBackend = .dxvk) throws -> Game {
        let bottle = Bottle(id: "game-\(UUID().uuidString.prefix(6))", name: "Example", wine: wine, createdAt: Date())
        try FileManager.default.createDirectory(at: engine.bottles.root(of: bottle), withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        let recipe = Recipe(
            id: "example",
            game: GameInfo(title: "Example", slug: "example"),
            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: graphics)
        )
        return Game(id: bottle.id, title: "Example", bottleID: bottle.id, recipe: recipe)
    }

    func testFollowingUsesTheActiveVersions() throws {
        try add("wine-staging", "11.20", kind: .wine)
        let newWine = try add("wine-staging", "11.21", kind: .wine)
        try add("dxvk-macos", "1.10.2", kind: .graphics, provides: .dxvk)
        let newLayer = try add("dxvk-macos", "1.10.3", kind: .graphics, provides: .dxvk)
        let game = try game(wine: "wine-staging@11.20")
        let versions = try engine.versions(for: game)
        XCTAssertNil(versions.wine.stayOn)
        XCTAssertEqual(versions.wine.current?.id, newWine.id)
        XCTAssertEqual(versions.graphics?.current?.id, newLayer.id)
        XCTAssertEqual(versions.wine.options.map(\.id), ["wine-staging@11.21", "wine-staging@11.20"])
    }

    func testStayingOnAVersionKeepsTheGameThere() throws {
        let oldWine = try add("wine-staging", "11.20", kind: .wine)
        try add("wine-staging", "11.21", kind: .wine)
        let oldLayer = try add("dxvk-macos", "1.10.2", kind: .graphics, provides: .dxvk)
        try add("dxvk-macos", "1.10.3", kind: .graphics, provides: .dxvk)
        let oldTricks = try add("winetricks", "20250102", kind: .winetricks)
        try add("winetricks", "20260125", kind: .winetricks)
        let game = try game(wine: "wine-staging@11.20")

        try engine.setStayOn(.wine, oldWine, for: game)
        try engine.setStayOn(.graphics, oldLayer, for: game)
        try engine.setStayOn(.winetricks, oldTricks, for: game)
        let bottle = try engine.bottles.bottle(id: game.bottleID)
        XCTAssertEqual(bottle.stayOn, Bottle.StayOn(wine: oldWine.id, graphics: oldLayer.id, winetricks: oldTricks.id))

        let resolved = engine.resolve(game.recipe, overrides: nil)
        XCTAssertEqual(try engine.chooseWine(for: resolved, bottle: bottle).id, oldWine.id)
        XCTAssertEqual(try engine.graphicsLayer(.dxvk, for: bottle).id, oldLayer.id)
        let installer = RecipeInstaller(runner: engine.runner, bottles: engine.bottles, components: engine.components)
        XCTAssertEqual(try installer.winetricks(for: bottle).id, oldTricks.id)
        XCTAssertEqual(try engine.bottles.bottle(id: game.bottleID).winetricks, oldTricks.id, "the bottle records what it used")

        // Kept versions are never cleaned up while a game stays on them.
        XCTAssertEqual(engine.unusedComponents(), [])

        // Following again uses the active versions, and the old ones become removable.
        try engine.setStayOn(.wine, nil, for: game)
        try engine.setStayOn(.graphics, nil, for: game)
        try engine.setStayOn(.winetricks, nil, for: game)
        XCTAssertNil(try engine.bottles.bottle(id: game.bottleID).stayOn)
        XCTAssertEqual(Set(engine.unusedComponents().map(\.id)), [oldWine.id, oldLayer.id, oldTricks.id])
    }

    func testWineCantStayOnABuildOlderThanTheBottleHasRunWith() throws {
        let oldWine = try add("wine-staging", "11.20", kind: .wine)
        try add("wine-staging", "11.21", kind: .wine)
        let game = try game(wine: "wine-staging@11.21")
        XCTAssertThrowsError(try engine.setStayOn(.wine, oldWine, for: game))
        XCTAssertEqual(try engine.versions(for: game).wine.options.map(\.id), ["wine-staging@11.21"])
    }

    func testAMissingKeptVersionSaysWhatToDo() throws {
        try add("wine-staging", "11.21", kind: .wine)
        var bottle = Bottle(id: "kept", name: "Example", wine: "wine-staging@11.20", createdAt: Date())
        bottle.stayOn = Bottle.StayOn(wine: "wine-staging@11.20")
        let resolved = engine.resolve(try game(wine: "wine-staging@11.20").recipe, overrides: nil)
        XCTAssertThrowsError(try engine.chooseWine(for: resolved, bottle: bottle)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Follow Updates"), error.localizedDescription)
        }
    }

    func testAKeptLayerForAnotherBackendDoesntApply() throws {
        let dxvk = try add("dxvk-macos", "1.10.2", kind: .graphics, provides: .dxvk)
        let dxmt = try add("dxmt", "0.80", kind: .graphics, provides: .dxmt)
        var bottle = Bottle(id: "b", name: "Example", wine: "wine-staging@11.21", createdAt: Date())
        bottle.stayOn = Bottle.StayOn(graphics: dxvk.id)
        // The game now uses DXMT (an override, say): the DXVK choice doesn't get in the way.
        XCTAssertEqual(try engine.graphicsLayer(.dxmt, for: bottle).id, dxmt.id)
    }

    func testOlderBottleFilesStillRead() throws {
        let json = #"{"id":"old","name":"Old","wine":"wine-staging@11.20","created_at":0}"#
        let bottle = try JSONDecoder().decode(Bottle.self, from: Data(json.utf8))
        XCTAssertNil(bottle.stayOn)
        XCTAssertNil(bottle.graphics)
        var updated = bottle
        updated.stayOn = Bottle.StayOn(wine: "wine-staging@11.20")
        let text = String(decoding: try JSONEncoder().encode(updated), as: UTF8.self)
        XCTAssertTrue(text.contains(#""stay_on""#), text)
    }
}
