import Foundation
import XCTest
@testable import DistillerCore

final class StorageLocationTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    func testDefaultsToSupportFolder() {
        let paths = DistillerPaths(root: work, storage: StorageSettings())
        XCTAssertEqual(paths.components.path, work.appendingPathComponent("Components").path)
        XCTAssertEqual(paths.bottles.path, work.appendingPathComponent("Bottles").path)
        XCTAssertEqual(paths.templates.path, work.appendingPathComponent("Templates").path)
        XCTAssertTrue(paths.unavailable.isEmpty)
    }

    func testChosenLocationsKeepTemplatesWithBottles() {
        let settings = StorageSettings(wineLocation: "/Volumes/Fast/Distiller", bottlesLocation: "/Volumes/Big/Distiller")
        let paths = DistillerPaths(root: work, storage: settings)
        XCTAssertEqual(paths.components.path, "/Volumes/Fast/Distiller/Components")
        XCTAssertEqual(paths.composedComponents.path, "/Volumes/Fast/Distiller/Components/_composed")
        XCTAssertEqual(paths.bottles.path, "/Volumes/Big/Distiller/Bottles")
        XCTAssertEqual(paths.templates.path, "/Volumes/Big/Distiller/Templates")
        // Small files stay in the support folder, so Distiller starts without the drives.
        XCTAssertEqual(paths.libraryFile.path, work.appendingPathComponent("library.json").path)
        XCTAssertEqual(paths.logs.path, work.appendingPathComponent("Logs").path)
    }

    func testDisconnectedDriveIsReportedAndNotCreated() throws {
        let drive = "distiller-missing-\(UUID().uuidString.prefix(8))"
        let settings = StorageSettings(bottlesLocation: "/Volumes/\(drive)/Distiller")
        let paths = DistillerPaths(root: work, storage: settings)

        XCTAssertEqual(paths.unavailable.map(\.kind), [.bottles])
        XCTAssertEqual(paths.unavailable.first?.volumeName, drive)
        XCTAssertThrowsError(try paths.requireAvailable(.bottles))
        XCTAssertNoThrow(try paths.requireAvailable(.wine))
        XCTAssertNoThrow(try paths.ensureDirectories())
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Volumes/\(drive)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.components.path))
        XCTAssertNil(StorageVolume(containing: URL(fileURLWithPath: "/Volumes/\(drive)/Distiller")))
    }

    func testSettingsRoundTrip() throws {
        let settings = StorageSettings(wineLocation: "/Volumes/A/Distiller", bottlesLocation: nil, locationsConfirmed: true)
        try settings.save(toSupportFolder: work)
        XCTAssertEqual(StorageSettings.load(fromSupportFolder: work), settings)
        let json = try String(contentsOf: work.appendingPathComponent(StorageSettings.fileName), encoding: .utf8)
        XCTAssertTrue(json.contains("\"wine_location\""))
        XCTAssertEqual(DistillerPaths(root: work).storage, settings)
    }

    func testVolumeRootGetsDistillerFolder() {
        XCTAssertEqual(StorageSettings.storageFolder(forChoice: URL(fileURLWithPath: "/")).path, "/Distiller")
        XCTAssertEqual(StorageSettings.storageFolder(forChoice: work).path, work.standardizedFileURL.path)
    }

    func testStartupDiskIsUsable() throws {
        let volume = try XCTUnwrap(StorageVolume(containing: work))
        XCTAssertTrue(volume.isStartupDisk)
        XCTAssertTrue(volume.problems.isEmpty, volume.problems.joined())
        XCTAssertNotNil(volume.availableBytes)
    }

    func testFormatRules() {
        func volume(_ format: String, caseSensitive: Bool = false) -> StorageVolume {
            StorageVolume(root: URL(fileURLWithPath: "/Volumes/X"), name: "X", format: format, isStartupDisk: false,
                          isInternal: false, isCaseSensitive: caseSensitive, supportsCloning: format == "APFS", availableBytes: nil)
        }
        XCTAssertTrue(volume("APFS").problems.isEmpty)
        XCTAssertTrue(volume("Mac OS Extended (Journaled)").problems.isEmpty)
        XCTAssertFalse(volume("Mac OS Extended (Journaled)").warnings.isEmpty)
        XCTAssertFalse(volume("ExFAT").problems.isEmpty)
        XCTAssertFalse(volume("MS-DOS (FAT32)").problems.isEmpty)
        XCTAssertFalse(volume("APFS", caseSensitive: true).problems.isEmpty)
    }

    func testMoveBottlesWithinOneDrive() async throws {
        let support = work.appendingPathComponent("support", isDirectory: true)
        let paths = DistillerPaths(root: support, storage: StorageSettings())
        try paths.ensureDirectories()
        let marker = paths.bottles.appendingPathComponent("game-1/prefix/drive_c/file.txt")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            atPath: paths.bottles.appendingPathComponent("game-1/prefix/c:").path, withDestinationPath: "drive_c"
        )

        let target = work.appendingPathComponent("elsewhere", isDirectory: true)
        let settings = try await DistillerEngine.moveStorage(.bottles, to: target, paths: paths)

        XCTAssertEqual(settings.bottlesLocation, target.standardizedFileURL.path)
        XCTAssertNil(settings.wineLocation)
        XCTAssertEqual(settings.locationsConfirmed, true)
        let moved = DistillerPaths(root: support)
        XCTAssertEqual(moved.bottles.path, target.appendingPathComponent("Bottles").standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: moved.bottles.appendingPathComponent("game-1/prefix/drive_c/file.txt"), encoding: .utf8), "save")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: moved.bottles.appendingPathComponent("game-1/prefix/c:").path), "drive_c")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottles.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.templates.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.components.path), "Wine stays where it was")

        // Moving back to the support folder clears the setting.
        let back = try await DistillerEngine.moveStorage(.bottles, to: support, paths: moved)
        XCTAssertNil(back.bottlesLocation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMoveRefusesFolderThatAlreadyHasBottles() async throws {
        let paths = DistillerPaths(root: work.appendingPathComponent("support"), storage: StorageSettings())
        try paths.ensureDirectories()
        let target = work.appendingPathComponent("taken", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Bottles/other"), withIntermediateDirectories: true)

        do {
            try await DistillerEngine.moveStorage(.bottles, to: target, paths: paths)
            XCTFail("Expected the move to be refused")
        } catch DistillerError.storageNotUsable(let message) {
            XCTAssertTrue(message.contains("isn't empty"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.bottles.path))
    }
}

final class DriveMapperTests: XCTestCase {
    private var prefix: URL!

    override func setUpWithError() throws {
        prefix = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-drives-\(UUID().uuidString)", isDirectory: true)
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        // What wineboot leaves on a Mac with a disk image and an ExFAT card mounted.
        for (name, target) in [("c:", "../drive_c"), ("z:", "/"), ("d:", "/Volumes/SomeInstaller"), ("d::", "/dev/rdisk9s1"),
                               ("e:", "/Volumes/storage"), ("e::", "/dev/rdisk6s3")] {
            try FileManager.default.createSymbolicLink(atPath: dosdevices.appendingPathComponent(name).path, withDestinationPath: target)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: prefix)
    }

    func testReadsWineDynamicDrives() {
        let mappings = DriveMapper.mappings(in: prefix)
        XCTAssertEqual(mappings.map(\.letter), ["c", "d", "e", "z"])
        XCTAssertEqual(mappings.filter(\.isDynamic).map(\.letter), ["d", "e"])
    }

    func testFirstVolumeGetsDThenE() throws {
        let first = try DriveMapper.ensureDrive(for: URL(fileURLWithPath: "/Volumes/big-drive1"), in: prefix)
        let second = try DriveMapper.ensureDrive(for: URL(fileURLWithPath: "/Volumes/big-drive2"), in: prefix)
        XCTAssertEqual(first, "d")
        XCTAssertEqual(second, "e")
        let dosdevices = prefix.appendingPathComponent("dosdevices")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dosdevices.appendingPathComponent("d:").path), "/Volumes/big-drive1")
        XCTAssertFalse(APFSClone.isSymlink(dosdevices.appendingPathComponent("d::")), "Wine's device link for the old D: is gone")
        XCTAssertEqual(DriveMapper.mappings(in: prefix).filter { !$0.isDynamic }.map(\.letter), ["c", "d", "e", "z"])
    }

    func testSameVolumeKeepsItsLetter() throws {
        let volume = URL(fileURLWithPath: "/Volumes/big-drive1")
        XCTAssertEqual(try DriveMapper.ensureDrive(for: volume, in: prefix), "d")
        XCTAssertEqual(try DriveMapper.ensureDrive(for: URL(fileURLWithPath: "/Volumes/big-drive1/"), in: prefix), "d")
        XCTAssertEqual(try DriveMapper.ensureDrive(for: URL(fileURLWithPath: "/Volumes/big-drive2"), in: prefix), "e")
    }

    func testRunsOutAtY() throws {
        for index in 0..<DriveMapper.assignableLetters.count {
            try DriveMapper.ensureDrive(for: URL(fileURLWithPath: "/Volumes/v\(index)"), in: prefix)
        }
        XCTAssertThrowsError(try DriveMapper.ensureDrive(for: URL(fileURLWithPath: "/Volumes/one-too-many"), in: prefix))
        XCTAssertTrue(DriveMapper.mappings(in: prefix).contains { $0.letter == "z" && $0.target == "/" }, "Z: is never taken")
    }

    func testWindowsPathOnMappedDrive() {
        XCTAssertEqual(
            DriveMapper.windowsPath(of: URL(fileURLWithPath: "/Volumes/big-drive/GW2"), onDrive: "d", volumeRoot: URL(fileURLWithPath: "/Volumes/big-drive")),
            "D:\\GW2"
        )
        XCTAssertEqual(
            DriveMapper.windowsPath(of: URL(fileURLWithPath: "/Volumes/big/games/my game"), onDrive: "e", volumeRoot: URL(fileURLWithPath: "/Volumes/big")),
            "E:\\games\\my game"
        )
    }

    func testStartupDiskFolderIsNotMapped() throws {
        XCTAssertNil(try DriveMapper.mapVolume(of: FileManager.default.temporaryDirectory, in: prefix))
        XCTAssertEqual(DriveMapper.mappings(in: prefix).filter { !$0.isDynamic }.map(\.letter), ["c", "z"])
    }

    func testTemplateLosesWineDynamicDrives() throws {
        try DriveMapper.removeDynamicDrives(in: prefix)
        XCTAssertEqual(DriveMapper.mappings(in: prefix).map(\.letter), ["c", "z"])
        let names = try FileManager.default.contentsOfDirectory(atPath: prefix.appendingPathComponent("dosdevices").path).sorted()
        XCTAssertEqual(names, ["c:", "z:"])
    }
}

