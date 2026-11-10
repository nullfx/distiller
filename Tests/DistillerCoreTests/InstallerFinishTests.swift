import XCTest
@testable import DistillerCore

/// When an install is done: installers that leave a launcher (or the game) running, and
/// installers that close without installing anything.
final class InstallerFinishTests: XCTestCase {
    let driveC = URL(fileURLWithPath: "/bottles/test/prefix/drive_c", isDirectory: true)

    func running(_ windowsPaths: [String]) -> [ProgramInBottle] {
        CommunityCheckSession.programs(from: windowsPaths.enumerated().map { RunningWindowsProgram(pid: $0 + 100, windowsPath: $1) }, driveC: driveC)
    }

    func testALauncherFromTheGamesFolderEndsTheWait() {
        let game = driveC.appendingPathComponent("Program Files (x86)/Battle.net/Battle.net Launcher.exe")
        let launcher = RecipeInstaller.programStartedByInstaller(
            running(["C:\\users\\player\\Temp\\Battle.net-Setup.exe", "C:\\Program Files (x86)\\Battle.net\\Battle.net.exe"]), gameProgram: game)
        XCTAssertEqual(launcher?.windowsPath, "C:\\Program Files (x86)\\Battle.net\\Battle.net.exe")
        XCTAssertNotNil(RecipeInstaller.programStartedByInstaller(running(["C:\\Program Files (x86)\\Battle.net\\Battle.net Launcher.exe"]), gameProgram: game),
                        "The game's own program counts too")
    }

    func testInstallersStillRunningKeepTheWaitGoing() {
        let game = driveC.appendingPathComponent("Games/Example/Game.exe")
        for paths in [
            ["C:\\cache\\setup.exe"],                                   // the installer itself
            ["C:\\Games\\Example\\unins000.exe"],                       // in the folder, but an (un)installer
            ["C:\\Games\\Example\\Setup Helper.exe"],
            ["C:\\Games\\Example\\_CommonRedist\\DXSETUP.exe"],         // a runtime's installer in a subfolder
            ["C:\\Games\\Other\\Game.exe"],                             // another folder
            ["C:\\windows\\system32\\explorer.exe"],                    // Wine's own
        ] {
            XCTAssertNil(RecipeInstaller.programStartedByInstaller(running(paths), gameProgram: game), "\(paths)")
        }
    }

    func testAMissingLaunchProgramIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var recipe = try loadFixtureRecipe("d3dmetal")
        recipe.launch = LaunchSpec(exe: "C:\\Program Files\\Example\\Game.exe", args: nil, workingDir: nil)
        let resolved = RecipeResolver.resolve(recipe, for: Macs.m3Pro)
        XCTAssertEqual(DistillerEngine.missingLaunchProgram(resolved, root: root), "C:\\Program Files\\Example\\Game.exe")

        let program = try BottlePath.resolve("C:\\Program Files\\Example\\Game.exe", in: root)
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: program)
        XCTAssertNil(DistillerEngine.missingLaunchProgram(resolved, root: root))

        recipe.launch = nil
        XCTAssertNil(DistillerEngine.missingLaunchProgram(RecipeResolver.resolve(recipe, for: Macs.m3Pro), root: root),
                     "Nothing to check without a launch program (chosen after the install)")
    }

    // MARK: Installers run from the Windows drive

    func testInstallersOutsideDriveCRunFromTheUsersDownloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-onc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix")
        let user = prefix.appendingPathComponent("drive_c/users/player")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let cached = root.appendingPathComponent("cache/Setup.exe")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("setup".utf8).write(to: cached)

        let staged = try RecipeInstaller.onDriveC(cached, prefix: prefix, environment: ["USER": "player"])
        XCTAssertEqual(staged.standardizedFileURL.path, user.appendingPathComponent("Downloads/Setup.exe").standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: staged), Data("setup".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path), "the cached installer stays for next time")
        // Again (a retry) replaces the copy.
        XCTAssertEqual(try RecipeInstaller.onDriveC(cached, prefix: prefix, environment: ["USER": "player"]), staged)

        // No such Windows user yet: the Public profile.
        let other = try RecipeInstaller.onDriveC(cached, prefix: prefix, environment: ["USER": "nobody"])
        XCTAssertTrue(other.path.hasSuffix("drive_c/users/Public/Downloads/Setup.exe"), other.path)
    }

    func testProgramsOnDriveCRunWhereTheyAre() throws {
        let prefix = URL(fileURLWithPath: "/bottles/test/prefix")
        let msiexec = prefix.appendingPathComponent("drive_c/windows/system32/msiexec.exe")
        XCTAssertEqual(try RecipeInstaller.onDriveC(msiexec, prefix: prefix, environment: [:]), msiexec)
        let installer = prefix.appendingPathComponent("drive_c/Installers/Game.exe")
        XCTAssertEqual(try RecipeInstaller.onDriveC(installer, prefix: prefix, environment: [:]), installer)
    }
}
