import Foundation
import XCTest
@testable import DistillerCore

final class InGameScreenshotTests: XCTestCase {
    var work: URL!
    var engine: DistillerEngine!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-ingame-\(UUID().uuidString)", isDirectory: true)
        engine = try DistillerEngine(paths: DistillerPaths(root: work.appendingPathComponent("home"), storage: StorageSettings()), hardware: Macs.m3Pro)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    @discardableResult
    func write(_ url: URL, bytes: Int = 20_000, modified: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    func makeCheckBottle(owner: String? = nil) throws -> Bottle {
        let bottle = Bottle(id: "real-game-check-\(UUID().uuidString.prefix(6).lowercased())", name: "Real Game" + DistillerEngine.communityCheckBottleSuffix,
                            wine: "wine@11", createdAt: Date().addingTimeInterval(-600))
        try FileManager.default.createDirectory(at: engine.bottles.prefix(of: bottle).appendingPathComponent("drive_c/users/player"), withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        if let owner {
            try owner.write(to: engine.bottles.root(of: bottle).appendingPathComponent(DistillerEngine.communityCheckOwnerFile), atomically: true, encoding: .utf8)
        }
        return bottle
    }

    func testFindsScreenshotsTheGameSavedDuringTheRun() throws {
        let prefix = work.appendingPathComponent("prefix")
        let screens = prefix.appendingPathComponent("drive_c/users/player/Documents/Guild Wars 2/Screens")
        let start = Date().addingTimeInterval(-60)
        let first = try write(screens.appendingPathComponent("gw001.jpg"), modified: start.addingTimeInterval(10))
        let second = try write(screens.appendingPathComponent("gw002.JPG"), modified: start.addingTimeInterval(20))
        try write(screens.appendingPathComponent("old.jpg"), modified: start.addingTimeInterval(-3600))     // before the run
        try write(screens.appendingPathComponent("tiny.png"), bytes: 100)                                   // a thumbnail or icon
        try write(screens.appendingPathComponent("notes.txt"))
        let program = prefix.appendingPathComponent("drive_c/Program Files/Real Game")
        let inGameFolder = try write(program.appendingPathComponent("screenshots/shot.bmp"), modified: start.addingTimeInterval(15))
        // A folder linked to the Mac isn't searched.
        let outside = work.appendingPathComponent("outside")
        try write(outside.appendingPathComponent("private.jpg"))
        try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("drive_c/users/player/Linked"), withDestinationURL: outside)

        let found = InGameScreenshots.find(inPrefix: prefix, programFolder: program, since: start)
        XCTAssertEqual(found.map(\.lastPathComponent), [first, inGameFolder, second].map(\.lastPathComponent), "Oldest first, from the user folders and the game's folder")
        XCTAssertEqual(InGameScreenshots.find(inPrefix: prefix, since: start, limit: 1).count, 1)
    }

    func testOrphanedCheckBottles() throws {
        let orphan = try makeCheckBottle()
        try makeCheckBottle(owner: String(ProcessInfo.processInfo.processIdentifier))   // a check running now
        try makeCheckBottle(owner: "kept")                                             // kept on purpose
        let dead = try makeCheckBottle(owner: "99999999")                             // its process is gone
        let ordinary = Bottle(id: "real-game-1", name: "Real Game", wine: "wine@11", createdAt: Date())
        try FileManager.default.createDirectory(at: engine.bottles.root(of: ordinary), withIntermediateDirectories: true)
        try engine.bottles.save(ordinary)
        XCTAssertEqual(Set(engine.orphanedCommunityCheckBottles().map(\.id)), [orphan.id, dead.id])
        XCTAssertThrowsError(try engine.removeOrphanedCommunityCheckBottle(ordinary), "Only check bottles")
    }

    func testRemovingAnOrphanRescuesItsScreenshotsFirst() throws {
        let bottle = try makeCheckBottle()
        let screens = engine.bottles.prefix(of: bottle).appendingPathComponent("drive_c/users/player/Documents/Guild Wars 2/Screens")
        try write(screens.appendingPathComponent("gw001.jpg"))
        let destination = work.appendingPathComponent("Pictures/Real Game")
        try write(destination.appendingPathComponent("gw001.jpg"))   // already there: not overwritten

        let copies = try engine.removeOrphanedCommunityCheckBottle(bottle, rescuingScreenshotsTo: destination)
        XCTAssertEqual(copies.map(\.lastPathComponent), ["gw001-2.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("gw001-2.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.bottles.root(of: bottle).path), "The bottle is gone")
        XCTAssertEqual(engine.orphanedCommunityCheckBottles(), [])
    }
}
