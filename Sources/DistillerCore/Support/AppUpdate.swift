import Foundation
import Security

/// A published Distiller release.
public struct AppRelease: Equatable, Sendable {
    public var version: String
    /// The release's page, for its notes.
    public var page: URL
    /// `Distiller.dmg`.
    public var diskImage: URL
    /// `SHA256SUMS.txt`, when the release has it.
    public var checksums: URL?
    public var size: Int64?
}

/// Distiller's own updates, from the GitHub releases of the repository this copy was built
/// from (`DistillerUpdateRepository` in Info.plist, written by `Scripts/bundle-app.sh`). A
/// fork's builds therefore update from the fork, and the official builds from the official
/// repository; nothing here names either.
///
/// Before an update is used: the disk image must match the release's `SHA256SUMS.txt`, and the
/// app in it must have the same bundle identifier, carry the release's version, pass
/// `codesign --verify --deep --strict`, be signed by the **same team** as the running copy, and
/// be accepted by Gatekeeper (`spctl`: Developer ID and notarized). A copy built by one team can
/// never be replaced by another team's build.
public struct AppUpdater: Sendable {
    public let repository: String
    let session: URLSession

    public init(repository: String, session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    /// The repository the running copy updates from, or nil for builds without one.
    public static var configuredRepository: String? {
        guard let value = DistillerVersion.appInfo()?["DistillerUpdateRepository"] as? String, isRepositoryName(value) else { return nil }
        return value
    }

    static func isRepositoryName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    /// Whether `available` is a newer version than `current`. Development builds (no version)
    /// never update.
    public static func isNewer(_ available: String, than current: String) -> Bool {
        guard current != DistillerVersion.development else { return false }
        return VersionNumber(available) > VersionNumber(current)
    }

    /// The latest published (not draft, not pre-release) release.
    public func latestRelease() async throws -> AppRelease {
        guard Self.isRepositoryName(repository),
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw DistillerError.setupFailed("'\(repository)' isn't a GitHub repository.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Distiller", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DistillerError.setupFailed(http.statusCode == 404
                ? "github.com/\(repository) has no published release yet."
                : "GitHub answered \(http.statusCode). Try again in a few minutes.")
        }
        let release = try JSONDecoder().decode(GitHubAppRelease.self, from: data)
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard let image = release.assets.first(where: { $0.name == "Distiller.dmg" }),
              let imageURL = URL(string: image.browserDownloadURL), imageURL.scheme == "https",
              let page = URL(string: release.htmlURL) else {
            throw DistillerError.setupFailed("The latest release on github.com/\(repository) has no Distiller.dmg.")
        }
        let sums = release.assets.first { $0.name == "SHA256SUMS.txt" }.flatMap { URL(string: $0.browserDownloadURL) }
        return AppRelease(version: version, page: page, diskImage: imageURL, checksums: sums?.scheme == "https" ? sums : nil, size: image.size)
    }

    /// Downloads the release's disk image into `folder` and checks it against the release's
    /// checksums. A release without `SHA256SUMS.txt` is refused.
    public func download(_ release: AppRelease, into folder: URL) async throws -> URL {
        guard let checksums = release.checksums else {
            throw DistillerError.setupFailed("Distiller \(release.version) has no SHA256SUMS.txt to check the download against, so it won't be installed. Download it from its release page instead.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sumsFile = folder.appendingPathComponent("SHA256SUMS.txt")
        _ = try await Downloader.download(checksums, to: sumsFile, session: session)
        guard let expected = Self.checksum(for: "Distiller.dmg", in: String(decoding: try Data(contentsOf: sumsFile), as: UTF8.self)) else {
            throw DistillerError.setupFailed("SHA256SUMS.txt for Distiller \(release.version) doesn't list Distiller.dmg.")
        }
        let image = folder.appendingPathComponent("Distiller.dmg")
        let actual = try await Downloader.download(release.diskImage, to: image, session: session)
        guard actual.lowercased() == expected.lowercased() else {
            try? FileManager.default.removeItem(at: image)
            throw DistillerError.setupFailed("The downloaded Distiller \(release.version) doesn't match its published checksum, so it wasn't used. Try again later.")
        }
        return image
    }

    /// The SHA-256 listed for `name` in `shasum -a 256` output.
    static func checksum(for name: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let file = parts[1].hasPrefix("*") ? parts[1].dropFirst() : parts[1]
            if file == name, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) { return String(parts[0]) }
        }
        return nil
    }
}

/// Checks a downloaded copy of Distiller before it replaces the running one.
public enum AppBundleCheck {
    public struct Mounted: Sendable {
        public var mountPoint: URL
        public var app: URL
    }