final class FolderInPlaceTests: XCTestCase {
    private var work: URL!
    private var engine: DistillerEngine!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-inplace-\(UUID().uuidString)", isDirectory: true)
        engine = try DistillerEngine(paths: DistillerPaths(root: work, storage: StorageSettings()), hardware: Macs.m3Pro)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func makeGame(copying original: URL) throws -> Game {
        var draft = RecipeDraft(source: .folder(original), title: "Example")
        draft.launchProgram = "Game.exe"
        let recipe = draft.makeRecipe()
        let bottle = Bottle(id: "example-1", name: "Example", wine: "wine@11", createdAt: Date())
        try FileManager.default.createDirectory(at: engine.bottles.prefix(of: bottle).appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        let game = Game(id: bottle.id, title: "Example", bottleID: bottle.id, recipe: recipe)
        try engine.library.upsert(game)
        let copy = try engine.userFolderLocation(of: game).url
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: copy)
        return game
    }

    private func makeOriginal() throws -> URL {
        let original = work.appendingPathComponent("Original Game", isDirectory: true)
        try FileManager.default.createDirectory(at: original.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: original.appendingPathComponent("Game.exe"))
        try Data(repeating: 1, count: 4096).write(to: original.appendingPathComponent("data/pack.dat"))
        return original
    }

