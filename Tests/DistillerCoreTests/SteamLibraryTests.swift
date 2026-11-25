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

        let first = engine.syncLauncherGames()
        XCTAssertEqual(first.added.map(\.title), ["Team Fortress 2"])
        let tf2 = try XCTUnwrap(first.added.first)
        XCTAssertEqual(tf2.bottleID, bottle.id, "It shares Steam's bottle")
        XCTAssertEqual(tf2.launchedBy, LauncherLink(kind: .steam, gameID: "440", launcherID: "steam",
                                                     program: #"C:\Program Files (x86)\Steam\steamapps\common\Team Fortress 2\tf_win64.exe"#))
        XCTAssertEqual(tf2.recipe.launch, LaunchSpec(exe: SteamLibrary.clientPath, args: ["-applaunch", "440"]))
        XCTAssertEqual(tf2.recipe.game.slug, "team-fortress-2")
        XCTAssertFalse(engine.isSteamLauncher(tf2))
        XCTAssertTrue(engine.syncLauncherGames().isEmpty, "Nothing changes on the next sync")

        // Steam's recipe changes (a graphics layer for the whole bottle): its games follow.
        var changedLauncher = launcher
        changedLauncher.recipe.stack.graphics = .dxvk
        try engine.library.upsert(changedLauncher)
        engine.syncLauncherGames()
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

        // A recipe whose Steam arguments got mixed up is put right at the next sync.
        var mixed = try engine.library.game(id: tf2.id)
        mixed.recipe.launch?.args = ["-applaunch", "440", "-applaunch", "-dx11", "440"]
        try engine.library.upsert(mixed)
        engine.syncLauncherGames()
        XCTAssertEqual(try engine.library.game(id: tf2.id).recipe.launch?.args, ["-applaunch", "440", "-dx11"])

        // Uninstalled in Steam: the entry goes.
        try FileManager.default.removeItem(at: steam.appendingPathComponent("steamapps/appmanifest_440.acf"))
        XCTAssertEqual(engine.syncLauncherGames().removed.map(\.id), [tf2.id])
        XCTAssertEqual(engine.library.load().map(\.id), ["steam"])
    }

    func testRecognisesASteamGamesRecipe() {
        func recipe(_ exe: String, _ args: [String]?) -> Recipe {
            Recipe(id: "x", game: GameInfo(title: "Portal 2", slug: "portal-2"),
                   stack: StackSpec(runner: RunnerRequirement(family: "sikarugir"), graphics: .wined3d), launch: LaunchSpec(exe: exe, args: args))
        }
        XCTAssertEqual(SteamLibrary.gameAppID(in: recipe(SteamLibrary.clientPath, ["-applaunch", "620"])), "620")
        XCTAssertEqual(SteamLibrary.gameAppID(in: recipe(SteamLibrary.clientPath, ["-silent", "-applaunch", "620", "-dx11"])), "620")
        XCTAssertNil(SteamLibrary.gameAppID(in: recipe(SteamLibrary.clientPath, nil)), "Steam itself")
        XCTAssertNil(SteamLibrary.gameAppID(in: recipe(SteamLibrary.clientPath, ["-applaunch"])))
        XCTAssertNil(SteamLibrary.gameAppID(in: recipe(SteamLibrary.clientPath, ["-applaunch", "x620"])))
        XCTAssertNil(SteamLibrary.gameAppID(in: recipe(#"C:\Games\Portal\portal2.exe"#, ["-applaunch", "620"])), "Not through Steam")
    }

    func testAddingASteamGamesRecipeGoesThroughSteam() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
        var portal = Recipe(id: "steam-620", notes: "Use -novid.", game: GameInfo(title: "Portal 2", slug: "portal-2"),
                            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d),
                            launch: LaunchSpec(exe: SteamLibrary.clientPath, args: ["-applaunch", "620", "-novid"]))
        portal.name = "No intro"

        // Never a bottle of its own.
        do {
            _ = try await engine.install(recipe: portal)
            XCTFail("Installed a Steam game into a bottle of its own")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Steam game"), error.localizedDescription)
        }
        // Without Steam in the library: say so.
        XCTAssertThrowsError(try engine.installSteamGame(portal) { _, _, _ in XCTFail("Asked a Steam that isn't there") }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Add Steam"), error.localizedDescription)
        }

        // Steam in the library, without the game: Steam is asked to install it.
        let bottle = Bottle(id: "steam", name: "Steam", wine: "wine-staging@11.21", createdAt: Date())
        let steam = engine.bottles.prefix(of: bottle).appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Portal 2"), withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        try Data("MZ".utf8).write(to: steam.appendingPathComponent("steam.exe"))
        let steamRecipe = Recipe(id: "steam", game: GameInfo(title: "Steam", slug: "steam"),
                                 stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d),
                                 launch: LaunchSpec(exe: SteamLibrary.clientPath))
        try engine.library.upsert(Game(id: "steam", title: "Steam", bottleID: bottle.id, recipe: steamRecipe))
        var asked: [String] = []
        let result = try engine.installSteamGame(portal) { launcher, client, appID in
            XCTAssertEqual(launcher.id, "steam")
            XCTAssertEqual(client, SteamLibrary.clientPath)
            asked.append(appID)
        }
        XCTAssertEqual(asked, ["620"])
        guard case .requested(let appID, let launcher) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(appID, "620")
        XCTAssertEqual(launcher.id, "steam")
        XCTAssertEqual(engine.library.load().map(\.id), ["steam"], "No entry until Steam has it")

        // Steam finishes: the entry appears under Steam with the recipe's own options.
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Portal 2"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: steam.appendingPathComponent("steamapps/common/Portal 2/portal2.exe"))
        try manifest.replacingOccurrences(of: "\"440\"", with: "\"620\"").replacingOccurrences(of: "Team Fortress 2", with: "Portal 2")
            .write(to: steam.appendingPathComponent("steamapps/appmanifest_620.acf"), atomically: true, encoding: .utf8)
        XCTAssertEqual(engine.syncLauncherGames().added.map(\.title), ["Portal 2"])
        let entry = try engine.library.game(id: "steam-steam-620")
        XCTAssertEqual(entry.recipe.launch?.args, ["-applaunch", "620", "-novid"])
        XCTAssertEqual(entry.recipe.notes, "Use -novid.")
        XCTAssertEqual(entry.recipe.name, "No intro")
        XCTAssertEqual(entry.bottleID, "steam", "Steam's bottle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.paths.pendingSteamGames.appendingPathComponent("steam-620.yaml").path))

        // Adding a recipe for a game Steam already has: applied at once, nothing asked of Steam.
        var again = portal
        again.launch?.args = ["-applaunch", "620", "-windowed"]
        let second = try engine.installSteamGame(again) { _, _, _ in XCTFail("Asked Steam for a game it has") }
        guard case .alreadyInstalled(let game) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(game.recipe.launch?.args, ["-applaunch", "620", "-windowed"])
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
        tf2.launchedBy = LauncherLink(kind: .steam, gameID: "440", launcherID: "steam", program: nil)
        try engine.library.upsert(tf2)
        XCTAssertTrue(engine.syncLauncherGames().isEmpty, "A missing bottle (a disconnected drive) removes nothing")
        XCTAssertEqual(engine.library.load().count, 2)
    }

    func testSteamsOwnArgumentsAreTakenOutWhereverTheyAre() {
        // Portal 2's recipe after editing (Steam's part ended up in the middle and was added again).
        let broken = ["-applaunch", "620", "-applaunch", "-vulkan", "620"]
        XCTAssertEqual(DistillerEngine.steamOptions(appID: "620", in: broken), ["-vulkan"])
        XCTAssertEqual(DistillerEngine.steamLaunchArguments(appID: "620", recipeArgs: broken), ["-applaunch", "620", "-vulkan"])
        XCTAssertEqual(DistillerEngine.steamOptions(appID: "620", in: ["-vulkan", "-applaunch", "620", "-novid"]), ["-vulkan", "-novid"])
        XCTAssertEqual(DistillerEngine.steamOptions(appID: "620", in: ["-AppLaunch", "620"]), [])
        XCTAssertEqual(DistillerEngine.steamOptions(appID: "620", in: ["+exec", "autoexec.cfg"]), ["+exec", "autoexec.cfg"])
        XCTAssertEqual(DistillerEngine.steamOptions(appID: "620", in: nil), [])
    }

    func testPlayersArgumentsFollowSteamsOwn() {
        XCTAssertEqual(DistillerEngine.steamLaunchArguments(appID: "440", recipeArgs: ["-applaunch", "440"]), ["-applaunch", "440"])
        XCTAssertEqual(DistillerEngine.steamLaunchArguments(appID: "440", recipeArgs: ["-applaunch", "440", "-dx11"]), ["-applaunch", "440", "-dx11"])
        // Arguments set without Steam's (a launch override): Steam's still come first.
        XCTAssertEqual(DistillerEngine.steamLaunchArguments(appID: "440", recipeArgs: ["-windowed"]), ["-applaunch", "440", "-windowed"])
        XCTAssertEqual(DistillerEngine.steamLaunchArguments(appID: "440", recipeArgs: nil), ["-applaunch", "440"])
    }
}
