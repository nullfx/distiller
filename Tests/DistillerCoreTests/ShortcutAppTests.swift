import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DistillerCore

/// A game's shortcut app: a Mac app with the game's icon that starts it through Distiller.
final class ShortcutAppTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A 256-pixel PNG, like the icons Distiller extracts.
    func iconPNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 32, y: 32, width: 192, height: 192))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testMakesAnIconFileAtEverySize() throws {
        let icns = try XCTUnwrap(ICNS.make(fromImage: try iconPNG()))
        let entries = try XCTUnwrap(ICNS.read(icns))
        XCTAssertEqual(entries.map(\.type), ["icp4", "icp5", "icp6", "ic07", "ic08", "ic09", "ic10"])
        for (entry, size) in zip(entries, [16, 32, 64, 128, 256, 512, 1024]) {
            let image = try XCTUnwrap(CGImageSourceCreateWithData(entry.png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual(image.width, size, entry.type)
            XCTAssertEqual(image.height, size, entry.type)
        }
        XCTAssertNil(ICNS.make(fromImage: Data("not an image".utf8)))
    }

    func testMakesASignedShortcutApp() async throws {
        // A stand-in for the DistillerShortcut program.
        let program = root.appendingPathComponent(ShortcutApp.programName)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: program)
        let app = root.appendingPathComponent("Guild Wars 2.app")
        try await ShortcutApp.create(gameID: "guild-wars-2-f484a9", title: "Guild Wars 2", icon: try iconPNG(), program: program, at: app)

        let info = try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.nullfx.distiller.shortcut.guild-wars-2-f484a9")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Guild Wars 2")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "DistillerShortcut")
        XCTAssertEqual(info["LSUIElement"] as? Bool, true, "No Dock icon of its own: the game shows its own")
        XCTAssertEqual(info["LSApplicationCategoryType"] as? String, "public.app-category.games")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/DistillerShortcut").path))
        XCTAssertNotNil(ICNS.read(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/AppIcon.icns"))))
        XCTAssertEqual(ShortcutApp.manifest(of: app), ShortcutApp.Manifest(gameID: "guild-wars-2-f484a9", title: "Guild Wars 2"))
        let verify = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--strict", app.path])
        XCTAssertEqual(verify.status, 0, "Signed for this Mac")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".Guild Wars 2.app.partial").path))

        // Making it again replaces it; something else with that name is never replaced.
        try await ShortcutApp.create(gameID: "guild-wars-2-f484a9", title: "Guild Wars 2", icon: nil, program: program, at: app, sign: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/AppIcon.icns").path))
        let other = root.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(at: other.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        do {
            try await ShortcutApp.create(gameID: "x", title: "Other", icon: nil, program: program, at: other, sign: false)
            XCTFail("Replaced an app that isn't a shortcut")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("Contents").path))
        }
        do {
            try await ShortcutApp.create(gameID: "x", title: "X", icon: nil, program: root.appendingPathComponent("missing"),
                                         at: root.appendingPathComponent("X.app"), sign: false)
            XCTFail("Made a shortcut without its program")
        } catch {}
        XCTAssertEqual(ShortcutApp.bundleIdentifier(for: "Steam games/440"), "com.nullfx.distiller.shortcut.steam-games-440")
    }

    func testNoticesGamesStartedOutsideTheApp() throws {
        let engine = try DistillerEngine(paths: DistillerPaths(root: root.appendingPathComponent("home"), storage: StorageSettings()), hardware: Macs.m3Pro)
        let bottle = Bottle(id: "gw2", name: "Guild Wars 2", wine: "wine-staging@11.21", createdAt: Date())
        try FileManager.default.createDirectory(at: engine.bottles.prefix(of: bottle), withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        let recipe = Recipe(id: "dxvk", game: GameInfo(title: "Guild Wars 2", slug: "guild-wars-2"),
                            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .dxvk),
                            launch: LaunchSpec(exe: #"C:\Games\Guild Wars 2\Gw2-64.exe"#))
        let game = Game(id: "gw2", title: "Guild Wars 2", bottleID: "gw2", recipe: recipe)
        let prefix = engine.bottles.prefix(of: bottle).path
        // Started directly, Wine shows the Mac path; from inside Windows, the C:\ path.
        var processes = BottleProcesses(active: [prefix], commands: [prefix: ["/Volumes/Games Drive/GW2/Gw2-64.exe -mapLoadinfo"]])
        XCTAssertTrue(engine.isGameRunning(game, processes: processes))
        processes.commands[prefix] = [#"C:\Games\Guild Wars 2\gw2-64.exe"#]
        XCTAssertTrue(engine.isGameRunning(game, processes: processes), "Names compare without case")
        processes.commands[prefix] = [#"C:\Games\Guild Wars 2\NotGw2-64.exe"#, #"C:\windows\system32\services.exe"#]
        XCTAssertFalse(engine.isGameRunning(game, processes: processes))
        processes.commands[prefix] = [#"C:\Games\Guild Wars 2\Gw2-64.exe"#]
        processes.active = []
        XCTAssertFalse(engine.isGameRunning(game, processes: processes), "Not while its bottle is idle")
        XCTAssertEqual(DistillerEngine.programPath(of: #"C:\Program Files (x86)\Steam\steam.exe -silent"#), #"C:\Program Files (x86)\Steam\steam.exe"#)
    }
}
