import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DistillerCore

/// Builds a PE file whose resources hold one icon group with the given PNG images, laid out
/// the way linkers do: type directory → ID directory → language directory → data entry.
enum TestIconPE {
    static func make(images: [Data], groupID: UInt32 = 1) -> Data {
        var data = TestPE.make(imports: ["KERNEL32.dll"])
        // A second section, .rsrc, at RVA 0x2000 / file offset 0x400.
        let sectionTable = 0x84 + 20 + 240
        func put16(_ value: UInt16, _ offset: Int) { withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + 2, with: $0) } }
        func put32(_ value: UInt32, _ offset: Int) { withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + 4, with: $0) } }

        var rsrc = Data()
        func at(_ offset: Int, _ bytes: Data) {
            if rsrc.count < offset + bytes.count { rsrc.append(Data(count: offset + bytes.count - rsrc.count)) }
            rsrc.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func directory(_ offset: Int, _ entries: [(id: UInt32, target: UInt32, isDirectory: Bool)]) {
            at(offset, Data(count: 12) + le16(0) + le16(UInt16(entries.count)))
            for (index, entry) in entries.enumerated() {
                at(offset + 16 + index * 8, le32(entry.id) + le32(entry.target | (entry.isDirectory ? 0x8000_0000 : 0)))
            }
        }
        let rva: UInt32 = 0x2000
        // Fixed layout: root 0x0, type directories 0x40 and 0x80, then each resource's language
        // directory (icons from 0x100, the group at 0x200), data entries from 0x500, payloads from 0x800.
        let iconIDs = images.indices.map { UInt32($0 + 1) }
        directory(0x0, [(3, 0x40, true), (14, 0x80, true)])
        directory(0x40, iconIDs.enumerated().map { ($1, UInt32(0x100 + $0 * 0x20), true) })
        directory(0x80, [(groupID, 0x200, true)])
        var payload = 0x800
        var dataEntry = 0x500
        func addData(_ bytes: Data, languageDirectory: Int) {
            directory(languageDirectory, [(1033, UInt32(dataEntry), false)])
            at(dataEntry, le32(rva + UInt32(payload)) + le32(UInt32(bytes.count)) + Data(count: 8))
            at(payload, bytes)
            dataEntry += 16
            payload += (bytes.count + 15) / 16 * 16
        }
        for (index, image) in images.enumerated() {
            addData(image, languageDirectory: 0x100 + index * 0x20)
        }
        var group = le16(0) + le16(1) + le16(UInt16(images.count))
        for (index, image) in images.enumerated() {
            let size = pixelWidth(image)
            group += Data([UInt8(size >= 256 ? 0 : size), UInt8(size >= 256 ? 0 : size), 0, 0]) + le16(1) + le16(32)
                + le32(UInt32(image.count)) + le16(UInt16(index + 1))
        }
        addData(group, languageDirectory: 0x200)

        put16(2, 0x84 + 2)
        data.replaceSubrange(sectionTable + 40..<sectionTable + 45, with: Array(".rsrc".utf8))
        put32(UInt32(rsrc.count), sectionTable + 40 + 8)
        put32(rva, sectionTable + 40 + 12)
        put32(UInt32(rsrc.count), sectionTable + 40 + 16)
        put32(0x400, sectionTable + 40 + 20)
        let directories = 0x84 + 20 + 112
        put32(rva, directories + 2 * 8)
        put32(UInt32(rsrc.count), directories + 2 * 8 + 4)
        return data.prefix(0x400) + rsrc
    }

    static func png(size: Int, red: CGFloat) -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func pixelWidth(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        return properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    }
}

final class IconTests: XCTestCase {
    func testExtractsLargestIconFromExecutable() throws {
        let exe = TestIconPE.make(images: [TestIconPE.png(size: 32, red: 1), TestIconPE.png(size: 256, red: 0.5), TestIconPE.png(size: 48, red: 0)])
        XCTAssertNotNil(PEFile.parse(exe), "Still a valid program for the inspector")

        let ico = try XCTUnwrap(PEIcon.ico(fromExecutableData: exe))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(ico as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3, "Every size is kept in the .ico")

        let png = try XCTUnwrap(PEIcon.png(fromImageData: ico))
        XCTAssertEqual(TestIconPE.pixelWidth(png), 256)
    }

    func testProgramsWithoutIconsAndDamagedFiles() {
        XCTAssertNil(PEIcon.ico(fromExecutableData: TestPE.make(imports: ["KERNEL32.dll"])))
        XCTAssertNil(PEIcon.ico(fromExecutableData: Data("not a program".utf8)))
        let exe = TestIconPE.make(images: [TestIconPE.png(size: 32, red: 1)])
        for cut in stride(from: 0x400, to: exe.count, by: 97) {
            _ = PEIcon.ico(fromExecutableData: exe.prefix(cut))   // must not crash
        }
        XCTAssertNil(PEIcon.png(fromImageData: Data("not an image".utf8)))
    }
}

