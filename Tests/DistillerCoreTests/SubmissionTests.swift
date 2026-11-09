import Foundation
import XCTest
@testable import DistillerCommunity
@testable import DistillerCore

final class SubmissionPlanTests: XCTestCase {
    let repository = CommunityRepository(owner: "distiller-org", name: "distiller-recipes", oauthClientID: "Iv1.example")

    static let installerURL = "https://cdn.example-publisher.com/RealGameSetup.exe"
    static let installerSHA = String(repeating: "ab", count: 32)

    /// A game whose community check passed (unless `checked` is false) for its current recipe.
    func makeGame(_ recipe: Recipe, played: Bool = true, checked: Bool = true) -> Game {
        var game = Game(id: "g", title: recipe.game.title, bottleID: "g", recipe: recipe, lastPlayedAt: played ? Date() : nil, authored: true)
        if checked, recipe.game.installer != nil,
           let shared = try? CommunityCheck.shareableRecipe(from: recipe, installerSHA256: Self.installerSHA, launchExe: "C:\\Program Files\\Real Game\\Game.exe") {
            game.communityCheck = CommunityCheckResult(
                checkedAt: Date(), recipe: shared, sourceFingerprint: CommunityCheck.fingerprint(recipe),
                installerSHA256: Self.installerSHA, hardwareKey: "M3-Pro-18gpu-18gb-macos27", wine: "wine-staging@11.21", graphics: nil
            )
        }
        return game
    }

    /// The player's own recipe: their folder, with the official installer recorded.
    func shareableRecipe() -> Recipe {
        var draft = RecipeDraft(source: .folder(URL(fileURLWithPath: "/Games/Real Game")), title: "Real Game")
        draft.launchProgram = "Game.exe"
        draft.notes = "GOG version 1.2."
        draft.publicInstallerURL = Self.installerURL
        return draft.makeRecipe()
    }

    func testPathsAndBranch() {
        let recipe = shareableRecipe()
        XCTAssertEqual(SubmissionPlan.recipePath(recipe), "recipes/real-game/d3dmetal.yaml")
        let date = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        let report = SubmissionPlan.reportPath(recipe, login: "Player_One", date: date)
        XCTAssertEqual(report, "reports/real-game/d3dmetal/player-one-20261106.yaml")
        let stem = URL(fileURLWithPath: report).deletingPathExtension().lastPathComponent
        XCTAssertTrue(RecipePolicy.isValidSlug(stem))
        XCTAssertEqual(SubmissionPlan.branchName(recipe), "recipe/real-game/d3dmetal")
        XCTAssertEqual(SubmissionPlan.branchName(recipe, attempt: 3), "recipe/real-game/d3dmetal-3")
    }

    func testAddsLoginToAuthorsOnce() {
        let prepared = SubmissionPlan.prepared(shareableRecipe(), login: "octocat")
        XCTAssertEqual(prepared.authors, ["octocat"])
        XCTAssertEqual(SubmissionPlan.prepared(prepared, login: "OctoCat").authors, ["octocat"])
    }

    func testCheckedRecipePasses() throws {
        let game = makeGame(shareableRecipe())
        let toSubmit = try XCTUnwrap(CommunityCheck.recipeToSubmit(for: game))
        XCTAssertEqual(SubmissionPlan.issues(for: game, recipe: toSubmit, repository: repository), [])
    }

