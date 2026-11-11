import Foundation
import XCTest
@testable import DistillerCore

/// Restore points: a bottle's copy from before it moved to a newer Wine.
final class RestorePointTests: XCTestCase {
    var root: URL!
    var engine: DistillerEngine!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-restore-\(UUID().uuidString)")
        engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func addWine(_ version: String) throws -> InstalledComponent {
        let manifest = ComponentManifest(
            id: "wine-staging", kind: .wine, version: version, displayName: "Wine Staging \(version)", arch: .x86_64,
            family: "winehq", source: "https://example.com/download"
        )
        let directory = engine.components.directory(for: manifest)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try engine.components.writeManifest(manifest, in: directory)
        return InstalledComponent(manifest: manifest, directory: directory)
    }

    /// A game whose bottle last ran with `wine`, with a prefix holding `marker`.
    func game(wine: String, marker: String = "before") throws -> Game {
        let bottle = Bottle(id: "game-\(UUID().uuidString.prefix(6))", name: "Example", wine: wine, createdAt: Date())
        let prefix = engine.bottles.prefix(of: bottle)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: prefix.appendingPathComponent("system.reg"))
        try engine.bottles.save(bottle)
        let recipe = Recipe(
            id: "example", game: GameInfo(title: "Example", slug: "example"),
            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d)
        )
        return Game(id: bottle.id, title: "Example", bottleID: bottle.id, recipe: recipe)
    }

    func marker(_ game: Game) throws -> String {
        let bottle = try engine.bottles.bottle(id: game.bottleID)
        return try String(contentsOf: engine.bottles.prefix(of: bottle).appendingPathComponent("system.reg"), encoding: .utf8)
    }

    func testAMoveIsPendingOnlyForANewerActiveWine() throws {
        try addWine("11.21")
        let current = try game(wine: "wine-staging@11.21")
        XCTAssertNil(try engine.pendingWineMove(for: current))
        try addWine("11.22")
        XCTAssertEqual(try engine.pendingWineMove(for: current)?.to.id, "wine-staging@11.22")
        XCTAssertEqual(try engine.pendingWineMove(for: current)?.from, "wine-staging@11.21")
        // A game that stays on its Wine never moves.
        var bottle = try engine.bottles.bottle(id: current.bottleID)
        bottle.stayOn = Bottle.StayOn(wine: "wine-staging@11.21")
        try engine.bottles.save(bottle)
        XCTAssertNil(try engine.pendingWineMove(for: current))
    }

    func testARestorePointIsACopyThatCanBePutBack() throws {
        let game = try game(wine: "wine-staging@11.21")
        let bottle = try engine.bottles.bottle(id: game.bottleID)
        let point = try engine.bottles.makeRestorePoint(of: bottle, from: "wine-staging@11.21", to: "wine-staging@11.22")
        XCTAssertEqual(engine.bottles.restorePoint(of: bottle), point)
        // The live bottle changes after the move...
        try Data("after".utf8).write(to: engine.bottles.prefix(of: bottle).appendingPathComponent("system.reg"))
        // ...and putting the copy back restores it.
        try engine.bottles.restorePrefix(of: bottle)
        XCTAssertEqual(try marker(game), "before")
        XCTAssertNil(engine.bottles.restorePoint(of: bottle))
    }

    func testRollingBackKeepsTheGameOnItsOldWine() async throws {
        try addWine("11.21")
        try addWine("11.22")
        let game = try game(wine: "wine-staging@11.22")
        var bottle = try engine.bottles.bottle(id: game.bottleID)
        _ = try engine.bottles.makeRestorePoint(of: bottle, from: "wine-staging@11.21", to: "wine-staging@11.22")
        try Data("after".utf8).write(to: engine.bottles.prefix(of: bottle).appendingPathComponent("system.reg"))

        try await engine.rollBack(game)
        bottle = try engine.bottles.bottle(id: game.bottleID)
        XCTAssertEqual(try marker(game), "before")
        XCTAssertEqual(bottle.wine, "wine-staging@11.21")
        XCTAssertEqual(bottle.stayOn?.wine, "wine-staging@11.21", "it stays there until the player follows updates again")
        XCTAssertNil(try engine.pendingWineMove(for: game))
    }

    func testRollingBackNeedsTheOldWine() async throws {
        try addWine("11.22")
        let game = try game(wine: "wine-staging@11.22")
        let bottle = try engine.bottles.bottle(id: game.bottleID)
        _ = try engine.bottles.makeRestorePoint(of: bottle, from: "wine-staging@11.21", to: "wine-staging@11.22")
        do {
            try await engine.rollBack(game)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("11.21"), error.localizedDescription)
        }
        XCTAssertNotNil(engine.bottles.restorePoint(of: bottle), "nothing changed")
    }

    func testTheOldWineStaysWhileARestorePointNeedsIt() throws {
        try addWine("11.21")
        try addWine("11.22")
        let game = try game(wine: "wine-staging@11.22")
        let bottle = try engine.bottles.bottle(id: game.bottleID)
        XCTAssertEqual(engine.unusedComponents().map(\.id), ["wine-staging@11.21"])
        _ = try engine.bottles.makeRestorePoint(of: bottle, from: "wine-staging@11.21", to: "wine-staging@11.22")
        XCTAssertEqual(engine.unusedComponents(), [])
    }

    func testConfirmingDiscardsUnlessKeptUntilRemoved() throws {
        let game = try game(wine: "wine-staging@11.22")
        let bottle = try engine.bottles.bottle(id: game.bottleID)
        _ = try engine.bottles.makeRestorePoint(of: bottle, from: "wine-staging@11.21", to: "wine-staging@11.22")
        try engine.confirmWineMove(game)
        XCTAssertNil(engine.bottles.restorePoint(of: bottle))

        var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        settings.restorePointDays = RestorePointRetention.untilRemoved
        try settings.save(toSupportFolder: engine.paths.root)
        _ = try engine.bottles.makeRestorePoint(of: bottle, from: "wine-staging@11.21", to: "wine-staging@11.22")
        try engine.confirmWineMove(game)
        XCTAssertNotNil(engine.bottles.restorePoint(of: bottle)?.confirmedAt)
    }

    func testRestorePointsExpireAfterTheChosenDays() throws {
        let game = try game(wine: "wine-staging@11.22")
        let bottle = try engine.bottles.bottle(id: game.bottleID)
        let created = Date()
        _ = try engine.bottles.makeRestorePoint(of: bottle, from: "wine-staging@11.21", to: "wine-staging@11.22", now: created)
        // Default: 7 days.
        XCTAssertEqual(engine.expireRestorePoints(now: created.addingTimeInterval(6 * 24 * 3600)), 0)
        XCTAssertEqual(engine.expireRestorePoints(now: created.addingTimeInterval(8 * 24 * 3600)), 1)
        XCTAssertNil(engine.bottles.restorePoint(of: bottle))

        // "Until I confirm" and "until I remove it" never expire.
        for days in [RestorePointRetention.untilConfirmed, RestorePointRetention.untilRemoved] {
            var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
            settings.restorePointDays = days
            try settings.save(toSupportFolder: engine.paths.root)
            _ = try engine.bottles.makeRestorePoint(of: bottle, from: "wine-staging@11.21", to: "wine-staging@11.22", now: created)
            XCTAssertEqual(engine.expireRestorePoints(now: created.addingTimeInterval(365 * 24 * 3600)), 0)
        }
    }

    func testAskingOnce() throws {
        let game = try game(wine: "wine-staging@11.22")
        let bottle = try engine.bottles.bottle(id: game.bottleID)
        _ = try engine.bottles.makeRestorePoint(of: bottle, from: "wine-staging@11.21", to: "wine-staging@11.22")
        XCTAssertNil(engine.bottles.restorePoint(of: bottle)?.askedAt)
        engine.markRestorePointAsked(game)
        XCTAssertNotNil(engine.bottles.restorePoint(of: bottle)?.askedAt)
    }

    func testDescribesWineBuilds() {
        XCTAssertEqual(RestorePoint.describe("wine-staging@11.21"), "Wine Staging 11.21")
        XCTAssertEqual(RestorePointRetention.describe(7), "Up to 7 days")
        XCTAssertEqual(RestorePointRetention.describe(RestorePointRetention.untilConfirmed), "Until I confirm the game works")
    }
}
