import Foundation

/// A file to commit: UTF-8 text, or binary data such as an image.
public enum RepositoryFile: Equatable, Sendable {
    case text(String)
    case binary(Data)
    /// Removes the file in the new commit.
    case delete
}

public struct GitHubUser: Codable, Equatable, Sendable {
    public var login: String
    public var name: String?
    public var avatarURL: URL?
    public var profileURL: URL?

    public init(login: String, name: String? = nil, avatarURL: URL? = nil, profileURL: URL? = nil) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.profileURL = profileURL
    }

    enum CodingKeys: String, CodingKey {
        case login, name
        case avatarURL = "avatar_url"
        case profileURL = "html_url"
    }
}

public struct GitHubRepository: Decodable, Equatable, Sendable {
    public var fullName: String
    public var name: String
    public var owner: Owner
    public var defaultBranch: String
    public var fork: Bool
    public var parent: Parent?
    /// The signed-in user's access, which GitHub includes when the request is authenticated.
    public var permissions: Permissions?

    /// True when the signed-in user can push branches here (owners and maintainers).
    public var canPush: Bool { permissions?.push == true || permissions?.maintain == true || permissions?.admin == true }

    public struct Permissions: Decodable, Equatable, Sendable {
        public var admin: Bool?
        public var maintain: Bool?
        public var push: Bool?
    }

    public struct Owner: Decodable, Equatable, Sendable { public var login: String }
    public struct Parent: Decodable, Equatable, Sendable {
        public var fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }

    enum CodingKeys: String, CodingKey {
        case name, owner, fork, parent, permissions
        case fullName = "full_name"
        case defaultBranch = "default_branch"
    }
}

public struct GitHubPullRequest: Decodable, Equatable, Sendable {
    public var number: Int
    public var htmlURL: String
    public var state: String
    public var merged: Bool?
    public var head: Head

    public struct Head: Decodable, Equatable, Sendable { public var sha: String }

    enum CodingKeys: String, CodingKey {
        case number, state, merged, head
        case htmlURL = "html_url"
    }
}

public struct GitHubCheckRun: Decodable, Equatable, Sendable {
    public var name: String
    public var status: String
    public var conclusion: String?
}

/// The handful of GitHub REST calls recipe submission needs.
public final class GitHubAPI: @unchecked Sendable {
    let token: String?
    let session: URLSession
    let base = URL(string: "https://api.github.com")!

