import Foundation
import DistillerCore

/// What a player's check of a source found, for the pull request that adds it.
public struct SourceCheckNotes: Equatable, Sendable {
    public var file: String
    public var sha256: String
    public var librariesFrom: String?
    public var librariesAdded: Int
    public var containsD3DMetal: Bool
    public var exportsMacDriverFunctions: Bool?
    public var recipe: String?

    public init(file: String, sha256: String, librariesFrom: String?, librariesAdded: Int, containsD3DMetal: Bool,
                exportsMacDriverFunctions: Bool?, recipe: String?) {
        self.file = file
        self.sha256 = sha256
        self.librariesFrom = librariesFrom
        self.librariesAdded = librariesAdded
        self.containsD3DMetal = containsD3DMetal
        self.exportsMacDriverFunctions = exportsMacDriverFunctions
        self.recipe = recipe
    }
}

extension RecipeSubmitter {
    public static func sourceBranchName(_ source: ComponentSource, attempt: Int = 1) -> String {
        let base = "source/\(source.kind.rawValue)/\(source.tag)"
        return attempt <= 1 ? base : "\(base)-\(attempt)"
    }

    public static func sourcePullRequestBody(_ source: ComponentSource, notes: SourceCheckNotes?) -> String {
        var lines = [
            "## What this changes",
            "",
            "Adds the source for \(source.kind == .wine ? "the Wine build" : "the graphics layer") **\(source.name)** (`\(source.tag)`), submitted from Distiller, so recipes can name it.",
            "",
            "- Publisher: \(source.publisher) (\(source.homepage))",
            "- Downloads: github.com/\(source.get.githubRelease.repository) releases, files matching `\(source.get.githubRelease.asset)`",
            "- Licence: \(source.license)",
        ]
        if source.kind == .wine { lines.append("- Family: `\(source.family)`") }
        if let from = source.librariesFrom { lines.append("- Libraries from: `\(from)`") }
        if source.containsD3DMetal == true { lines.append("- **Includes D3DMetal** (its publisher answers for it under Apple's terms; Distiller labels it and asks before downloading)") }
        if let notes {
            lines += ["", "## Checked in Distiller", "",
                      "- Downloaded `\(notes.file)` and matched GitHub's checksum (`\(notes.sha256.prefix(16))…`)"]
            if let from = notes.librariesFrom {
                lines.append("- Added \(notes.librariesAdded) libraries from `\(from)`; every library it loads was then present")
            } else {
                lines.append("- Every library it loads is in its download")
            }
            lines.append("- D3DMetal: \(notes.containsD3DMetal ? "included" : "not included")")
            if let exports = notes.exportsMacDriverFunctions {
                lines.append("- Runs D3DMetal and DXMT: \(exports ? "yes" : "no") (macOS driver functions)")
            }
            if let recipe = notes.recipe { lines.append("- Needed by: \(recipe)") }
        }
        lines += ["", "A maintainer reviews sources before they're merged: they're programs that run on players' Macs."]
        return lines.joined(separator: "\n")
    }

    /// Submits a source as a pull request adding `components/<kind>/<tag>.yaml`, the same way
    /// recipes are submitted: a branch in the community repository for maintainers, in the
    /// player's fork otherwise; never pushed to the base branch. A source that's already
    /// published isn't replaced from here.
    public func submitSource(_ source: ComponentSource, notes: SourceCheckNotes?,
                             progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        guard repository.isConfiguredForSubmissions else { throw GitHubError.notConfigured }
        let problems = source.problems
        guard problems.isEmpty else { throw GitHubError.invalidResponse(problems.joined(separator: " ")) }
        let upstream = repository.fullName
        let base = repository.branch
        progress("Checking your GitHub account")
        let user = try await api.currentUser()
        if try await api.fileExists(upstream, path: source.repositoryPath, ref: base) {
            throw GitHubError.invalidResponse("\(upstream) already has a source tagged \(source.tag). Changes to published sources go through its maintainers.")
        }
        let isMaintainer = try await api.repository(upstream)?.canPush ?? false
        let target: String
        if isMaintainer {
            target = upstream
        } else {
            progress("Preparing your copy of \(upstream)")
            target = try await ensureFork(of: upstream, login: user.login)
            _ = await api.mergeUpstream(fork: target, branch: base)
        }
        guard let parent = try await api.branchHead(upstream, branch: base) else {
            throw GitHubError.invalidResponse("\(upstream) has no \(base) branch.")
        }
        var branch = Self.sourceBranchName(source)
        var attempt = 1
        while try await api.branchHead(target, branch: branch) != nil {
            attempt += 1
            branch = Self.sourceBranchName(source, attempt: attempt)
        }
        guard branch != base else { throw GitHubError.invalidResponse("refusing to push to \(base).") }
        progress("Committing the source")
        let commit = try await commit([source.repositoryPath: .text(try source.encoded())], onto: parent, in: target,
                                      message: "Add \(source.repositoryPath)")
        try await api.createBranch(target, branch: branch, sha: commit)
        progress("Opening the pull request")
        let head = isMaintainer ? branch : "\(target.split(separator: "/").first.map(String.init) ?? user.login):\(branch)"
        let pull = try await api.createPullRequest(upstream, title: "Add source: \(source.name) (\(source.tag))", head: head, base: base,
                                                   body: Self.sourcePullRequestBody(source, notes: notes))
        return URL(string: pull.htmlURL) ?? repository.webURL
    }
}