    func testBlocksUnshareableRecipes() {
        var recipe = shareableRecipe()
        recipe.launch = nil
        recipe.game.slug = "example-thing"
        let placeholder = CommunityRepository(owner: "YOUR-GITHUB-USER", name: "distiller-recipes", oauthClientID: "YOUR-OAUTH-CLIENT-ID")
        let issues = SubmissionPlan.issues(for: makeGame(recipe, played: false, checked: false), recipe: recipe, repository: placeholder)
        let errors = issues.filter { $0.severity == .error }.map(\.message)
        XCTAssertTrue(errors.contains { $0.contains("isn't set up") }, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("program to launch") })
        XCTAssertTrue(errors.contains { $0.contains("community check") })
        XCTAssertTrue(errors.contains { $0.contains("example-") })
        XCTAssertTrue(issues.contains { $0.severity == .warning && $0.message.contains("haven't played") })
    }

    func testOfficialInstallerAndACurrentCheckAreRequired() {
        var noInstaller = shareableRecipe()
        noInstaller.game.installer = nil
        let missing = SubmissionPlan.issues(for: makeGame(noInstaller), recipe: noInstaller, repository: repository)
        XCTAssertTrue(missing.contains { $0.severity == .error && $0.message.contains("official public installer") }, "\(missing)")

        // Changing a setting after the check makes it out of date; changing the notes doesn't.
        var game = makeGame(shareableRecipe())
        game.recipe.notes = "Updated notes."
        XCTAssertTrue(CommunityCheck.isCurrent(game))
        XCTAssertEqual(CommunityCheck.recipeToSubmit(for: game)?.notes, "Updated notes.")
        game.recipe.prefix?.windows = "win7"
        XCTAssertFalse(CommunityCheck.isCurrent(game))
        XCTAssertNil(CommunityCheck.recipeToSubmit(for: game))
        let stale = SubmissionPlan.issues(for: game, recipe: game.recipe, repository: repository)
        XCTAssertTrue(stale.contains { $0.message.contains("changed since its community check") }, "\(stale)")
    }

    func testShareableRecipeInstallsFromTheOfficialInstaller() throws {
        var recipe = shareableRecipe()
        recipe.install = (recipe.install ?? []) + [.winetricks(["vcrun2022"]), .registry(RegistryEdit(key: "HKCU\\Software\\Wine", values: ["X": .string("1")]))]
        let shared = try CommunityCheck.shareableRecipe(from: recipe, installerSHA256: Self.installerSHA, launchExe: "C:\\Program Files\\Real Game\\Game.exe")
        // Settings first, then the official installer: downloaded, then run.
        guard case .download(let download)? = shared.install?.dropLast().last, case .runWindows(let run)? = shared.install?.last else {
            return XCTFail("\(String(describing: shared.install))")
        }
        XCTAssertEqual(download.url, Self.installerURL)
        XCTAssertEqual(download.sha256, Self.installerSHA)
        XCTAssertEqual(run.path, download.to)
        XCTAssertFalse(shared.install!.contains { if case .userFolder = $0 { return true }; return false }, "The player's own folder isn't shared")
        XCTAssertTrue(shared.install!.contains { if case .winetricks = $0 { return true }; return false }, "Settings steps are kept")
        XCTAssertEqual(shared.launch?.exe, "C:\\Program Files\\Real Game\\Game.exe")
        XCTAssertNoThrow(try RecipeLoader.validate(shared))

        // A shared recipe may download only the official installer.
        var sneaky = shared
        sneaky.install?.append(.download(.init(url: "https://mirror.example/Game.dat", sha256: Self.installerSHA, to: "cache/Game.dat")))
        let issues = SubmissionPlan.issues(for: makeGame(recipe), recipe: sneaky, repository: repository)
        XCTAssertTrue(issues.contains { $0.message.contains("only download the game's official installer") }, "\(issues)")
    }

    func testMSIInstallersRunThroughMsiexec() throws {
        let steps = try CommunityCheck.installerSteps(PublicInstaller(url: "https://cdn.example.com/Game.msi", args: ["/qn"]), sha256: Self.installerSHA)
        guard case .runWindows(let run)? = steps.last else { return XCTFail() }
        XCTAssertEqual(run.path, "C:\\windows\\system32\\msiexec.exe")
        XCTAssertEqual(run.args, ["/i", "C:\\Installers\\Game.msi", "/qn"])
        XCTAssertThrowsError(try CommunityCheck.installerSteps(PublicInstaller(url: "http://cdn.example.com/Game.exe"), sha256: Self.installerSHA))
    }

    func testReportYAMLKeepsVersionsAsText() throws {
        let yaml = try SubmissionPlan.reportYAML(
            ReportDraft(tier: .gold, averageFPS: 59.96, notes: "Smooth.", wineVersion: "wine-staging@11.17", graphicsVersion: nil),
            recipe: shareableRecipe(),
            hardware: Macs.m3Pro,
            date: ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        )
        XCTAssertTrue(yaml.contains("macos: '27.1'") || yaml.contains("macos: \"27.1\""), yaml)
        XCTAssertTrue(yaml.contains("date: '2026-11-06'") || yaml.contains("date: \"2026-11-06\"") || yaml.contains("date: 2026-11-06"), yaml)
        XCTAssertTrue(yaml.contains("fps_avg: 60\n"), yaml)
        XCTAssertTrue(yaml.contains("tier: gold"))
        XCTAssertFalse(yaml.contains("graphics:"))
    }

    func testPullRequestBodyMentionsReport() {
        let body = SubmissionPlan.pullRequestBody(shareableRecipe(), hardware: Macs.m1Air, report: ReportDraft(tier: .silver))
        XCTAssertTrue(body.contains("**Real Game**"))
        XCTAssertTrue(body.contains("Silver"))
        XCTAssertTrue(body.contains("MIT license"))
        XCTAssertFalse(body.contains("Nothing here downloads the game"), "Shared recipes install from the official installer")
        XCTAssertFalse(body.contains("from the community check:"))
        let withPictures = SubmissionPlan.pullRequestBody(shareableRecipe(), hardware: Macs.m1Air, report: nil, media: SubmissionMedia(screenshots: [Data([1]), Data([2])]))
        XCTAssertTrue(withPictures.contains("2 screenshots from the community check: `media/real-game/d3dmetal/1.jpg`, `media/real-game/d3dmetal/2.jpg`"))
    }

    func testPlaceholderRepositoryIsNotConfigured() {
        XCTAssertFalse(CommunityRepository(owner: "YOUR-GITHUB-USER", name: "distiller-recipes", oauthClientID: "YOUR-OAUTH-CLIENT-ID").isConfiguredForSubmissions)
        XCTAssertFalse(CommunityRepository(owner: "nullfx", name: "distiller-recipes", oauthClientID: "").isConfiguredForSubmissions)
        XCTAssertTrue(repository.isConfiguredForSubmissions)
    }

    func testShippedRepositoryIsConfigured() {
        XCTAssertTrue(CommunityRepository.default.isConfiguredForSubmissions)
        XCTAssertEqual(CommunityRepository.default.fullName, "nullfx/distiller-recipes")
        XCTAssertEqual(CommunityRepository.default.indexURL.absoluteString, "https://nullfx.github.io/distiller-recipes/index.json")
    }
}

