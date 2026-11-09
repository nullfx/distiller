import Security
import XCTest
@testable import DistillerCommunity
@testable import DistillerCore

/// Installers with no direct link that works on its own: players download them from the
/// publisher's page (`user_download`, and installers with only `game.installer.page`).
final class PageDownloadTests: XCTestCase {
    let page = "https://www.example-publisher.com/download"
    let sha = String(repeating: "c", count: 64)

    func recipe(installer: PublicInstaller?) throws -> Recipe {
        var recipe = try loadFixtureRecipe("d3dmetal")
        recipe.game.installer = installer
        recipe.install = []
        return recipe
    }

    func userDownload(id: String = "installer", page: String? = nil, sha256: String? = nil, signer: String? = nil, to: String = "cache/Setup.exe") -> InstallStep {
        .userDownload(.init(id: id, prompt: "Download the installer.", page: page ?? self.page, sha256: sha256, signer: signer, to: to))
    }

    // MARK: The format

    func testAnInstallerNeedsALinkOrAPage() throws {
        var recipe = try recipe(installer: PublicInstaller(url: nil, page: nil))
        recipe.schema = 2
        XCTAssertThrowsError(try RecipeLoader.validate(recipe))
        recipe.game.installer = PublicInstaller(url: nil, page: "http://www.example-publisher.com/download")
        XCTAssertThrowsError(try RecipeLoader.validate(recipe), "The page must be https")
        recipe.game.installer = PublicInstaller(url: nil, page: page)
        XCTAssertNoThrow(try RecipeLoader.validate(recipe))
    }

    func testSchemaTwoForPageOnlyInstallersAndUserDownloads() throws {
        XCTAssertEqual(try recipe(installer: PublicInstaller(url: "https://cdn.example-publisher.com/Setup.exe", page: page)).requiredSchema, 1,
                       "A direct link with its page stays schema 1")
        var pageOnly = try recipe(installer: PublicInstaller(url: nil, page: page))
        XCTAssertEqual(pageOnly.requiredSchema, 2)
        XCTAssertThrowsError(try RecipeLoader.validate(pageOnly), "Older versions can't install it, so schema 1 can't say it")

        pageOnly.game.installer = nil
        pageOnly.install = [userDownload(sha256: sha)]
        XCTAssertEqual(pageOnly.requiredSchema, 2)
        XCTAssertThrowsError(try RecipeLoader.validate(pageOnly))
        pageOnly.schema = 2
        XCTAssertNoThrow(try RecipeLoader.validate(pageOnly))
    }

    func testUserDownloadsAreChecked() throws {
        var recipe = try recipe(installer: nil)
        recipe.schema = 2
        for (step, valid) in [
            (userDownload(sha256: sha), true),
            (userDownload(signer: "Example Publisher, Inc."), true),
            (userDownload(), false),
            (userDownload(sha256: sha, signer: "Example Publisher, Inc."), false),
            (userDownload(sha256: "abc"), false),
            (userDownload(id: "Not A Slug", sha256: sha), false),
            (userDownload(page: "http://www.example-publisher.com/download", sha256: sha), false),
            (userDownload(page: "file:///Users/someone/Setup.exe", sha256: sha), false),
            (userDownload(sha256: sha, to: "../../outside.exe"), false),
        ] {
            recipe.install = [step]
            if valid { XCTAssertNoThrow(try RecipeLoader.validate(recipe), "\(step)") } else { XCTAssertThrowsError(try RecipeLoader.validate(recipe), "\(step)") }
        }
    }

    func testUserDownloadsReadAndWriteAsYAML() throws {
        var recipe = try recipe(installer: PublicInstaller(url: nil, page: page))
        recipe.schema = 2
        recipe.install = [userDownload(signer: "Example Publisher, Inc.")]
        let yaml = try RecipeLoader.encode(recipe)
        XCTAssertTrue(yaml.contains("user_download:"), yaml)
        XCTAssertFalse(yaml.contains("url:"), "A page-only installer has no url: \(yaml)")
        XCTAssertEqual(try RecipeLoader.decode(yaml: yaml), recipe)
    }

    // MARK: Sharing

    func testSharedPageOnlyInstallersAreDownloadedFromThePage() throws {
        let source = try recipe(installer: PublicInstaller(url: nil, page: page, args: ["/S"]))
        let shared = try CommunityCheck.shareableRecipe(from: source, installerSHA256: sha, installerFileName: "Example Setup 1.2.exe", launchExe: "C:\\Games\\Example\\Game.exe")
        guard case .userDownload(let download)? = shared.install?.dropLast().last, case .runWindows(let run)? = shared.install?.last else {
            return XCTFail("\(String(describing: shared.install))")
        }
        XCTAssertEqual(download.id, CommunityCheck.installerDownloadID)
        XCTAssertEqual(download.page, page)
        XCTAssertEqual(download.sha256, sha)
        XCTAssertNil(download.signer)
        XCTAssertTrue(download.prompt.contains(source.game.title), download.prompt)
        XCTAssertEqual(run.path, download.to)
        XCTAssertEqual(run.args, ["/S"])
        XCTAssertEqual(shared.schema, 2)
        XCTAssertNoThrow(try RecipeLoader.validate(shared))

        let signed = try CommunityCheck.shareableRecipe(from: recipe(installer: PublicInstaller(url: nil, page: page, updates: true)),
                                                         installerSHA256: sha, installerSigner: "Example Publisher, Inc.", installerFileName: "Setup.exe", launchExe: nil)
        guard case .userDownload(let bySignature)? = signed.install?.dropLast().last else { return XCTFail() }
        XCTAssertEqual(bySignature.signer, "Example Publisher, Inc.")
        XCTAssertNil(bySignature.sha256, "The file changes with updates, so there's no checksum")
    }

