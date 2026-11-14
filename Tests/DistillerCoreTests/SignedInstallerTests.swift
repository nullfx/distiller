import Security
import XCTest
@testable import DistillerCore

/// Installers that change with every update, verified by their publisher's signature.
final class SignedInstallerTests: XCTestCase {
    let installerURL = "https://downloads.example-publisher.com/download/getInstaller?os=win"

    func recipe(updates: Bool) throws -> Recipe {
        var recipe = try loadFixtureRecipe("d3dmetal")
        recipe.game.installer = PublicInstaller(url: installerURL, updates: updates ? true : nil)
        recipe.install = []
        return recipe
    }

    func testSchemaTwoOnlyWhenASignatureIsUsed() throws {
        XCTAssertEqual(try recipe(updates: false).requiredSchema, 1)
        XCTAssertEqual(try recipe(updates: true).requiredSchema, 2)

        var signed = try recipe(updates: true)
        XCTAssertThrowsError(try RecipeLoader.validate(signed), "Schema 1 can't use it, so older versions refuse it cleanly")
        signed.schema = 2
        XCTAssertNoThrow(try RecipeLoader.validate(signed))
    }

    func testADownloadNeedsAWayToBeChecked() throws {
        var recipe = try recipe(updates: false)
        recipe.schema = 3
        let target = "cache/Setup.exe"
        for (step, valid) in [
            (InstallStep.Download(url: installerURL, sha256: String(repeating: "a", count: 64), to: target), true),
            (InstallStep.Download(url: installerURL, signer: "Example Publisher, Inc.", to: target), true),
            (InstallStep.Download(url: installerURL, sha256: String(repeating: "a", count: 64), signer: "Example Publisher, Inc.", to: target), true),
            (InstallStep.Download(url: installerURL, sha256: "short", signer: "Example Publisher, Inc.", to: target), false),
            (InstallStep.Download(url: installerURL, to: target), false),
            (InstallStep.Download(url: installerURL, signer: " Example", to: target), false),
            (InstallStep.Download(url: installerURL, signer: "Example\nPublisher", to: target), false),
        ] {
            recipe.install = [.download(step)]
            if valid { XCTAssertNoThrow(try RecipeLoader.validate(recipe), "\(step)") } else { XCTAssertThrowsError(try RecipeLoader.validate(recipe), "\(step)") }
        }
    }

    func testSharedRecipesCarryTheChecksumAndTheSigner() throws {
        let sha = String(repeating: "b", count: 64)
        let shared = try CommunityCheck.shareableRecipe(from: recipe(updates: true), installerSHA256: sha, installerSigner: "Example Publisher, Inc.", launchExe: "C:\\Program Files\\Example\\Launcher.exe")
        guard case .download(let download)? = shared.install?.dropLast().last else { return XCTFail("\(String(describing: shared.install))") }
        XCTAssertEqual(download.signer, "Example Publisher, Inc.")
        XCTAssertEqual(download.sha256, sha, "Both: the checksum while the file is unchanged, the signer after")
        XCTAssertEqual(shared.schema, 3)
        XCTAssertNoThrow(try RecipeLoader.validate(shared))
        let yaml = try RecipeLoader.encode(shared)
        XCTAssertTrue(yaml.contains("signer: Example Publisher, Inc.") && yaml.contains("updates: true"), yaml)
        XCTAssertEqual(try RecipeLoader.decode(yaml: yaml), shared)

        let fixed = try CommunityCheck.shareableRecipe(from: recipe(updates: false), installerSHA256: sha, launchExe: "C:\\Game.exe")
        XCTAssertEqual(fixed.schema, 1, "Recipes that don't need schema 2 stay readable by older versions")
    }

    // MARK: Downloading

    func root() throws -> SecCertificate {
        try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: fixtureURL("authenticode-root", "cer")) as CFData))
    }

    func download(signer: String, anchors: [SecCertificate]?) async throws -> URL {
        let url = URL(string: "https://downloads.example-publisher.com/Setup.exe")!
        FakeDownloads.routes = [url.absoluteString: .init(body: try Data(contentsOf: fixtureURL("authenticode-signed", "exe")))]
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Setup.exe")
        try await Downloader.download(url, signer: signer, to: destination, session: FakeDownloads.session(), anchors: anchors)
        return destination
    }

    func testDownloadsCheckTheSignatureBeforeKeepingTheFile() async throws {
        let kept = try await download(signer: "Distiller Test Publisher", anchors: [root()])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        try? FileManager.default.removeItem(at: kept.deletingLastPathComponent())

        do {
            _ = try await download(signer: "Example Publisher, Inc.", anchors: [root()])
            XCTFail("A different signer must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Distiller Test Publisher"), error.localizedDescription)
        }
        do {
            _ = try await download(signer: "Distiller Test Publisher", anchors: nil)
            XCTFail("An untrusted certificate must be refused")
        } catch {}
    }

    func testSchemaThreeWhenADownloadHasBothChecks() throws {
        var recipe = try recipe(updates: false)
        recipe.install = [.download(.init(url: installerURL, sha256: String(repeating: "a", count: 64), signer: "Example Publisher, Inc.", to: "cache/Setup.exe"))]
        XCTAssertEqual(recipe.requiredSchema, 3)
        recipe.schema = 2
        XCTAssertThrowsError(try RecipeLoader.validate(recipe), "Distiller 1.1 would refuse both, so it's schema 3")
        recipe.install = [.userDownload(.init(id: "installer", prompt: "Download it", page: "https://example.com/download",
                                              sha256: String(repeating: "a", count: 64), signer: "Example Publisher, Inc.", to: "cache/Setup.exe"))]
        XCTAssertEqual(recipe.requiredSchema, 3)
    }

    // MARK: Either check passes

    func testEitherCheckIsEnough() throws {
        let program = try fixtureURL("authenticode-signed", "exe")
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: fixtureURL("authenticode-root", "cer")) as CFData))
        let right = try Checksum.sha256(of: program)
        let wrong = String(repeating: "0", count: 64)
        func check(_ sha256: String?, _ signer: String?) throws -> InstallerCheck.Passed {
            try InstallerCheck.verify(program, sha256: sha256, signer: signer, anchors: [root])
        }
        XCTAssertEqual(try check(right, nil), .checksum)
        XCTAssertEqual(try check(right, "Distiller Test Publisher"), .checksum, "The checksum is tried first")
        XCTAssertEqual(try check(right, "Someone Else"), .checksum, "A matching checksum is enough on its own")
        XCTAssertEqual(try check(nil, "Distiller Test Publisher"), .signer(changed: false))
        let changed = try check(wrong, "Distiller Test Publisher")
        XCTAssertEqual(changed, .signer(changed: true), "A new installer from the same publisher")
        XCTAssertTrue(changed.installerChanged)
        XCTAssertThrowsError(try check(wrong, nil))
        XCTAssertThrowsError(try check(wrong, "Someone Else")) { error in
            XCTAssertTrue(error.localizedDescription.contains("checksum") && error.localizedDescription.contains("Someone Else"), error.localizedDescription)
        }
        XCTAssertThrowsError(try check(nil, nil))
    }
}
