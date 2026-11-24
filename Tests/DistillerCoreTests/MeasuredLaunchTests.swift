import Foundation
import XCTest
@testable import DistillerCore

/// A measured launch turns on the Metal HUD's frame log, kept invisible, for one launch.
final class MeasuredLaunchTests: XCTestCase {
    func testSettingsAreAllowedAndReachTheGame() throws {
        for key in MeasuredLaunch.environment.keys {
            XCTAssertTrue(RecipePolicy.isAllowedEnvKey(key), key)
        }
        // Logging needs the HUD on; hiding it (MTL_HUD_HIDDEN) would stop the logging, so the
        // overlay is made transparent instead.
        XCTAssertEqual(MeasuredLaunch.environment["MTL_HUD_LOG_ENABLED"], "1")
        XCTAssertEqual(MeasuredLaunch.environment["MTL_HUD_OPACITY"], "0")
        XCTAssertNil(MeasuredLaunch.environment["MTL_HUD_HIDDEN"])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-measure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
        let recipe = Recipe(id: "dxvk", game: GameInfo(title: "Game", slug: "game"),
                            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .dxvk),
                            launch: LaunchSpec(exe: #"C:\Game\game.exe"#))
        let resolved = engine.resolve(recipe, overrides: LocalOverrides(env: MeasuredLaunch.environment))
        for (key, value) in MeasuredLaunch.environment {
            XCTAssertEqual(resolved.env[key], value, key)
        }
    }
}
