import Foundation

/// An installer the player downloaded from a publisher's download page in Distiller's
/// browser: where they were, the links the download went through, and the file.
public struct CapturedDownload: Sendable, Equatable {
    /// The page they were on when they clicked download.
    public var page: URL?
    /// The link they clicked, each redirect, and the file's final address, in that order.
    public var links: [URL]
    public var fileName: String
    /// The downloaded file's size in bytes.
    public var size: Int64
    /// The downloaded file, until it's used or thrown away.
    public var localFile: URL?

    public init(page: URL?, links: [URL], fileName: String, size: Int64, localFile: URL? = nil) {
        self.page = page
        var seen = Set<String>()
        self.links = links.filter { seen.insert($0.absoluteString).inserted }
        self.fileName = fileName
        self.size = size
        self.localFile = localFile
    }
}

/// What the direct-download test found for one link.
public enum InstallerLinkOutcome: Sendable, Equatable {
    /// Downloads the same file with no cookies and no referrer.
    case works
    /// Signed or expiring (its query has an expiry, a signature or a token), so it won't
    /// work for the next player even if it works now.
    case shortLived
    /// Not an https link.
    case notHTTPS
    /// The server refused it on its own (it needs the page's cookies or referrer, or a login).
    case refused(status: Int)
    /// It answers with a file of a different size.
    case differentFile(size: Int64)
    /// The request failed.
    case failed(String)
}

public struct InstallerLinkResult: Sendable, Equatable {
    /// The link to record as `game.installer.url`: the earliest that works on its own.
    public var url: URL?
    /// Each link tried, in order, with what happened.
    public var tried: [Attempt]

    public struct Attempt: Sendable, Equatable {
        public var url: URL
        public var outcome: InstallerLinkOutcome
    }
}

/// Finds which of a captured download's links a later player's Distiller can use directly:
/// requested the way Distiller downloads installers, with no cookies and no referrer. The
/// link the player clicked comes first (often a stable redirector), then each redirect, then
/// the final address, which is often a short-lived CDN link.
public enum InstallerLinkTest {
    /// Query parameters that mark a signed or expiring link (compared in lower case).
    static let shortLivedParameters: Set<String> = [
        "expires", "expiry", "expire", "exp", "e", "signature", "sig", "token", "auth", "hdnts", "policy",
        "key-pair-id", "se", "sp", "sv", "st", "x-amz-signature", "x-amz-expires", "x-amz-credential",
        "x-amz-security-token", "x-goog-signature", "x-goog-expires", "x-goog-credential", "validto",
    ]

    public static func looksShortLived(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { shortLivedParameters.contains($0.name.lowercased()) }
    }

    /// A session like a later player's download: no cookies kept or sent, no cache.
    public static func plainSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    public static func test(_ capture: CapturedDownload, session: URLSession = plainSession()) async -> InstallerLinkResult {
        var tried: [InstallerLinkResult.Attempt] = []
        for link in capture.links {
            let outcome = await check(link, expectedSize: capture.size, session: session)
            tried.append(.init(url: link, outcome: outcome))
            if outcome == .works { return InstallerLinkResult(url: link, tried: tried) }
        }
        return InstallerLinkResult(url: nil, tried: tried)
    }

    static func check(_ url: URL, expectedSize: Int64, session: URLSession) async -> InstallerLinkOutcome {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return .notHTTPS }
        if looksShortLived(url) { return .shortLived }
        do {
            let (status, size) = try await probe(url, session: session)
            guard (200..<300).contains(status) else { return .refused(status: status) }
            // The size proves it's the same file (the community check records its checksum).
            // A server that won't say keeps the link; the check still downloads it in full.
            if let size, expectedSize > 0, size != expectedSize { return .differentFile(size: size) }
            return .works
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The status and the file's size: from HEAD, or, if HEAD isn't allowed, a GET for the
    /// first byte (the size from Content-Range, or Content-Length if the server sends it all,
    /// in which case the download is stopped once the headers arrive).
    static func probe(_ url: URL, session: URLSession) async throws -> (status: Int, size: Int64?) {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        if let (_, response) = try? await session.data(for: head), let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            return (http.statusCode, http.expectedContentLength > 0 ? http.expectedContentLength : nil)
        }
        var get = URLRequest(url: url)
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: get)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { return (0, nil) }
        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            return (http.statusCode, total)
        }
        return (http.statusCode, http.expectedContentLength > 0 ? http.expectedContentLength : nil)
    }
}

/// A file the player downloads themselves from a publisher's download page: an installer with
/// no direct link that works on its own (`user_download` steps, and installers with only a
/// `game.installer.page`). The app opens the page in its private browser; the command line
/// asks for the file's path.
public struct PageDownloadRequest: Sendable, Equatable {
    /// The step's id (`CommunityCheck.installerDownloadID` for a game's installer).
    public var id: String
    /// The game.
    public var title: String
    public var prompt: String
    public var page: URL

    public init(id: String, title: String, prompt: String, page: URL) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.page = page
    }
}