    /// Mounts a disk image read-only and out of sight, and finds Distiller.app in it.
    public static func attach(_ image: URL) async throws -> Mounted {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", image.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path]
        )
        guard result.status == 0 else {
            throw DistillerError.setupFailed("The update's disk image couldn't be opened: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let app = mountPoint.appendingPathComponent("Distiller.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
            await detach(mountPoint)
            throw DistillerError.setupFailed("The update's disk image doesn't contain Distiller.app.")
        }
        return Mounted(mountPoint: mountPoint, app: app)
    }

    public static func detach(_ mountPoint: URL) async {
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", mountPoint.path, "-force"])
        try? FileManager.default.removeItem(at: mountPoint)
    }

    /// The team identifier of a signed bundle, or nil if it has none (ad-hoc or unsigned).
    public static func teamIdentifier(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Everything the update must pass before it replaces `current`. Throws with the reason.
    public static func verify(_ candidate: URL, replacing current: URL, version: String) async throws {
        let currentInfo = NSDictionary(contentsOf: current.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let candidateInfo = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        try check(candidateInfo: candidateInfo, currentInfo: currentInfo, version: version,
                  candidateTeam: teamIdentifier(of: candidate), currentTeam: teamIdentifier(of: current))
        let signature = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--deep", "--strict", candidate.path])
        guard signature.status == 0 else {
            throw DistillerError.setupFailed("The update's signature isn't valid, so it wasn't installed.")
        }
        let gatekeeper = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/spctl"), arguments: ["--assess", "--type", "execute", candidate.path])
        guard gatekeeper.status == 0 else {
            throw DistillerError.setupFailed("macOS doesn't accept the update (it must be signed with a Developer ID and notarized by Apple), so it wasn't installed.")
        }
    }

    /// The checks that need no tools: identifier, version and signing team.
    static func check(candidateInfo: [String: Any]?, currentInfo: [String: Any]?, version: String,
                      candidateTeam: String?, currentTeam: String?) throws {
        guard let candidateInfo, let identifier = candidateInfo["CFBundleIdentifier"] as? String,
              identifier == currentInfo?["CFBundleIdentifier"] as? String else {
            throw DistillerError.setupFailed("The download isn't this app (its bundle identifier differs), so it wasn't installed.")
        }
        guard DistillerVersion.version(fromInfo: candidateInfo) == version else {
            throw DistillerError.setupFailed("The download says it's a different version than release \(version), so it wasn't installed.")
        }
        guard let currentTeam else {
            throw DistillerError.setupFailed("This copy of Distiller isn't signed by a developer team, so there's nothing to check an update's signature against. Install the update from its disk image instead.")
        }
        guard candidateTeam == currentTeam else {
            throw DistillerError.setupFailed("The update is signed by a different developer than this copy of Distiller, so it wasn't installed.")
        }
    }
}

/// Replaces the running app with a checked update, then reopens it.
public enum AppReplacer {
    /// Whether the app can be replaced in place: its folder is writable and it isn't running
    /// from a temporary, read-only location (macOS's App Translocation for apps opened straight
    /// from Downloads or a disk image).
    public static func canReplace(_ app: URL) -> Bool {
        !app.standardizedFileURL.path.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Copies `candidate` next to `current` (so the final move stays on one volume), moves
    /// `current` to the Trash, and moves the copy into its place. On failure the original is
    /// put back. Returns the old copy's place in the Trash.
    @discardableResult
    public static func replace(_ current: URL, with candidate: URL) async throws -> URL? {
        let staged = current.deletingLastPathComponent().appendingPathComponent(".Distiller-update-\(UUID().uuidString).app", isDirectory: true)
        let copy = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [candidate.path, staged.path])
        guard copy.status == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw DistillerError.setupFailed("The update couldn't be copied next to Distiller: \(copy.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        do {
            try FileManager.default.moveItem(at: staged, to: current)
        } catch {
            if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: current) }
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return trashed as URL?
    }

    /// Starts a small shell that waits for this process to end, then opens `app`.
    public static func reopenAfterExit(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$2""#,
            "distiller-relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path,
        ]
        try process.run()
    }
}

struct GitHubAppRelease: Decodable {
    var tagName: String
    var htmlURL: String
    var assets: [Asset]

    struct Asset: Decodable {
        var name: String
        var browserDownloadURL: String
        var size: Int64?

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
