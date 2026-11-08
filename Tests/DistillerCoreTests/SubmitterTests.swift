import Foundation
import XCTest
@testable import DistillerCommunity
@testable import DistillerCore

/// A small in-memory GitHub that answers the REST calls `RecipeSubmitter` makes, by route.
final class FakeGitHub: URLProtocol {
    struct State {
        var login = "octocat"
        var canPush = false
        var forkExists = false
        /// Paths that exist on the community repository's main branch.
        var upstreamFiles: Set<String> = []
        /// Authors of the published recipe, served as its file contents.
        var publishedAuthors: [String] = []
        var refs: [String: [String: String]] = ["nullfx/distiller-recipes": ["main": "base-sha"]]
        var openPullRequests: Set<Int> = []
        /// Recorded writes: "METHOD /path".
        var writes: [String] = []
        var treeFiles: [String] = []
        /// Tree entries that point at an uploaded blob rather than inline text.
        var treeBlobFiles: [String] = []
        /// Tree entries that remove a file (`sha: null`).
        var treeDeletedFiles: [String] = []
        /// Decoded contents of each uploaded blob, in order.
        var blobs: [Data] = []
        var pullRequestBody: [String: Any] = [:]
    }

    nonisolated(unsafe) static var state = State()
    static let upstream = "nullfx/distiller-recipes"
    static var fork: String { "\(state.login)/distiller-recipes" }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeGitHub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let body = Self.body(of: request)
        let (status, json) = Self.route(method, path, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func repositoryJSON(_ fullName: String, fork: Bool) -> String {
        let owner = fullName.split(separator: "/").first ?? ""
        let parent = fork ? #","parent":{"full_name":"\#(upstream)"}"# : ""
        let permissions = fullName == upstream ? #","permissions":{"admin":false,"push":\#(state.canPush)}"# : ""
        return #"{"full_name":"\#(fullName)","name":"distiller-recipes","owner":{"login":"\#(owner)"},"default_branch":"main","fork":\#(fork)\#(parent)\#(permissions)}"#
    }

    static func route(_ method: String, _ path: String, _ body: [String: Any]) -> (Int, String) {
        if method != "GET" { state.writes.append("\(method) \(path)") }
        let parts = path.split(separator: "/").map(String.init)
        if method == "GET", path == "/user" { return (200, #"{"login":"\#(state.login)"}"#) }
        guard parts.count >= 3, parts[0] == "repos" else { return (404, "{}") }
        let repo = "\(parts[1])/\(parts[2])"
        let rest = Array(parts.dropFirst(3))

        switch (method, rest.first) {
        case ("GET", nil):
            if repo == upstream { return (200, repositoryJSON(upstream, fork: false)) }
            if repo == fork, state.forkExists { return (200, repositoryJSON(fork, fork: true)) }
            return (404, "{}")
        case ("POST", "forks"):
            state.forkExists = true
            state.refs[fork] = ["main": "old-fork-sha"]
            return (202, repositoryJSON(fork, fork: true))
        case ("POST", "merge-upstream"):
            let upstreamMain = state.refs[upstream]?["main"]
            state.refs[repo]?["main"] = upstreamMain
            return (200, "{}")
        case ("GET", "git") where rest.count >= 3 && rest[1] == "ref" && rest[2] == "heads":
            let branch = rest.dropFirst(3).joined(separator: "/")
            guard let sha = state.refs[repo]?[branch] else { return (404, "{}") }
            return (200, #"{"object":{"sha":"\#(sha)"}}"#)
        case ("GET", "git") where rest.count == 3 && rest[1] == "commits":
            return (200, #"{"tree":{"sha":"tree-of-\#(rest[2])"}}"#)
        case ("POST", "git") where rest.count == 2 && rest[1] == "trees":
            let entries = (body["tree"] as? [[String: Any]]) ?? []
            state.treeFiles = entries.compactMap { $0["path"] as? String }
            state.treeBlobFiles = entries.filter { $0["sha"] is String }.compactMap { $0["path"] as? String }
            state.treeDeletedFiles = entries.filter { $0["sha"] is NSNull }.compactMap { $0["path"] as? String }
            return (201, #"{"sha":"new-tree"}"#)
        case ("POST", "git") where rest.count == 2 && rest[1] == "blobs":
            guard body["encoding"] as? String == "base64", let data = (body["content"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return (422, "{}") }
            state.blobs.append(data)
            return (201, #"{"sha":"blob-\#(state.blobs.count)"}"#)
        case ("POST", "git") where rest.count == 2 && rest[1] == "commits":
            return (201, #"{"sha":"new-commit"}"#)
        case ("POST", "git") where rest.count == 2 && rest[1] == "refs":
            let ref = (body["ref"] as? String ?? "").replacingOccurrences(of: "refs/heads/", with: "")
            state.refs[repo, default: [:]][ref] = body["sha"] as? String
            return (201, "{}")
        case ("PATCH", "git"):
            let branch = rest.dropFirst(3).joined(separator: "/")
            state.refs[repo, default: [:]][branch] = body["sha"] as? String
            return (200, "{}")
        case ("GET", "contents"):
            let file = rest.dropFirst().joined(separator: "/")
            guard repo == upstream, state.upstreamFiles.contains(file) else { return (404, "{}") }
            if file.hasPrefix("recipes/") {
                var draft = RecipeDraft(source: .manual, title: "Real Game", slug: "real-game", recipeID: "dxvk")
                draft.authors = state.publishedAuthors
                let yaml = (try? RecipeLoader.encode(draft.makeRecipe())) ?? ""
                return (200, #"{"encoding":"base64","content":"\#(Data(yaml.utf8).base64EncodedString())"}"#)
            }
            return (200, "{}")
        case ("POST", "pulls"):
            state.pullRequestBody = body
            state.openPullRequests.insert(7)
            return (201, #"{"number":7,"html_url":"https://github.com/\#(upstream)/pull/7","state":"open","head":{"sha":"new-commit"}}"#)
        case ("GET", "pulls"):
            let number = Int(rest.last ?? "") ?? 0
            let open = state.openPullRequests.contains(number)
            return (200, #"{"number":\#(number),"html_url":"https://github.com/\#(upstream)/pull/\#(number)","state":"\#(open ? "open" : "closed")","head":{"sha":"x"}}"#)
        default:
            return (404, "{}")
        }
    }

    static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

final class RecipeSubmitterTests: XCTestCase {
    let repository = CommunityRepository(owner: "nullfx", name: "distiller-recipes", oauthClientID: "Ov23.example")

    override func setUp() {
        FakeGitHub.state = FakeGitHub.State()
    }

    private func submitter() -> RecipeSubmitter {
        RecipeSubmitter(repository: repository, token: "gho_test", session: FakeGitHub.session()) { _ in }
    }

    private func recipe(authors: [String]? = nil) -> Recipe {
        var draft = RecipeDraft(source: .folder(URL(fileURLWithPath: "/Games/Real Game")), title: "Real Game")
        draft.launchProgram = "Game.exe"
        draft.recipeID = "dxvk"
        draft.publicInstallerURL = "https://cdn.example.com/RealGameSetup.exe"
        draft.authors = authors ?? []
        return draft.makeRecipe()
    }

    private var details: GameDetails {
        var details = GameDetails(from: recipe())
        details.description = "A real game."
        details.genres = ["rpg"]
        details.releaseYear = 2012
        return details
    }

    /// Writes to the community repository's main branch, which must never happen.
    private var writesToMain: [String] {
        FakeGitHub.state.writes.filter { $0.contains("/repos/\(FakeGitHub.upstream)/git/refs/heads/main") }
    }

    func testContributorGoesThroughAFork() async throws {
        let result = try await submitter().submit(recipe(), report: nil, hardware: Macs.m3Pro, previous: nil, game: details)

        XCTAssertEqual(result.fork, "octocat/distiller-recipes")
        XCTAssertEqual(result.branch, "recipe/real-game/dxvk")
        XCTAssertTrue(FakeGitHub.state.writes.contains("POST /repos/nullfx/distiller-recipes/forks"))
        XCTAssertNotNil(FakeGitHub.state.refs["octocat/distiller-recipes"]?["recipe/real-game/dxvk"])
        XCTAssertNil(FakeGitHub.state.refs[FakeGitHub.upstream]?["recipe/real-game/dxvk"], "Contributors don't branch upstream")
        XCTAssertEqual(FakeGitHub.state.pullRequestBody["head"] as? String, "octocat:recipe/real-game/dxvk")
        XCTAssertEqual(FakeGitHub.state.pullRequestBody["base"] as? String, "main")
        XCTAssertEqual(Set(FakeGitHub.state.treeFiles), ["recipes/real-game/dxvk.yaml", "games/real-game.yaml"], "The new game's file comes with its first recipe")
        XCTAssertEqual(writesToMain, [])
    }

    func testPicturesGoInAsBlobs() async throws {
        let icon = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let cover = Data([0xFF, 0xD8, 0xFF, 4, 5, 6])
        let second = Data([0xFF, 0xD8, 0xFF, 7, 8, 9])
        _ = try await submitter().submit(
            recipe(), report: nil, hardware: Macs.m3Pro, previous: nil, game: details,
            media: SubmissionMedia(icon: icon, screenshots: [cover, second])
        )
        XCTAssertEqual(Set(FakeGitHub.state.treeBlobFiles), ["media/real-game/icon.png", "media/real-game/dxvk/1.jpg", "media/real-game/dxvk/2.jpg"])
        XCTAssertEqual(FakeGitHub.state.blobs.count, 3)
        XCTAssertEqual(Set(FakeGitHub.state.blobs), [icon, cover, second])
        XCTAssertEqual(FakeGitHub.state.treeDeletedFiles, [])
        XCTAssertTrue(FakeGitHub.state.writes.contains("POST /repos/octocat/distiller-recipes/git/blobs"), "Blobs go where the branch is")

        // The catalogue's icon for the game is kept; the recipe's screenshots are replaced,
        // and ones beyond the new set are removed.
        FakeGitHub.state = FakeGitHub.State()
        FakeGitHub.state.upstreamFiles = ["games/real-game.yaml", "media/real-game/icon.png", "media/real-game/dxvk/2.jpg", "media/real-game/dxvk/3.jpg"]
        _ = try await submitter().submit(
            recipe(), report: nil, hardware: Macs.m3Pro, previous: nil, game: nil,
            media: SubmissionMedia(icon: icon, screenshots: [cover])
        )
        XCTAssertEqual(FakeGitHub.state.treeBlobFiles, ["media/real-game/dxvk/1.jpg"])
        XCTAssertEqual(FakeGitHub.state.treeDeletedFiles, ["media/real-game/dxvk/2.jpg", "media/real-game/dxvk/3.jpg"])

        // Without screenshots, published ones are left alone; at most three are sent.
        FakeGitHub.state = FakeGitHub.State()
        FakeGitHub.state.upstreamFiles = ["games/real-game.yaml", "media/real-game/dxvk/1.jpg"]
        _ = try await submitter().submit(recipe(), report: nil, hardware: Macs.m3Pro, previous: nil, game: nil)
        XCTAssertEqual(FakeGitHub.state.treeFiles, ["recipes/real-game/dxvk.yaml"])
        XCTAssertEqual(SubmissionMedia(screenshots: [cover, cover, cover, second]).screenshots.count, 3)
    }

    func testMaintainerBranchesInTheRepositoryItself() async throws {
        FakeGitHub.state.login = "nullfx"
        FakeGitHub.state.canPush = true
        let result = try await submitter().submit(recipe(), report: nil, hardware: Macs.m3Pro, previous: nil, game: details)

        XCTAssertEqual(result.fork, FakeGitHub.upstream)
        XCTAssertFalse(FakeGitHub.state.writes.contains { $0.hasSuffix("/forks") }, "No fork for maintainers")
        XCTAssertEqual(FakeGitHub.state.refs[FakeGitHub.upstream]?["recipe/real-game/dxvk"], "new-commit")
        XCTAssertEqual(FakeGitHub.state.refs[FakeGitHub.upstream]?["main"], "base-sha", "main is untouched")
        XCTAssertEqual(FakeGitHub.state.pullRequestBody["head"] as? String, "recipe/real-game/dxvk")
        XCTAssertEqual(writesToMain, [])
    }

    func testExistingGameIsntRewrittenAndNewGameNeedsDetails() async throws {
        FakeGitHub.state.upstreamFiles = ["games/real-game.yaml"]
        _ = try await submitter().submit(recipe(), report: nil, hardware: Macs.m3Pro, previous: nil, game: nil)
        XCTAssertEqual(FakeGitHub.state.treeFiles, ["recipes/real-game/dxvk.yaml"])

        FakeGitHub.state = FakeGitHub.State()
        do {
            _ = try await submitter().submit(recipe(), report: nil, hardware: Macs.m3Pro, previous: nil, game: nil)
            XCTFail("A new game needs its details")
        } catch GitHubError.gameDetailsNeeded(let slug) {
            XCTAssertEqual(slug, "real-game")
        }
        var empty = details
        empty.description = " "
        await XCTAssertThrowsErrorAsync(try await self.submitter().submit(self.recipe(), report: nil, hardware: Macs.m3Pro, previous: nil, game: empty))
    }

    func testRevisingAMergedRecipe() async throws {
        FakeGitHub.state.upstreamFiles = ["games/real-game.yaml", "recipes/real-game/dxvk.yaml"]

        // Someone else's recipe: refused, with advice to fork it under a new ID. Adding yourself
        // to your own copy's authors doesn't help; the published recipe decides.
        FakeGitHub.state.publishedAuthors = ["someone-else"]
        do {
            _ = try await submitter().submit(recipe(authors: ["someone-else", "octocat"]), report: nil, hardware: Macs.m3Pro, previous: nil)
            XCTFail("Only authors and maintainers may revise")
        } catch GitHubError.recipeExists(let path) {
            XCTAssertEqual(path, "recipes/real-game/dxvk.yaml")
        }

        // One of its published authors: an update branch and an "Update" pull request.
        FakeGitHub.state.publishedAuthors = ["octocat"]
        let result = try await submitter().submit(recipe(authors: ["octocat"]), report: nil, hardware: Macs.m3Pro, previous: nil)
        XCTAssertEqual(result.branch, "recipe/real-game/dxvk-update")
        XCTAssertTrue((FakeGitHub.state.pullRequestBody["title"] as? String ?? "").hasPrefix("Update"), "\(FakeGitHub.state.pullRequestBody)")

        // A maintainer may revise anyone's recipe.
        FakeGitHub.state = FakeGitHub.State()
        FakeGitHub.state.upstreamFiles = ["games/real-game.yaml", "recipes/real-game/dxvk.yaml"]
        FakeGitHub.state.login = "nullfx"
        FakeGitHub.state.canPush = true
        let maintained = try await submitter().submit(recipe(authors: ["someone-else"]), report: nil, hardware: Macs.m3Pro, previous: nil)
        XCTAssertEqual(maintained.fork, FakeGitHub.upstream)
        XCTAssertEqual(maintained.branch, "recipe/real-game/dxvk-update")
        XCTAssertEqual(writesToMain, [])
    }

    func testResubmittingWhileThePullRequestIsOpenUpdatesIt() async throws {
        FakeGitHub.state.upstreamFiles = ["games/real-game.yaml"]
        let first = try await submitter().submit(recipe(), report: nil, hardware: Macs.m3Pro, previous: nil)
        FakeGitHub.state.writes = []
        let second = try await submitter().submit(recipe(), report: nil, hardware: Macs.m3Pro, previous: first)
        XCTAssertEqual(second.pullRequest, first.pullRequest)
        XCTAssertNotNil(second.updatedAt)
        XCTAssertTrue(FakeGitHub.state.writes.contains("PATCH /repos/octocat/distiller-recipes/git/refs/heads/recipe/real-game/dxvk"), "\(FakeGitHub.state.writes)")
        XCTAssertFalse(FakeGitHub.state.writes.contains { $0.hasSuffix("/pulls") }, "No second pull request")
    }

    func testTargetDescribesWhereASubmissionGoes() async throws {
        FakeGitHub.state.upstreamFiles = ["recipes/real-game/dxvk.yaml"]
        FakeGitHub.state.publishedAuthors = ["octocat"]
        let contributor = try await submitter().target(for: recipe())
        XCTAssertEqual(contributor, SubmissionTarget(isMaintainer: false, gameExists: false, recipeExists: true, canRevise: true))
        FakeGitHub.state.publishedAuthors = ["someone-else"]
        let stranger = try await submitter().target(for: recipe(authors: ["octocat"]))
        XCTAssertFalse(stranger.canRevise, "Your own copy's author list doesn't count")

        FakeGitHub.state.canPush = true
        let maintainer = try await submitter().target(for: recipe())
        XCTAssertTrue(maintainer.isMaintainer)
        XCTAssertTrue(maintainer.canRevise)
    }

    func testGameFileMatchesTheSchemaShape() throws {
        let yaml = try SubmissionPlan.gameYAML(details)
        XCTAssertTrue(yaml.contains("schema: 1"))
        XCTAssertTrue(yaml.contains("release_year: 2012"), "A number, not text")
        XCTAssertTrue(yaml.contains("installer:"))
        XCTAssertFalse(yaml.contains("developer:"), "Empty fields are left out")
        XCTAssertEqual(GameDetails(slug: "x", title: "X", genres: ["nope"], description: "").problems.count, 2)
    }
}

/// `XCTAssertThrowsError` for async expressions.
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