/// Answers requests from a queue of canned responses.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let next = Self.responses.isEmpty ? (404, "{}") : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DeviceFlowTests: XCTestCase {
    override func setUp() {
        StubProtocol.responses = []
        StubProtocol.requests = []
    }

    func testWaitsThroughPendingAndSlowDown() async throws {
        StubProtocol.responses = [
            (200, #"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
            (200, #"{"error":"authorization_pending"}"#),
            (200, #"{"error":"slow_down","interval":10}"#),
            (200, #"{"access_token":"gho_token","token_type":"bearer","scope":"public_repo"}"#),
        ]
        let waits = WaitLog()
        let flow = GitHubDeviceFlow(clientID: "Iv1.example", session: StubProtocol.session()) { seconds in await waits.add(seconds) }
        let code = try await flow.start()
        XCTAssertEqual(code.userCode, "ABCD-1234")
        let token = try await flow.waitForToken(code)
        XCTAssertEqual(token, "gho_token")
        let recorded = await waits.values
        XCTAssertEqual(recorded, [5, 5, 10])
        let body = String(decoding: StubProtocol.requests.first.flatMap { $0.httpBodyStream.map(Self.read) ?? $0.httpBody } ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("scope=public_repo"), body)
    }

    func testDeniedSignIn() async throws {
        StubProtocol.responses = [(200, #"{"error":"access_denied"}"#)]
        let flow = GitHubDeviceFlow(clientID: "x", session: StubProtocol.session()) { _ in }
        let code = DeviceCode(deviceCode: "d", userCode: "u", verificationURI: URL(string: "https://github.com/login/device")!, expiresIn: 60, interval: 1)
        do {
            _ = try await flow.waitForToken(code)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? GitHubError, .signInDenied)
        }
    }

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

actor WaitLog {
    var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}
