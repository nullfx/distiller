import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DistillerCore

final class CommunityMediaTests: XCTestCase {
    /// A solid image, half transparent when `alpha` is below 1, encoded as `type`.
    static func image(width: Int, height: Int, alpha: CGFloat = 1, as type: UTType = .png) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.1, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func properties(_ data: Data) -> (type: String, width: Int, height: Int, alpha: Bool) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        return (CGImageSourceGetType(source)! as String, image.width, image.height, alpha)
    }

    func testIconIsASquarePNGOfAtMost256Pixels() throws {
        let big = try XCTUnwrap(CommunityMedia.icon(from: Self.image(width: 512, height: 512)))
        let info = Self.properties(big)
        XCTAssertEqual(info.type, UTType.png.identifier)
        XCTAssertEqual(info.width, 256)
        XCTAssertEqual(info.height, 256)
        XCTAssertEqual(Self.properties(try XCTUnwrap(CommunityMedia.icon(from: Self.image(width: 48, height: 48)))).width, 48, "Small icons aren't enlarged")
        XCTAssertNil(CommunityMedia.icon(from: Self.image(width: 16, height: 16)), "Too small to show")
        XCTAssertNil(CommunityMedia.icon(from: Self.image(width: 300, height: 200)), "Not square")
        XCTAssertNil(CommunityMedia.icon(from: Data("not an image".utf8)))
    }

    func testScreenshotIsAnOpaqueJPEGOfAtMost1600Wide() throws {
        let shot = try XCTUnwrap(CommunityMedia.screenshot(from: Self.image(width: 3024, height: 1890, alpha: 0.5)))
        let info = Self.properties(shot)
        XCTAssertEqual(info.type, UTType.jpeg.identifier)
        XCTAssertEqual(info.width, 1600)
        XCTAssertEqual(info.height, 1000)
        XCTAssertFalse(info.alpha)
        XCTAssertLessThanOrEqual(shot.count, CommunityMedia.screenshotMaxBytes)
        XCTAssertEqual(Self.properties(try XCTUnwrap(CommunityMedia.screenshot(from: Self.image(width: 800, height: 600)))).width, 800)
        XCTAssertNil(CommunityMedia.screenshot(from: Self.image(width: 200, height: 150)), "Too small")
    }

    func testChoosingCapturesToShare() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
        let recipe = RecipeDraft(source: .manual, title: "Real Game").makeRecipe()
        let names = (1...5).map(CommunityMedia.captureFile)
        var game = Game(id: "real-game-1", title: "Real Game", bottleID: "real-game-1", recipe: recipe, authored: true)
        game.communityCheck = CommunityCheckResult(
            checkedAt: Date(), recipe: recipe, sourceFingerprint: CommunityCheck.fingerprint(recipe), installerSHA256: "", hardwareKey: "",
            wine: "wine", graphics: nil, captures: names, sharedCaptures: Array(names.prefix(3))
        )
        try engine.library.upsert(game)
        let folder = engine.paths.communityMedia.appendingPathComponent(game.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names.dropLast() { try Data([1]).write(to: folder.appendingPathComponent(name)) }

        XCTAssertEqual(engine.communityCheckCaptures(for: game).map(\.name), Array(names.prefix(4)), "Missing files are skipped")
        XCTAssertEqual(engine.sharedCommunityScreenshots(for: game).map(\.lastPathComponent), ["capture-1.jpg", "capture-2.jpg", "capture-3.jpg"])

        let updated = try engine.setSharedScreenshots(["capture-4.jpg", "nope.jpg", "capture-1.jpg", "capture-4.jpg", "capture-2.jpg", "capture-3.jpg"], for: game)
        XCTAssertEqual(updated.communityCheck?.sharedCaptures, ["capture-4.jpg", "capture-1.jpg", "capture-2.jpg"], "Known names only, no repeats, at most three, in order")
        XCTAssertEqual(try engine.library.game(id: game.id).communityCheck?.sharedCaptures?.first, "capture-4.jpg", "Saved; the first is the cover")

        engine.removeIcons(for: updated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Removed with the game")
    }
}
