import Foundation
import XCTest
@testable import DistillerCore

/// Games Steam installs get library entries of their own. The Steam files here are shaped like
/// the real ones (from a test install of a free game), with made-up values.
final class SteamLibraryTests: XCTestCase {
    let manifest = #"""
    "AppState"
    {
    	"appid"		"440"
    	"universe"		"1"
    	"name"		"Team Fortress 2"
    	"StateFlags"		"4"
    	"installdir"		"Team Fortress 2"
    	"SizeOnDisk"		"33292355826"
    	"BytesToDownload"		"17384016960"
    	"BytesDownloaded"		"17384016960"
    	"InstalledDepots"
    	{
    		"441"
    		{
    			"manifest"		"123"
    		}
    	}
    }
    """#

    func testParsesVDF() throws {
        let vdf = try XCTUnwrap(VDFValue.parse(#"""
        // a comment
        "libraryfolders"
        {
            "0"
            {
                "path"		"C:\\Program Files (x86)\\Steam"
                "apps" { "440" "0" "228980" "0" }
            }
        }
        """#))
        XCTAssertEqual(vdf["LibraryFolders"]?["0"]?["path"]?.string, #"C:\Program Files (x86)\Steam"#, "Keys without case; \\\\ unescaped")
        XCTAssertEqual(vdf["libraryfolders"]?["0"]?["apps"]?.entries.map(\.key), ["440", "228980"])
        XCTAssertNil(VDFValue.parse(#""a" { "b" "c" "#), "Unclosed block")
        XCTAssertNil(VDFValue.parse(#""a" }"#))
        XCTAssertNil(VDFValue.parse(#""a""#), "A key without a value")
        XCTAssertNil(VDFValue.parse(String(repeating: #""a" {"#, count: 40) + String(repeating: "}", count: 40)), "Nesting is limited")
    }

    func testReadsAnAppManifest() throws {
        let app = try XCTUnwrap(SteamLibrary.app(fromManifest: manifest))
        XCTAssertEqual(app.appID, "440")
        XCTAssertEqual(app.name, "Team Fortress 2")
        XCTAssertEqual(app.installFolder, "Team Fortress 2")
        XCTAssertTrue(app.fullyInstalled)
        XCTAssertEqual(app.bytesDownloaded, 17_384_016_960)
        let downloading = manifest.replacingOccurrences(of: "\"StateFlags\"\t\t\"4\"", with: "\"StateFlags\"\t\t\"1026\"")
        XCTAssertEqual(SteamLibrary.app(fromManifest: downloading)?.fullyInstalled, false)
        let escaping = manifest.replacingOccurrences(of: "\"installdir\"\t\t\"Team Fortress 2\"", with: "\"installdir\"\t\t\"..\"")
        XCTAssertNil(SteamLibrary.app(fromManifest: escaping), "Install folders can't leave steamapps\\common")
    }

    func testReadsWhetherAGameIsRunning() {
        let log = """
        [2026-11-15 00:49:10] AppID 440 adding PID 1680 as a tracked process ""C:\\Program Files (x86)\\Steam\\steamapps\\common\\Team Fortress 2\\tf_win64.exe" -steam"
        [2026-11-15 00:49:11] SSGL: change [440] LCT 102427040->0
        """
        XCTAssertTrue(SteamLibrary.runningState(appID: "440", log: log).running)
        XCTAssertEqual(SteamLibrary.runningState(appID: "440", log: log).pid, 1680)
        let ended = log + "\n[2026-11-15 00:52:50] AppID 440 no longer tracking PID 1680, exit code 0\n[2026-11-15 00:52:50] Remove 440 from running list"
        XCTAssertFalse(SteamLibrary.runningState(appID: "440", log: ended).running)
        XCTAssertFalse(SteamLibrary.runningState(appID: "44", log: log).running, "Another app's ID doesn't count")
        // Steam writes Windows line endings.
        let windows = ended.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertFalse(SteamLibrary.runningState(appID: "440", log: windows).running)
        XCTAssertTrue(SteamLibrary.runningState(appID: "440", log: log.replacingOccurrences(of: "\n", with: "\r\n")).running)
    }

    func testFindsWhichBottlesAreActive() {
        let ps = """
        /x/wine/bin/wineserver WINEPREFIX=/b/steam/prefix WINEDEBUG=-all HOME=/u
        /x/wine/lib/wine/../../bin/wineserver WINEPREFIX=/b/other/prefix
        /x/wine/bin/wine C:\\x.exe WINEPREFIX=/b/third/prefix
        """
        XCTAssertEqual(DistillerEngine.activePrefixes(psOutput: ps), ["/b/steam/prefix", "/b/other/prefix"])
    }

    func testRecognizesSteamsClient() {
        XCTAssertTrue(SteamLibrary.isClient(#"C:\Program Files (x86)\Steam\steam.exe"#))
        XCTAssertTrue(SteamLibrary.isClient("C:/Games/Steam/Steam.exe"))
        XCTAssertFalse(SteamLibrary.isClient(#"C:\Games\NotSteam\steam.exe.bak"#))
        XCTAssertFalse(SteamLibrary.isClient(#"C:\Program Files (x86)\Steam\steamapps\common\Game\game.exe"#))
    }

    // MARK: Library sync

    func testGamesSteamInstallsComeAndGo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
        let bottle = Bottle(id: "steam", name: "Steam", wine: "wine-staging@11.21", createdAt: Date())
        let steam = engine.bottles.prefix(of: bottle).appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Team Fortress 2"), withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        try Data("MZ".utf8).write(to: steam.appendingPathComponent("steam.exe"))
        try Data(count: 4096).write(to: steam.appendingPathComponent("steamapps/common/Team Fortress 2/tf_win64.exe"))
        try manifest.write(to: steam.appendingPathComponent("steamapps/appmanifest_440.acf"), atomically: true, encoding: .utf8)
        // Steam's redistributables: installed, but not a game.
        try manifest.replacingOccurrences(of: "\"440\"", with: "\"228980\"").replacingOccurrences(of: "Team Fortress 2", with: "Steamworks Shared")
            .write(to: steam.appendingPathComponent("steamapps/appmanifest_228980.acf"), atomically: true, encoding: .utf8)
        // A game still downloading isn't added yet.
        try manifest.replacingOccurrences(of: "\"440\"", with: "\"570\"").replacingOccurrences(of: "\"StateFlags\"\t\t\"4\"", with: "\"StateFlags\"\t\t\"1026\"")
            .write(to: steam.appendingPathComponent("steamapps/appmanifest_570.acf"), atomically: true, encoding: .utf8)

        let recipe = Recipe(id: "steam", game: GameInfo(title: "Steam", slug: "steam"),
                            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d),
                            launch: LaunchSpec(exe: SteamLibrary.clientPath))
        let launcher = Game(id: "steam", title: "Steam", bottleID: bottle.id, recipe: recipe)
        try engine.library.upsert(launcher)
        XCTAssertTrue(engine.isSteamLauncher(launcher))

        let first = engine.syncSteamGames()
        XCTAssertEqual(first.added.map(\.title), ["Team Fortress 2"])
        let tf2 = try XCTUnwrap(first.added.first)
        XCTAssertEqual(tf2.bottleID, bottle.id, "It shares Steam's bottle")
        XCTAssertEqual(tf2.steam, Game.SteamLink(appID: "440", launcherID: "steam",
                                                 program: #"C:\Program Files (x86)\Steam\steamapps\common\Team Fortress 2\tf_win64.exe"#))
        XCTAssertEqual(tf2.recipe.launch, LaunchSpec(exe: SteamLibrary.clientPath, args: ["-applaunch", "440"]))
        XCTAssertEqual(tf2.recipe.game.slug, "team-fortress-2")
        XCTAssertFalse(engine.isSteamLauncher(tf2))
        XCTAssertTrue(engine.syncSteamGames().isEmpty, "Nothing changes on the next sync")

        // Steam's recipe changes (a graphics layer for the whole bottle): its games follow.
        var changedLauncher = launcher
        changedLauncher.recipe.stack.graphics = .dxvk
        try engine.library.upsert(changedLauncher)
        engine.syncSteamGames()
        XCTAssertEqual(try engine.library.game(id: tf2.id).recipe.stack.graphics, .dxvk)
        XCTAssertEqual(try engine.library.game(id: tf2.id).recipe.launch?.args, ["-applaunch", "440"], "Its launch stays its own")

        // Saving the game's recipe keeps Steam's bottle settings, whatever it says, and leaves
        // Steam's recipe file in the bottle alone.
        var edited = try engine.library.game(id: tf2.id).recipe
        edited.stack.graphics = .d3dmetal
        edited.launch?.args = ["-applaunch", "440", "-dx11"]
        let saved = try await engine.updateRecipe(edited, for: try engine.library.game(id: tf2.id))
        XCTAssertEqual(saved.recipe.stack.graphics, .dxvk)
        XCTAssertEqual(saved.recipe.launch?.args, ["-applaunch", "440", "-dx11"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.bottles.root(of: bottle).appendingPathComponent("recipe.yaml").path))

        // Its editable file is its own, beside Steam's; reloading it keeps Steam's settings too.
        let steamFile = try engine.writeRecipeFile(for: launcher)
        let gameFile = try engine.writeRecipeFile(for: saved)
        XCTAssertEqual(steamFile.lastPathComponent, "recipe.yaml")
        XCTAssertEqual(gameFile.lastPathComponent, "recipe-steam-440.yaml")
        XCTAssertEqual(try RecipeLoader.load(from: steamFile).launch, launcher.recipe.launch, "Steam's file is untouched")
        let reloaded = try await engine.reloadRecipeFile(for: saved)
        XCTAssertEqual(reloaded.recipe.launch?.args, ["-applaunch", "440", "-dx11"])
        XCTAssertEqual(reloaded.recipe.stack.graphics, .dxvk)

        // Uninstalled in Steam: the entry goes.
        try FileManager.default.removeItem(at: steam.appendingPathComponent("steamapps/appmanifest_440.acf"))
        XCTAssertEqual(engine.syncSteamGames().removed.map(\.id), [tf2.id])
        XCTAssertEqual(engine.library.load().map(\.id), ["steam"])
    }

    func testABottleThatCantBeReadIsLeftAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
        let recipe = Recipe(id: "steam", game: GameInfo(title: "Steam", slug: "steam"),
                            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d),
                            launch: LaunchSpec(exe: SteamLibrary.clientPath))
        try engine.library.upsert(Game(id: "steam", title: "Steam", bottleID: "gone", recipe: recipe))
        var tf2 = Game(id: "steam-steam-440", title: "Team Fortress 2", bottleID: "gone", recipe: recipe)
        tf2.steam = Game.SteamLink(appID: "440", launcherID: "steam", program: nil)
        try engine.library.upsert(tf2)
        XCTAssertTrue(engine.syncSteamGames().isEmpty, "A missing bottle (a disconnected drive) removes nothing")
        XCTAssertEqual(engine.library.load().count, 2)
    }

    func testPlayersArgumentsFollowSteamsOwn() {
        XCTAssertEqual(DistillerEngine.steamLaunchArguments(appID: "440", recipeArgs: ["-applaunch", "440"]), ["-applaunch", "440"])
        XCTAssertEqual(DistillerEngine.steamLaunchArguments(appID: "440", recipeArgs: ["-applaunch", "440", "-dx11"]), ["-applaunch", "440", "-dx11"])
        // Arguments set without Steam's (a launch override): Steam's still come first.
        XCTAssertEqual(DistillerEngine.steamLaunchArguments(appID: "440", recipeArgs: ["-windowed"]), ["-applaunch", "440", "-windowed"])
        XCTAssertEqual(DistillerEngine.steamLaunchArguments(appID: "440", recipeArgs: nil), ["-applaunch", "440"])
    }
}
