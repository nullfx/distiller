import XCTest
@testable import DistillerCore

final class APFSCloneTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-clone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testReplacingAFileWithItselfKeepsIt() throws {
        // An installer picked from the bottle's own cache folder, which is also where it goes.
        let file = folder.appendingPathComponent("cache/Setup.exe")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("installer".utf8).write(to: file)
        try APFSClone.replaceItem(at: file, withCloneOf: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("installer".utf8))
        // The same file by another path.
        let other = folder.appendingPathComponent("cache/../cache/./Setup.exe")
        try APFSClone.replaceItem(at: file, withCloneOf: other)
        XCTAssertEqual(try Data(contentsOf: file), Data("installer".utf8))
    }

    func testReplacingAnotherFileReplacesIt() throws {
        let source = folder.appendingPathComponent("new.exe")
        let destination = folder.appendingPathComponent("old.exe")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        try APFSClone.replaceItem(at: destination, withCloneOf: source)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("new".utf8))
    }
}