    func testPageOnlyMSIInstallersRunThroughMsiexec() throws {
        let steps = try CommunityCheck.installerSteps(PublicInstaller(url: nil, page: page), sha256: sha, fileName: "Game.msi")
        guard case .userDownload(let download)? = steps.first, case .runWindows(let run)? = steps.last else { return XCTFail("\(steps)") }
        XCTAssertEqual(download.to, "C:\\Installers\\Game.msi")
        XCTAssertEqual(run.args, ["/i", "C:\\Installers\\Game.msi"])
    }

    func testADirectLinkWinsOverThePage() throws {
        let steps = try CommunityCheck.installerSteps(PublicInstaller(url: "https://cdn.example-publisher.com/Setup.exe", page: page), sha256: sha, fileName: "Other.exe")
        guard case .download(let download)? = steps.first else { return XCTFail("\(steps)") }
        XCTAssertEqual(download.to, "cache/Setup.exe")
    }

    func testSharedRecipesDownloadOnlyFromTheInstallersPage() throws {
        let repository = CommunityRepository(owner: "distiller-org", name: "distiller-recipes", oauthClientID: "Iv1.example")
        var source = try recipe(installer: PublicInstaller(url: nil, page: page))
        source.schema = 2
        let shared = try CommunityCheck.shareableRecipe(from: source, installerSHA256: sha, installerFileName: "Setup.exe", launchExe: "C:\\Game.exe")
        var game = Game(id: "g", title: source.game.title, bottleID: "g", recipe: source, lastPlayedAt: Date(), authored: true)
        game.communityCheck = CommunityCheckResult(
            checkedAt: Date(), recipe: shared, sourceFingerprint: CommunityCheck.fingerprint(source),
            installerSHA256: sha, hardwareKey: "M3-Pro-18gpu-18gb-macos27", wine: "wine-staging@11.21", graphics: nil)
        let onlyThePage = "only download the game's official installer"
        XCTAssertFalse(SubmissionPlan.issues(for: game, recipe: shared, repository: repository).contains { $0.message.contains(onlyThePage) })

        var elsewhere = shared
        elsewhere.install?.insert(userDownload(id: "data", page: "https://mirror.example/files", sha256: sha, to: "cache/Data.zip"), at: 0)
        XCTAssertTrue(SubmissionPlan.issues(for: game, recipe: elsewhere, repository: repository).contains { $0.message.contains(onlyThePage) })
    }

    func testTheCatalogueListsADownloadPageSeparately() throws {
        // build_index.py publishes an installer with only a page as download_page, because
        // Distiller 1.0 needs every installer in the index to have a url.
        let json = #"{"slug": "real-game", "title": "Real Game", "recipes": [], "download_page": "https://www.example-publisher.com/download", "download_page_updates": true}"#
        let game = try JSONDecoder().decode(IndexGame.self, from: Data(json.utf8))
        XCTAssertNil(game.installer)
        XCTAssertEqual(game.officialInstaller, PublicInstaller(url: nil, page: page, updates: true))
        let direct = #"{"slug": "real-game", "title": "Real Game", "recipes": [], "installer": {"url": "https://cdn.example-publisher.com/Setup.exe"}}"#
        XCTAssertEqual(try JSONDecoder().decode(IndexGame.self, from: Data(direct.utf8)).officialInstaller?.url, "https://cdn.example-publisher.com/Setup.exe")
    }

    // MARK: Installing

    func temporaryFile(_ data: Data, name: String = "Setup.exe") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return file
    }

    func testTheDownloadedFileIsCheckedByChecksum() throws {
        let data = Data("an installer".utf8)
        let file = try temporaryFile(data)
        let right = try Checksum.sha256(of: file)
        XCTAssertNoThrow(try RecipeInstaller.checkPageDownload(file, for: .init(id: "installer", prompt: "", page: page, sha256: right, to: "cache/Setup.exe")))
        XCTAssertThrowsError(try RecipeInstaller.checkPageDownload(file, for: .init(id: "installer", prompt: "", page: page, sha256: sha, to: "cache/Setup.exe")))
    }

    func testTheDownloadedFileIsCheckedBySignature() throws {
        let file = try temporaryFile(try Data(contentsOf: fixtureURL("authenticode-signed", "exe")))
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: fixtureURL("authenticode-root", "cer")) as CFData))
        XCTAssertNoThrow(try RecipeInstaller.verify(file, sha256: nil, signer: "Distiller Test Publisher", anchors: [root]))
        XCTAssertThrowsError(try RecipeInstaller.verify(file, sha256: nil, signer: "Example Publisher, Inc.", anchors: [root]))
        XCTAssertThrowsError(try RecipeInstaller.verify(file, sha256: nil, signer: "Distiller Test Publisher", anchors: nil),
                             "The test root isn't trusted by macOS")
    }

    func testPageDownloadsListWhatToAskFor() throws {
        var recipe = try recipe(installer: nil)
        recipe.install = [.winetricks(["vcrun2022"]), userDownload(sha256: sha), userDownload(id: "data", sha256: sha, to: "cache/Data.zip")]
        let downloads = RecipeInstaller.pageDownloads(in: recipe)
        XCTAssertEqual(downloads.map(\.step.id), ["installer", "data"])
        XCTAssertEqual(downloads.first?.request.page.absoluteString, page)
        XCTAssertEqual(downloads.first?.request.title, recipe.game.title)
    }
}