final class GameLibraryStateTests: XCTestCase {
    private var work: URL!
    private var engine: DistillerEngine!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-library-\(UUID().uuidString)", isDirectory: true)
        engine = try DistillerEngine(paths: DistillerPaths(root: work, storage: StorageSettings()), hardware: Macs.m3Pro)
        try installFakeWine(into: engine, id: "wine", version: "11")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    /// A game whose folder is linked from `folder`, launching Game.exe.
    private func makeGame(linkingTo folder: URL) throws -> Game {
        var draft = RecipeDraft(source: .folder(folder), title: "Example")
        draft.launchProgram = "Game.exe"
        let bottle = Bottle(id: "example-1", name: "Example", wine: "wine@11", createdAt: Date())
        try FileManager.default.createDirectory(at: engine.bottles.prefix(of: bottle).appendingPathComponent("drive_c/Games"), withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        let game = Game(id: bottle.id, title: "Example", bottleID: bottle.id, recipe: draft.makeRecipe())
        let link = try engine.userFolderLocation(of: game).url
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        return game
    }

    func testAvailabilityFollowsTheGameFolder() throws {
        let folder = work.appendingPathComponent("Game Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let game = try makeGame(linkingTo: folder)

        XCTAssertNotNil(engine.availability(of: game).reason, "No Game.exe yet")
        try TestIconPE.make(images: [TestIconPE.png(size: 64, red: 1)]).write(to: folder.appendingPathComponent("Game.exe"))
        XCTAssertEqual(engine.availability(of: game), .ready)

        try FileManager.default.moveItem(at: folder, to: work.appendingPathComponent("Moved"))
        let reason = try XCTUnwrap(engine.availability(of: game).reason)
        XCTAssertTrue(reason.contains("can't be found"), reason)
        XCTAssertThrowsError(try engine.launch(game))
    }

    func testDisconnectedDriveIsNamed() throws {
        let drive = "distiller-missing-\(UUID().uuidString.prefix(8))"
        let game = try makeGame(linkingTo: URL(fileURLWithPath: "/Volumes/\(drive)/GW2"))
        XCTAssertEqual(engine.availability(of: game), .unavailable("It's on “\(drive)”, which isn't connected. Connect the drive to play."))
    }

    func testNoWineIsReportedAfterTheGameFolder() throws {
        let bare = try DistillerEngine(paths: DistillerPaths(root: work.appendingPathComponent("bare"), storage: StorageSettings()), hardware: Macs.m3Pro)
        let folder = work.appendingPathComponent("Bare Game", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestIconPE.make(images: [TestIconPE.png(size: 32, red: 1)]).write(to: folder.appendingPathComponent("Game.exe"))
        var draft = RecipeDraft(source: .folder(folder), title: "Bare")
        draft.launchProgram = "Game.exe"
        let bottle = Bottle(id: "bare-1", name: "Bare", wine: "wine@11", createdAt: Date())
        try FileManager.default.createDirectory(at: bare.bottles.prefix(of: bottle).appendingPathComponent("drive_c/Games"), withIntermediateDirectories: true)
        try bare.bottles.save(bottle)
        let game = Game(id: bottle.id, title: "Bare", bottleID: bottle.id, recipe: draft.makeRecipe())
        try FileManager.default.createSymbolicLink(at: try bare.userFolderLocation(of: game).url, withDestinationURL: folder)

        XCTAssertEqual(bare.availability(of: game), .unavailable("No installed component provides a Wine build. Add one in Components."))
        XCTAssertNotNil(bare.refreshIcon(for: game), "Icons need only the program, not a Wine build")
    }

    func testNoLaunchProgramNeedsSetup() throws {
        let bottle = Bottle(id: "manual-1", name: "Manual", wine: "wine@11", createdAt: Date())
        try FileManager.default.createDirectory(at: engine.bottles.root(of: bottle), withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        let game = Game(id: bottle.id, title: "Manual", bottleID: bottle.id, recipe: RecipeDraft(source: .manual, title: "Manual").makeRecipe())
        XCTAssertEqual(engine.availability(of: game), .needsSetup)
    }

    func testIconIsReadFromProgramAndKeptWhenItGoesAway() throws {
        let folder = work.appendingPathComponent("Game Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestIconPE.make(images: [TestIconPE.png(size: 128, red: 1)]).write(to: folder.appendingPathComponent("Game.exe"))
        let game = try makeGame(linkingTo: folder)

        XCTAssertNil(engine.iconURL(for: game))
        let icon = try XCTUnwrap(engine.refreshIcon(for: game))
        XCTAssertEqual(TestIconPE.pixelWidth(try Data(contentsOf: icon)), 128)
        XCTAssertTrue(icon.path.hasPrefix(engine.paths.root.path), "Icons stay in the support folder")

        try FileManager.default.removeItem(at: folder)
        XCTAssertNil(engine.refreshIcon(for: game))
        XCTAssertEqual(engine.iconURL(for: game), icon, "The saved icon still shows")
    }

    func testCustomIconWinsAndCanBeRemoved() throws {
        let folder = work.appendingPathComponent("Game Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestIconPE.make(images: [TestIconPE.png(size: 128, red: 1)]).write(to: folder.appendingPathComponent("Game.exe"))
        let game = try makeGame(linkingTo: folder)
        let extracted = try XCTUnwrap(engine.refreshIcon(for: game))

        let picture = work.appendingPathComponent("cover.png")
        try TestIconPE.png(size: 512, red: 0).write(to: picture)
        try engine.setCustomIcon(for: game, from: picture)
        XCTAssertTrue(engine.hasCustomIcon(game))
        XCTAssertEqual(TestIconPE.pixelWidth(try Data(contentsOf: try XCTUnwrap(engine.iconURL(for: game)))), 512)

        // Another program's icon works too.
        try engine.setCustomIcon(for: game, from: folder.appendingPathComponent("Game.exe"))
        XCTAssertEqual(TestIconPE.pixelWidth(try Data(contentsOf: try XCTUnwrap(engine.iconURL(for: game)))), 128)

        try engine.removeCustomIcon(for: game)
        XCTAssertEqual(engine.iconURL(for: game), extracted)
        XCTAssertThrowsError(try engine.setCustomIcon(for: game, from: work.appendingPathComponent("missing.png")))
    }
}
