import Foundation
import XCTest
@testable import DistillerCore

/// Rebuilding a game's bottle: what's reused from the old bottle, and keeping or switching back.
final class RebuildTests: XCTestCase {
    var root: URL!
    var engine: DistillerEngine!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-rebuild-\(UUID().uuidString)")
        engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
        engine.bottles.deletesToTrash = false
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func makeBottle(_ id: String) throws -> Bottle {
        let bottle = Bottle(id: id, name: "Example", wine: "wine-staging@11.21", createdAt: Date())
        try FileManager.default.createDirectory(at: engine.bottles.prefix(of: bottle).appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        return bottle
    }

    func testReusesWhatTheOldBottleHas() throws {
        let bottle = try makeBottle("old")
        let root = engine.bottles.root(of: bottle)
        // A folder used in place from another drive (a link), a copied folder, and a chosen file.
        let elsewhere = self.root.appendingPathComponent("OtherDrive/Game", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let linked = try BottlePath.resolve(#"C:\Games\Linked"#, in: root)
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
        let copied = try BottlePath.resolve(#"C:\Games\Copied"#, in: root)
        try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
        let file = try BottlePath.resolve("cache/Setup.exe", in: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("setup".utf8).write(to: file)

        let recipe = Recipe(
            id: "example", game: GameInfo(title: "Example", slug: "example"),
            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d),
            install: [
                .userFolder(.init(id: "linked", prompt: "Choose the game", to: #"C:\Games\Linked"#)),
                .userFolder(.init(id: "copied", prompt: "Choose the game", to: #"C:\Games\Copied"#)),
                .userFile(.init(id: "installer", prompt: "Choose the installer", to: "cache/Setup.exe")),
                .userFile(.init(id: "missing", prompt: "Choose the patch", to: "cache/Patch.exe")),
            ]
        )
        let game = Game(id: "g", title: "Example", bottleID: bottle.id, recipe: recipe)
        let items = try engine.rebuildItems(for: game)
        XCTAssertEqual(items.folders["linked"], UserFolderSource(url: elsewhere.followingSymlinks, linkInPlace: true))
        XCTAssertEqual(items.folders["copied"]?.linkInPlace, false)
        XCTAssertEqual(items.files["installer"]?.lastPathComponent, "Setup.exe")
        XCTAssertNil(items.files["missing"], "what the old bottle doesn't have is asked for again")
    }

    func testKeepingTheRebuildRemovesTheOldBottle() throws {
        let old = try makeBottle("old")
        let fresh = try makeBottle("fresh")
        var game = Game(id: "g", title: "Example", bottleID: fresh.id, recipe: Recipe(
            id: "example", game: GameInfo(title: "Example", slug: "example"),
            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d)
        ))
        game.rebuild = Game.Rebuild(previousBottleID: old.id, rebuiltAt: Date())
        try engine.library.upsert(game)

        engine.markRebuildAsked(game)
        XCTAssertNotNil(try engine.library.game(id: "g").rebuild?.askedAt)

        try engine.keepRebuild(game)
        XCTAssertNil(try engine.library.game(id: "g").rebuild)
        XCTAssertEqual(try engine.library.game(id: "g").bottleID, fresh.id)
        XCTAssertThrowsError(try engine.bottles.bottle(id: old.id), "the old bottle went to the Trash")
    }

    func testSwitchingBackRemovesTheNewBottle() throws {
        let old = try makeBottle("old")
        let fresh = try makeBottle("fresh")
        var game = Game(id: "g", title: "Example", bottleID: fresh.id, recipe: Recipe(
            id: "example", game: GameInfo(title: "Example", slug: "example"),
            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d)
        ))
        game.rebuild = Game.Rebuild(previousBottleID: old.id, rebuiltAt: Date())
        try engine.library.upsert(game)

        let back = try engine.switchBack(game)
        XCTAssertEqual(back.bottleID, old.id)
        XCTAssertNil(back.rebuild)
        XCTAssertEqual(try engine.library.game(id: "g").bottleID, old.id)
        XCTAssertThrowsError(try engine.bottles.bottle(id: fresh.id))
        XCTAssertNoThrow(try engine.bottles.bottle(id: old.id))
    }

    func testAGameAlreadyRebuiltMustBeDecidedFirst() async throws {
        let old = try makeBottle("old")
        var game = Game(id: "g", title: "Example", bottleID: old.id, recipe: Recipe(
            id: "example", game: GameInfo(title: "Example", slug: "example"),
            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d)
        ))
        game.rebuild = Game.Rebuild(previousBottleID: "older", rebuiltAt: Date())
        do {
            _ = try await engine.rebuild(game, supplied: UserSupplied())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("switch back"), error.localizedDescription)
        }
    }

    func testOlderLibraryFilesStillRead() throws {
        let json = #"{"id":"g","title":"T","bottle_id":"b","recipe":{"schema":1,"id":"r","game":{"title":"T","slug":"t"},"stack":{"runner":{"family":"any"},"graphics":"wined3d"}},"added_at":0,"seconds_played":0}"#
        let game = try JSONDecoder().decode(Game.self, from: Data(json.utf8))
        XCTAssertNil(game.rebuild)
    }
}