    func testMatchingCopyIsReplacedByLink() throws {
        let original = try makeOriginal()
        let game = try makeGame(copying: original)

        let comparison = try engine.compareFolderCopy(of: game, with: original)
        XCTAssertTrue(comparison.matches)
        XCTAssertTrue(comparison.onlyInOriginal.isEmpty)

        let path = try engine.useFolderInPlace(for: game, original: original)
        let copy = try engine.userFolderLocation(of: game).url
        XCTAssertTrue(APFSClone.isSymlink(copy))
        XCTAssertEqual(copy.resolvingSymlinksInPath().path, original.resolvingSymlinksInPath().path)
        // The original is on the startup disk, so no drive letter is added.
        XCTAssertEqual(path, "C:\\Games\\Example")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("data/pack.dat").path), "The original is untouched")
    }

    func testCopyChangesAreReported() throws {
        let original = try makeOriginal()
        let game = try makeGame(copying: original)
        let copy = try engine.userFolderLocation(of: game).url
        try Data("progress".utf8).write(to: copy.appendingPathComponent("save.sav"))
        try Data(repeating: 2, count: 10).write(to: copy.appendingPathComponent("data/pack.dat"))
        try Data("new".utf8).write(to: original.appendingPathComponent("patch.txt"))

        let comparison = try engine.compareFolderCopy(of: game, with: original)
        XCTAssertFalse(comparison.matches)
        XCTAssertEqual(comparison.onlyInCopy, ["data/pack.dat", "save.sav"])
        XCTAssertEqual(comparison.onlyInOriginal, ["patch.txt"])
    }
}
