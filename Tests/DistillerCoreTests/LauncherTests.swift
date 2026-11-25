import Foundation
import XCTest
@testable import DistillerCore

/// Launchers other than Steam (Battle.net), and what all launchers share. The Battle.net files
/// here are shaped like a real bottle's (Diablo III installed, World of Warcraft downloading).
final class LauncherTests: XCTestCase {
    var root: URL!
    var engine: DistillerEngine!

    let summary = #"""
    {"installed":[
     {"box_art_uri":"https://example.com/d3.webp","icon_index":0,"icon_path":"C:/Program Files (x86)/Diablo III/Diablo III Launcher.exe","last_played_timestamp":0,"launch_uri":"battlenet://game/d3","name":"Diablo III","product_id":"d3"},
     {"icon_path":"C:/Program Files (x86)/World of Warcraft/World of Warcraft Launcher.exe","launch_uri":"battlenet://game/wow","name":"World of Warcraft","product_id":"wow"},
     {"icon_path":"C:/Program Files (x86)/Overwatch/Overwatch Launcher.exe","name":"Overwatch","product_id":"pro"},
     {"icon_path":"C:/Windows/evil.exe","name":"Bad id","product_id":"../x"}
    ]}
    """#

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-launchers-\(UUID().uuidString)")
        engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRecognisesLaunchers() {
        XCTAssertEqual(LauncherKind.kind(ofClient: SteamLibrary.clientPath), .steam)
        XCTAssertEqual(LauncherKind.kind(ofClient: BattleNetLibrary.clientPath), .battlenet)
        XCTAssertEqual(LauncherKind.kind(ofClient: #"C:\Program Files (x86)\Battle.net\Battle.net.exe"#), .battlenet)
        XCTAssertNil(LauncherKind.kind(ofClient: #"C:\Program Files (x86)\World of Warcraft\World of Warcraft Launcher.exe"#))
        XCTAssertEqual(BattleNetLibrary.gameClient(launcherExe: BattleNetLibrary.clientPath), #"C:\Program Files (x86)\Battle.net\Battle.net.exe"#)
    }

    func testStartsBattleNetGamesByTheirCode() {
        XCTAssertEqual(DistillerEngine.launchArguments(kind: .battlenet, gameID: "wow", recipeArgs: nil), ["--exec=launch WoW"])
        XCTAssertEqual(DistillerEngine.launchArguments(kind: .battlenet, gameID: "d3", recipeArgs: ["-windowed"]), ["--exec=launch D3"],
                       "Battle.net doesn't pass anything on")
        XCTAssertEqual(DistillerEngine.launchArguments(kind: .battlenet, gameID: "newgame", recipeArgs: nil), ["--exec=launch newgame"])
        XCTAssertEqual(DistillerEngine.launchArguments(kind: .battlenet, gameID: "anbs", recipeArgs: nil), ["--exec=launch ANBS"], "Diablo Immortal")
        XCTAssertEqual(DistillerEngine.launchArguments(kind: .steam, gameID: "440", recipeArgs: ["-applaunch", "440", "-dx11"]), ["-applaunch", "440", "-dx11"])
    }

    func testReadsWhatIsRunningInEachBottle() {
        let ps = """
        /x/bin/wineserver WINEPREFIX=/Volumes/Games Drive/Bottles/bnet/prefix WINEDEBUG=-all
        C:\\Program Files (x86)\\World of Warcraft\\_retail_\\Wow.exe -launcherlogin WINEPREFIX=/Volumes/Games Drive/Bottles/bnet/prefix PATH=/usr/bin
        C:\\Program Files (x86)\\World of Warcraft\\World of Warcraft Launcher.exe WINEPREFIX=/Volumes/Games Drive/Bottles/bnet/prefix
        C:\\windows\\system32\\services.exe WINEPREFIX=/b/steam/prefix
        /usr/bin/login -pf me
        """
        let processes = DistillerEngine.bottleProcesses(psOutput: ps)
        XCTAssertEqual(processes.active, ["/Volumes/Games Drive/Bottles/bnet/prefix"], "Paths with spaces; only wineserver makes a bottle active")
        let commands = processes.commands["/Volumes/Games Drive/Bottles/bnet/prefix"] ?? []
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(BattleNetLibrary.runningPrograms(inFolder: #"C:\Program Files (x86)\World of Warcraft\"#, commands: commands), ["Wow.exe"],
                       "Not its launcher stub")
        XCTAssertEqual(BattleNetLibrary.runningPrograms(inFolder: #"c:\program files (x86)\diablo iii"#, commands: commands), [])
        XCTAssertEqual(DistillerEngine.activePrefixes(psOutput: ps), processes.active)
    }

    func testPlacesWindowsProgramsByTheirWorkingFolder() {
        // As this Wine shows them: only Wine's own processes carry WINEPREFIX; Windows programs
        // appear as C:\ paths or as the Mac path inside drive_c, with no environment.
        let ps = """
          101 /w/lib/wine/../../bin/wineserver WINEPREFIX=/b/steam/prefix WINEDEBUG=-all
          102 /b/steam/prefix/drive_c/Program Files (x86)/Steam/steam.exe -silent
          103 C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe -nocrashdialog -lang=en_US
          104 /usr/libexec/something HOME=/Users/x
        """
        XCTAssertEqual(DistillerEngine.unplacedWindowsPrograms(psOutput: ps), [
            102: #"C:\Program Files (x86)\Steam\steam.exe -silent"#,
            103: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe -nocrashdialog -lang=en_US"#,
        ])
        XCTAssertEqual(DistillerEngine.bottleProcesses(psOutput: ps).active, ["/b/steam/prefix"], "Leading pids are fine")
        XCTAssertEqual(DistillerEngine.bottleProcesses(psOutput: ps).pids, ["/b/steam/prefix": [101]], "Kept, for the bottle's windows")
        let lsof = "p102\nfcwd\nn/b/steam/prefix/drive_c/Program Files (x86)/Steam\np103\nfcwd\nn/b/steam/prefix/drive_c\n"
        XCTAssertEqual(DistillerEngine.workingFolders(lsofOutput: lsof), [102: "/b/steam/prefix/drive_c/Program Files (x86)/Steam", 103: "/b/steam/prefix/drive_c"])
        XCTAssertEqual(DistillerEngine.prefix(ofFolder: "/Volumes/Games Drive/b/prefix/drive_c/windows"), "/Volumes/Games Drive/b/prefix")
        XCTAssertEqual(DistillerEngine.prefix(ofFolder: "/b/prefix/drive_c"), "/b/prefix")
        XCTAssertNil(DistillerEngine.prefix(ofFolder: "/Users/x/drive_cx/y"))
        XCTAssertNil(DistillerEngine.prefix(ofFolder: "/Volumes/Games/Guild Wars 2"), "A game used in place from another drive")
    }

    func testOldSteamLinksCarryOver() throws {
        // As Distiller 1.1 stored a Steam game.
        let recipe = Recipe(id: "steam-440", game: GameInfo(title: "Team Fortress 2", slug: "team-fortress-2"),
                            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d),
                            launch: LaunchSpec(exe: SteamLibrary.clientPath, args: ["-applaunch", "440"]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(
            [Game(id: "steam-steam-440", title: "Team Fortress 2", bottleID: "steam", recipe: recipe)])) as? [[String: Any]])
        json[0]["steam"] = ["app_id": "440", "launcher_id": "steam", "program": #"C:\TF2\tf.exe"#]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: engine.paths.libraryFile)

        let game = try XCTUnwrap(engine.library.load().first)
        XCTAssertEqual(game.launchedBy, LauncherLink(kind: .steam, gameID: "440", launcherID: "steam", program: #"C:\TF2\tf.exe"#))
        try engine.library.upsert(game)
        let saved = try String(contentsOf: engine.paths.libraryFile, encoding: .utf8)
        XCTAssertTrue(saved.contains("launched_by"))
        XCTAssertFalse(saved.contains("\"steam\" :"), "Stored the new way")
    }

    func testSteamStartOptions() throws {
        XCTAssertEqual(LauncherOptions(startView: .normal).steamStartArguments, ["-nobigpicture"])
        XCTAssertEqual(LauncherOptions(startView: .bigPicture).steamStartArguments, ["-gamepadui"])
        XCTAssertEqual(LauncherOptions(startView: .menuBar).steamStartArguments, [], "Steam ignores -silent here: no longer used")
        XCTAssertFalse(LauncherOptions.StartView.offered.contains(.menuBar))
        XCTAssertEqual(LauncherOptions(startView: .small).steamStartArguments, [], "Small Mode is a link, once Steam is up")
        XCTAssertEqual(LauncherOptions(startView: .small, friends: .invisible).steamLinksAfterStart, ["steam://open/minigameslist"])
        XCTAssertEqual(LauncherOptions(friends: .offline).steamLinksAfterStart, [], "The status is written, not sent")
        XCTAssertEqual(LauncherOptions(friends: .offline).steamPersonaState, 0)
        XCTAssertEqual(LauncherOptions(friends: .online).steamPersonaState, 1)
        XCTAssertEqual(LauncherOptions(friends: .away).steamPersonaState, 3)
        XCTAssertEqual(LauncherOptions(friends: .invisible).steamPersonaState, 7)
        XCTAssertNil(LauncherOptions().steamPersonaState)
        XCTAssertTrue(LauncherOptions().isEmpty)
        XCTAssertEqual(LauncherOptions().steamLinksAfterStart, [])

        // Saved on Steam's entry, found from its games; "as Steam left it" stores nothing.
        let recipe = Recipe(id: "steam", game: GameInfo(title: "Steam", slug: "steam"),
                            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .wined3d),
                            launch: LaunchSpec(exe: SteamLibrary.clientPath))
        try engine.library.upsert(Game(id: "steam", title: "Steam", bottleID: "steam", recipe: recipe))
        let tf2 = Game(id: "steam-steam-440", title: "Team Fortress 2", bottleID: "steam", recipe: recipe,
                       launchedBy: LauncherLink(kind: .steam, gameID: "440", launcherID: "steam", program: nil))
        try engine.library.upsert(tf2)
        try engine.setLauncherOptions(LauncherOptions(startView: .small, friends: .invisible), for: "steam")
        XCTAssertEqual(engine.launcherEntry(for: tf2)?.launcherOptions, LauncherOptions(startView: .small, friends: .invisible))
        XCTAssertEqual(engine.launcherEntry(for: try engine.library.game(id: "steam"))?.id, "steam")
        let saved = try String(contentsOf: engine.paths.libraryFile, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"start_view\" : \"small\"") && saved.contains("\"friends\" : \"invisible\""), saved)
        try engine.setLauncherOptions(LauncherOptions(), for: "steam")
        XCTAssertNil(try engine.library.game(id: "steam").launcherOptions)
        XCTAssertNil(engine.launcherEntry(for: Game(id: "x", title: "X", bottleID: "x", recipe: Recipe(
            id: "x", game: GameInfo(title: "X", slug: "x"), stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .dxvk),
            launch: LaunchSpec(exe: #"C:\x.exe"#)))), "An ordinary game has no launcher")
    }

    func testWritesSteamsSavedFriendsStatus() throws {
        // Shaped like a real localconfig.vdf (a JSON value with escaped quotes).
        let config = "\"UserLocalConfigStore\"\n{\n\t\"WebStorage\"\n\t{\n"
            + "\t\t\"ChatStorePopupState_123\"\t\t\"{\\\"bFriendsListVisible\\\":false}\"\n"
            + "\t\t\"FriendStoreLocalPrefs_123\"\t\t\"{\\\"ePersonaState\\\":7,\\\"strNonFriendsAllowedToMsg\\\":\\\"\\\"}\"\n"
            + "\t}\n}\n"
        let updated = try XCTUnwrap(SteamLibrary.settingPersonaState(0, in: config))
        XCTAssertTrue(updated.contains(#""FriendStoreLocalPrefs_123""# + "\t\t" + #""{\"ePersonaState\":0,\"strNonFriendsAllowedToMsg\":\"\"}""#), updated)
        XCTAssertTrue(updated.contains(#""ChatStorePopupState_123""# + "\t\t" + #""{\"bFriendsListVisible\":false}""#), "Other entries untouched")
        XCTAssertEqual(updated.count, config.count, "Only the one digit changed")
        XCTAssertEqual(try XCTUnwrap(SteamLibrary.settingPersonaState(7, in: updated)), config)
        // It parses as VDF still, with the new state.
        let vdf = try XCTUnwrap(VDFValue.parse(updated))
        XCTAssertEqual(vdf["UserLocalConfigStore"]?["WebStorage"]?["FriendStoreLocalPrefs_123"]?.string,
                       #"{"ePersonaState":0,"strNonFriendsAllowedToMsg":""}"#)
        XCTAssertNil(SteamLibrary.settingPersonaState(0, in: "\"UserLocalConfigStore\"\n{\n}\n"), "Not signed in yet")
    }

    func testGamesBattleNetInstallsComeAndGo() async throws {
        let bottle = Bottle(id: "bnet", name: "Battle.net", wine: "sikarugir@10.0_8", createdAt: Date())
        let driveC = engine.bottles.prefix(of: bottle).appendingPathComponent("drive_c")
        let agent = driveC.appendingPathComponent("ProgramData/Battle.net/Agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        for program in ["Program Files (x86)/Battle.net/Battle.net Launcher.exe",
                        "Program Files (x86)/Diablo III/Diablo III Launcher.exe",
                        "Program Files (x86)/World of Warcraft/World of Warcraft Launcher.exe"] {
            let url = driveC.appendingPathComponent(program)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: url)
        }
        // Overwatch is listed but its program isn't there yet (just started downloading).
        try summary.write(to: agent.appendingPathComponent("aggregate.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(BattleNetLibrary.installedGames(root: engine.bottles.root(of: bottle)).map(\.gameID), ["d3", "wow"])

        let recipe = Recipe(id: "battle-net", game: GameInfo(title: "Battle.net", slug: "battle-net"),
                            stack: StackSpec(runner: RunnerRequirement(family: "sikarugir"), graphics: .wined3d),
                            launch: LaunchSpec(exe: BattleNetLibrary.clientPath))
        let launcher = Game(id: "bnet", title: "Battle.net", bottleID: bottle.id, recipe: recipe)
        try engine.library.upsert(launcher)
        XCTAssertEqual(engine.launcherKind(of: launcher), .battlenet)
        XCTAssertFalse(engine.isSteamLauncher(launcher))

        let sync = engine.syncLauncherGames()
        XCTAssertEqual(sync.added.map(\.title), ["Diablo III", "World of Warcraft"])
        let wow = try engine.library.game(id: "bnet-battlenet-wow")
        XCTAssertEqual(wow.bottleID, "bnet", "Battle.net's bottle")
        XCTAssertEqual(wow.launchedBy, LauncherLink(kind: .battlenet, gameID: "wow", launcherID: "bnet",
                                                    program: #"C:\Program Files (x86)\World of Warcraft\World of Warcraft Launcher.exe"#))
        XCTAssertEqual(wow.recipe.launch, LaunchSpec(exe: #"C:\Program Files (x86)\Battle.net\Battle.net.exe"#, args: ["--exec=launch WoW"]))
        XCTAssertEqual(wow.recipe.stack.runner.family, "sikarugir")
        XCTAssertNil(engine.launcherKind(of: wow), "A launcher's game isn't a launcher")
        XCTAssertTrue(engine.syncLauncherGames().isEmpty)

        // Running while a program from its folder runs in Battle.net's bottle.
        let prefix = engine.bottles.prefix(of: bottle).path
        var processes = BottleProcesses(active: [prefix], commands: [prefix: [#"C:\Program Files (x86)\World of Warcraft\_retail_\Wow.exe"#]])
        XCTAssertTrue(engine.launcherGameState(wow, processes: processes).running)
        XCTAssertFalse(engine.launcherGameState(try engine.library.game(id: "bnet-battlenet-d3"), processes: processes).running)
        processes.active = []
        XCTAssertFalse(engine.launcherGameState(wow, processes: processes).running, "Not while the bottle is idle")

        // Uninstalled in Battle.net: the entry goes.
        try summary.replacingOccurrences(of: "\"product_id\":\"wow\"", with: "\"product_id\":\"wow_gone\"")
            .write(to: agent.appendingPathComponent("aggregate.json"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: driveC.appendingPathComponent("Program Files (x86)/World of Warcraft"))
        XCTAssertEqual(engine.syncLauncherGames().removed.map(\.id), ["bnet-battlenet-wow"])
    }
}
