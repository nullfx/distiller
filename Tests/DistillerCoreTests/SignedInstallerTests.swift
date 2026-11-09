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

    func testADownloadNeedsExactlyOneWayToBeChecked() throws {
        var recipe = try recipe(updates: false)
        recipe.schema = 2
        let target = "cache/Setup.exe"
        for (step, valid) in [
            (InstallStep.Download(url: installerURL, sha256: String(repeating: "a", count: 64), to: target), true),
            (InstallStep.Download(url: installerURL, signer: "Example Publisher, Inc.", to: target), true),
            (InstallStep.Download(url: installerURL, sha256: String(repeating: "a", count: 64), signer: "Example Publisher, Inc.", to: target), false),
            (InstallStep.Download(url: installerURL, to: target), false),
            (InstallStep.Download(url: installerURL, signer: " Example", to: target), false),
            (InstallStep.Download(url: installerURL, signer: "Example\nPublisher", to: target), false),
        ] {
            recipe.install = [.download(step)]
            if valid { XCTAssertNoThrow(try RecipeLoader.validate(recipe), "\(step)") } else { XCTAssertThrowsError(try RecipeLoader.validate(recipe), "\(step)") }
        }
    }

    func testSharedRecipesUseTheSignerAndSchemaTwo() throws {
        let sha = String(repeating: "b", count: 64)
        let shared = try CommunityCheck.shareableRecipe(from: recipe(updates: true), installerSHA256: sha, installerSigner: "Example Publisher, Inc.", launchExe: "C:\\Program Files\\Example\\Launcher.exe")
        guard case .download(let download)? = shared.install?.dropLast().last else { return XCTFail("\(String(describing: shared.install))") }
        XCTAssertEqual(download.signer, "Example Publisher, Inc.")
        XCTAssertNil(download.sha256, "No checksum: the file changes with updates")
        XCTAssertEqual(shared.schema, 2)
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
}