    public init(token: String?, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    public func currentUser() async throws -> GitHubUser {
        try await call("GET", "/user")
    }

    /// nil when the repository doesn't exist or isn't visible.
    public func repository(_ fullName: String) async throws -> GitHubRepository? {
        try await optional("GET", "/repos/\(fullName)")
    }

    /// Starts creating a fork. GitHub returns at once and copies the repository in the background.
    public func createFork(of fullName: String) async throws -> GitHubRepository {
        try await call("POST", "/repos/\(fullName)/forks", body: ["default_branch_only": true])
    }

    /// Fast-forwards the fork's branch to the upstream branch. False when GitHub refuses,
    /// for example because the player committed to their fork's main branch.
    public func mergeUpstream(fork: String, branch: String) async -> Bool {
        do {
            let _: EmptyResponse = try await call("POST", "/repos/\(fork)/merge-upstream", body: ["branch": branch])
            return true
        } catch {
            return false
        }
    }

    public func branchHead(_ fullName: String, branch: String) async throws -> String? {
        let ref: GitRef? = try await optional("GET", "/repos/\(fullName)/git/ref/heads/\(Self.escapePath(branch))")
        return ref?.object.sha
    }

    public func treeOfCommit(_ fullName: String, sha: String) async throws -> String {
        let commit: GitCommit = try await call("GET", "/repos/\(fullName)/git/commits/\(sha)")
        return commit.tree.sha
    }

    /// Uploads binary content and returns the blob's SHA.
    public func createBlob(_ fullName: String, data: Data) async throws -> String {
        let blob: GitSHA = try await call("POST", "/repos/\(fullName)/git/blobs", body: ["content": data.base64EncodedString(), "encoding": "base64"])
        return blob.sha
    }

    /// Creates a tree with `files` on top of `baseTree`, and returns its SHA. Text goes in the
    /// tree directly; binary files are uploaded as blobs first.
    public func createTree(_ fullName: String, baseTree: String, files: [String: RepositoryFile]) async throws -> String {
        var entries: [[String: Any]] = []
        for path in files.keys.sorted() {
            switch files[path] {
            case .text(let text)?:
                entries.append(["path": path, "mode": "100644", "type": "blob", "content": text])
            case .binary(let data)?:
                entries.append(["path": path, "mode": "100644", "type": "blob", "sha": try await createBlob(fullName, data: data)])
            case .delete?:
                entries.append(["path": path, "mode": "100644", "type": "blob", "sha": NSNull()])
            case nil:
                break
            }
        }
        let tree: GitSHA = try await call("POST", "/repos/\(fullName)/git/trees", body: ["base_tree": baseTree, "tree": entries])
        return tree.sha
    }

    public func createCommit(_ fullName: String, message: String, tree: String, parents: [String]) async throws -> String {
        let commit: GitSHA = try await call("POST", "/repos/\(fullName)/git/commits", body: ["message": message, "tree": tree, "parents": parents])
        return commit.sha
    }

    public func createBranch(_ fullName: String, branch: String, sha: String) async throws {
        let _: EmptyResponse = try await call("POST", "/repos/\(fullName)/git/refs", body: ["ref": "refs/heads/\(branch)", "sha": sha])
    }

    public func updateBranch(_ fullName: String, branch: String, sha: String) async throws {
        let _: EmptyResponse = try await call(
            "PATCH", "/repos/\(fullName)/git/refs/heads/\(Self.escapePath(branch))", body: ["sha": sha, "force": false]
        )
    }

    public func fileExists(_ fullName: String, path: String, ref: String) async throws -> Bool {
        let item: EmptyResponse? = try await optional("GET", "/repos/\(fullName)/contents/\(Self.escapePath(path))?ref=\(Self.escapePath(ref))")
        return item != nil
    }

    /// A text file's contents at `ref`, or nil when it doesn't exist.
    public func fileText(_ fullName: String, path: String, ref: String) async throws -> String? {
        struct Contents: Decodable { var content: String?; var encoding: String? }
        guard let file: Contents = try await optional("GET", "/repos/\(fullName)/contents/\(Self.escapePath(path))?ref=\(Self.escapePath(ref))"),
              let content = file.content, file.encoding == "base64",
              let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func createPullRequest(_ fullName: String, title: String, head: String, base: String, body: String) async throws -> GitHubPullRequest {
        try await call("POST", "/repos/\(fullName)/pulls", body: [
            "title": title, "head": head, "base": base, "body": body, "maintainer_can_modify": true,
        ])
    }

    public func pullRequest(_ fullName: String, number: Int) async throws -> GitHubPullRequest {
        try await call("GET", "/repos/\(fullName)/pulls/\(number)")
    }

    public func checkRuns(_ fullName: String, sha: String) async throws -> [GitHubCheckRun] {
        let list: CheckRunList = try await call("GET", "/repos/\(fullName)/commits/\(sha)/check-runs")
        return list.checkRuns
    }

    // MARK: Plumbing

    struct EmptyResponse: Decodable {}
    struct GitSHA: Decodable { var sha: String }
    struct GitRef: Decodable { var object: GitSHA }
    struct GitCommit: Decodable { var tree: GitSHA }
    struct CheckRunList: Decodable {
        var checkRuns: [GitHubCheckRun]
        enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
    }
    struct ErrorBody: Decodable {
        var message: String?
        var errors: [Detail]?
        struct Detail: Decodable { var message: String? }
    }

    /// Escapes each segment of a path but keeps the slashes.
    static func escapePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0) }
            .joined(separator: "/")
    }

    func optional<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T? {
        do {
            return try await call(method, path, body: body) as T
        } catch GitHubError.http(let status, _) where status == 404 {
            return nil
        }
    }

    func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        guard let url = URL(string: base.absoluteString + path) else { throw GitHubError.invalidResponse("bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Distiller", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(ErrorBody.self, from: data)
            let message = ([detail?.message] + (detail?.errors ?? []).map(\.message)).compactMap { $0 }.joined(separator: " ")
            throw GitHubError.http(status: http.statusCode, message: message.isEmpty ? "\(method) \(path) failed" : message)
        }
        if T.self == EmptyResponse.self, data.isEmpty || (try? JSONSerialization.jsonObject(with: data)) is [Any] {
            return EmptyResponse() as! T
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.invalidResponse("\(method) \(path): \(error.localizedDescription)")
        }
    }
}
