import XCTest
@testable import DistillerCore

final class CheckSessionTests: XCTestCase {
    /// What `wine wmic.exe process get ExecutablePath,ProcessId` printed in a real bottle
    /// (Wine Staging 11.21), with a game and a launcher added, Windows line endings, and the
    /// kind of diagnostics Wine can print first.
    let wmicOutput = [
        "0024:fixme:wbemprox:client_security_SetBlanket 0x7b2ab5c8, 0x1c7e60, 10, 0, (null), 3, 3, 0x0, 0x0",
        "ExecutablePath                                        ProcessID                           ",
        "C:\\windows\\system32\\start.exe                         32                                  ",
        "C:\\windows\\system32\\services.exe                      64                                  ",
        "C:\\Program Files (x86)\\Example Launcher\\Launcher.exe   212                                 ",
        "C:\\Program Files\\Example Game\\Bin  64\\Game.exe         256                                 ",
        "C:\\Program Files\\Example Game\\Bin  64\\Game.exe         260                                 ",
        "D:\\Games\\Other\\Other.exe                              300                                 ",
        "C:\\windows\\system32\\wbem\\wmic.exe                    400                                 ",
        "",
    ].joined(separator: "\r\n")

    func testParsesWineProcessTable() {
        let programs = WineProcessList.parse(wmicOutput)
        XCTAssertEqual(programs.count, 7)
        XCTAssertEqual(programs[2], RunningWindowsProgram(pid: 212, windowsPath: "C:\\Program Files (x86)\\Example Launcher\\Launcher.exe"))
        XCTAssertEqual(programs[3].windowsPath, "C:\\Program Files\\Example Game\\Bin  64\\Game.exe", "Double spaces inside a path survive")
        XCTAssertEqual(programs[3].name, "Game.exe")
        XCTAssertEqual(WineProcessList.parse("wine: could not load kernel32.dll\n"), [], "No table, nothing running")
    }

    /// Redirected to a file, Wine's wmic writes UTF-16 with a byte-order mark; read as UTF-8,
    /// that came out empty, and the check listed nothing running.
    func testReadsWmicsUTF16Output() throws {
        let utf16 = Data([0xFF, 0xFE]) + (wmicOutput.data(using: .utf16LittleEndian) ?? Data())
        XCTAssertEqual(WineProcessList.parse(WineProcessList.decode(utf16)), WineProcessList.parse(wmicOutput))
        let bigEndian = Data([0xFE, 0xFF]) + (wmicOutput.data(using: .utf16BigEndian) ?? Data())
        XCTAssertEqual(WineProcessList.parse(WineProcessList.decode(bigEndian)).count, 7)
        XCTAssertEqual(WineProcessList.parse(WineProcessList.decode(Data(wmicOutput.utf8))).count, 7, "Plain text still works")
        XCTAssertEqual(WineProcessList.decode(Data()), "")
    }

    func testLeavesOutWinesOwnPrograms() {
        let programs = WineProcessList.parse(wmicOutput)
        XCTAssertEqual(programs.filter(\.isWineSystemProgram).map(\.name), ["start.exe", "services.exe", "wmic.exe"])
    }

    func testRunningProgramsBecomeProgramsInTheBottle() throws {
        let driveC = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("drive_c")
        let game = driveC.appendingPathComponent("Program Files/Example Game/Bin  64/Game.exe")
        try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2048).write(to: game)
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }

        var running = WineProcessList.parse(wmicOutput)
        running.append(RunningWindowsProgram(pid: 500, windowsPath: "C:\\Program Files\\..\\..\\outside.exe"))
        let programs = CommunityCheckSession.programs(from: running, driveC: driveC)
        XCTAssertEqual(programs.map(\.windowsPath), [
            "C:\\Program Files (x86)\\Example Launcher\\Launcher.exe",
            "C:\\Program Files\\Example Game\\Bin  64\\Game.exe",
        ], "Wine's own programs, other drives, repeats and paths that climb out are left out")
        let found = try XCTUnwrap(programs.last)
        XCTAssertEqual(found.program.url.standardizedFileURL, game.standardizedFileURL)
        XCTAssertEqual(found.program.relativePath, "Program Files/Example Game/Bin  64/Game.exe")
        XCTAssertEqual(found.program.size, 2048)
    }

    func testSharedRecipesApplySettingsBeforeTheInstaller() throws {
        var draft = RecipeDraft(source: .folder(URL(fileURLWithPath: "/Games/Real Game")), title: "Real Game")
        draft.launchProgram = "Game.exe"
        draft.publicInstallerURL = "https://downloads.example.com/RealGameSetup.exe"
        var recipe = draft.makeRecipe()
        recipe.install = (recipe.install ?? []) + [.winetricks(["corefonts"])]
        let shared = try CommunityCheck.shareableRecipe(from: recipe, installerSHA256: String(repeating: "a", count: 64), launchExe: "C:\\Games\\Real Game\\Game.exe")
        let kinds = (shared.install ?? []).map { step -> String in
            switch step {
            case .winetricks: return "winetricks"
            case .download: return "download"
            case .runWindows: return "run"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["winetricks", "download", "run"], "Settings first, then the installer, which may keep running")
    }
}
