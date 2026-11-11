import Foundation
import XCTest
@testable import DistillerCore

/// Distiller's own updates: which release, which download, and which app may replace this one.
final class AppUpdateTests: XCTestCase {
    override func setUp() {
        FakeReleases.responses = [:]
    }

    func release(tag: String, assets: [String]) -> String {
        let list = assets.map { #"{"name":"\#($0)","browser_download_url":"https://github.com/someone/distiller/releases/download/\#(tag)/\#($0)","size":52000000}"# }
        return #"{"tag_name":"\#(tag)","html_url":"https://github.com/someone/distiller/releases/tag/\#(tag)","draft":false,"prerelease":false,"assets":[\#(list.joined(separator: ","))]}"#
    }

    func testReadsTheLatestReleaseOfTheConfiguredRepository() async throws {
        // A fork's build asks its own repository.
        FakeReleases.responses["/repos/someone/distiller/releases/latest"] =
            release(tag: "v1.2.0", assets: ["Distiller-1.2.0.dmg", "Distiller.dmg", "SHA256SUMS.txt"])
        let latest = try await AppUpdater(repository: "someone/distiller", session: FakeReleases.session()).latestRelease()
        XCTAssertEqual(latest.version, "1.2.0")
        XCTAssertEqual(latest.diskImage.lastPathComponent, "Distiller.dmg")
        XCTAssertEqual(latest.checksums?.lastPathComponent, "SHA256SUMS.txt")
        XCTAssertEqual(latest.page.absoluteString, "https://github.com/someone/distiller/releases/tag/v1.2.0")
        XCTAssertEqual(latest.size, 52000000)
    }

    func testAReleaseWithoutTheDiskImageIsRefused() async {
        FakeReleases.responses["/repos/someone/distiller/releases/latest"] = release(tag: "v1.2.0", assets: ["notes.txt"])
        do {
            _ = try await AppUpdater(repository: "someone/distiller", session: FakeReleases.session()).latestRelease()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Distiller.dmg"), error.localizedDescription)
        }
    }

    func testRepositoryNamesAreValidated() {
        XCTAssertTrue(AppUpdater.isRepositoryName("nullfx/distiller"))
        XCTAssertTrue(AppUpdater.isRepositoryName("some-one/distiller.fork"))
        XCTAssertFalse(AppUpdater.isRepositoryName("nullfx"))
        XCTAssertFalse(AppUpdater.isRepositoryName("../../etc"))
        XCTAssertFalse(AppUpdater.isRepositoryName("a/b/c"))
        XCTAssertFalse(AppUpdater.isRepositoryName("a b/c"))
    }

    func testVersionsCompare() {
        XCTAssertTrue(AppUpdater.isNewer("1.1.0", than: "1.0.0"))
        XCTAssertTrue(AppUpdater.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(AppUpdater.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(AppUpdater.isNewer("0.9.0", than: "1.0.0"))
        XCTAssertFalse(AppUpdater.isNewer("9.0.0", than: DistillerVersion.development), "development builds never update")
    }

    func testFindsTheDiskImageInTheChecksums() {
        let sums = """
        dc47d80e00fe50a8ba22067bae81e963b1d9d2b8984c51c5823645da07782877  Distiller-1.0.0.dmg
        ab47d80e00fe50a8ba22067bae81e963b1d9d2b8984c51c5823645da07782877 *Distiller.dmg
        """
        XCTAssertEqual(AppUpdater.checksum(for: "Distiller.dmg", in: sums), "ab47d80e00fe50a8ba22067bae81e963b1d9d2b8984c51c5823645da07782877")
        XCTAssertNil(AppUpdater.checksum(for: "Other.dmg", in: sums))
        XCTAssertNil(AppUpdater.checksum(for: "Distiller.dmg", in: "nothex  Distiller.dmg"))
    }

    func testTheDownloadMustMatchItsChecksum() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        FakeReleases.responses = [
            "/someone/distiller/releases/download/v1.2.0/SHA256SUMS.txt": String(repeating: "0", count: 64) + "  Distiller.dmg\n",
            "/someone/distiller/releases/download/v1.2.0/Distiller.dmg": "not the published image",
        ]
        let release = AppRelease(
            version: "1.2.0", page: URL(string: "https://github.com/someone/distiller/releases/tag/v1.2.0")!,
            diskImage: URL(string: "https://github.com/someone/distiller/releases/download/v1.2.0/Distiller.dmg")!,
            checksums: URL(string: "https://github.com/someone/distiller/releases/download/v1.2.0/SHA256SUMS.txt")!, size: nil
        )
        do {
            _ = try await AppUpdater(repository: "someone/distiller", session: FakeReleases.session()).download(release, into: folder)
            XCTFail("expected a checksum error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Distiller.dmg").path))

        var unchecked = release
        unchecked.checksums = nil
        do {
            _ = try await AppUpdater(repository: "someone/distiller", session: FakeReleases.session()).download(unchecked, into: folder)
            XCTFail("a release without checksums must be refused")
        } catch {}
    }

    // MARK: Which app may replace this one

    let info: [String: Any] = ["CFBundleIdentifier": "com.nullfx.distiller", "DistillerVersion": "1.2.0"]

    func testOnlyTheSameTeamsBuildOfTheReleasedVersionPasses() throws {
        XCTAssertNoThrow(try AppBundleCheck.check(candidateInfo: info, currentInfo: info, version: "1.2.0", candidateTeam: "TEAM1", currentTeam: "TEAM1"))
        // Another team's build (a fork's, or anyone's) never replaces this copy.
        XCTAssertThrowsError(try AppBundleCheck.check(candidateInfo: info, currentInfo: info, version: "1.2.0", candidateTeam: "TEAM2", currentTeam: "TEAM1"))
        XCTAssertThrowsError(try AppBundleCheck.check(candidateInfo: info, currentInfo: info, version: "1.2.0", candidateTeam: nil, currentTeam: "TEAM1"))
        // An unsigned copy has nothing to compare against.
        XCTAssertThrowsError(try AppBundleCheck.check(candidateInfo: info, currentInfo: info, version: "1.2.0", candidateTeam: "TEAM1", currentTeam: nil))
        // Not the version the release says, or not this app.
        XCTAssertThrowsError(try AppBundleCheck.check(candidateInfo: info, currentInfo: info, version: "1.3.0", candidateTeam: "TEAM1", currentTeam: "TEAM1"))
        var other = info
        other["CFBundleIdentifier"] = "com.example.other"
        XCTAssertThrowsError(try AppBundleCheck.check(candidateInfo: other, currentInfo: info, version: "1.2.0", candidateTeam: "TEAM1", currentTeam: "TEAM1"))
    }

    func testAnAppInATranslocatedOrReadOnlyPlaceIsNotReplacedInPlace() throws {
        XCTAssertFalse(AppReplacer.canReplace(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Distiller.app")))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(AppReplacer.canReplace(folder.appendingPathComponent("Distiller.app")))
    }

    func testReplacingPutsTheNewCopyInPlaceAndTheOldInTheTrash() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-replace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = folder.appendingPathComponent("Applications/Distiller.app")
        let candidate = folder.appendingPathComponent("Volume/Distiller.app")
        for (app, text) in [(current, "old"), (candidate, "new")] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: app.appendingPathComponent("Contents/marker"))
        }
        let trashed = try await AppReplacer.replace(current, with: candidate)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("Contents/marker"), encoding: .utf8), "new")
        if let trashed {
            XCTAssertEqual(try String(contentsOf: trashed.appendingPathComponent("Contents/marker"), encoding: .utf8), "old")
            try? FileManager.default.removeItem(at: trashed)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: current.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["Distiller.app"], "no staged copy left behind")
    }
}
