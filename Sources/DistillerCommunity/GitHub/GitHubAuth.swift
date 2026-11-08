import Foundation
#if canImport(Security)
import Security
#endif

public enum GitHubError: Error, Equatable, LocalizedError {
    case notConfigured
    case notSignedIn
    case http(status: Int, message: String)
    case signInExpired
    case signInDenied
    case signIn(String)
    case recipeExists(path: String)
    case gameDetailsNeeded(slug: String)
    case forkNotReady(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Submitting recipes isn't set up in this build of Distiller. Set the owner and OAuth client ID in CommunityRepository.default."
        case .notSignedIn:
            return "Sign in to GitHub to submit recipes."
        case .http(let status, let message):
            return status == 401
                ? "GitHub didn't accept the sign-in. Sign out and sign in again."
                : "GitHub answered \(status): \(message)"
        case .signInExpired:
            return "The sign-in code expired before it was entered. Start again to get a new code."
        case .signInDenied:
            return "The sign-in was cancelled on GitHub."
        case .signIn(let detail):
            return "GitHub sign-in failed: \(detail)"
        case .recipeExists(let path):
            return "The community repository already has \(path), and only its authors or a maintainer can revise it. Give your recipe a different ID (it can say forked_from that recipe)."
        case .gameDetailsNeeded(let slug):
            return "The community repository doesn't have \(slug) yet. Fill in the game's details (at least a short description) so its catalogue page can be made."
        case .forkNotReady(let name):
            return "GitHub is still creating your copy of the repository (\(name)). Try again in a minute."
        case .invalidResponse(let detail):
            return "GitHub sent an unexpected response: \(detail)"
        }
    }
}

/// The code a player types at github.com/login/device.
public struct DeviceCode: Decodable, Equatable, Sendable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: URL
    public var expiresIn: Int
    public var interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }

    public init(deviceCode: String, userCode: String, verificationURI: URL, expiresIn: Int, interval: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

/// GitHub's OAuth device flow: the app shows a short code, the player approves it in their
/// browser, and the app receives a token. No client secret is involved.
/// https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
public struct GitHubDeviceFlow: Sendable {
    /// Enough to fork the public recipes repository and open a pull request.
    public static let scope = "public_repo"

    public var clientID: String
    public var session: URLSession
    /// Injected so tests don't wait.
    public var sleep: @Sendable (Int) async throws -> Void

    public init(
        clientID: String,
        session: URLSession = .shared,
        sleep: @escaping @Sendable (Int) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
    ) {
        self.clientID = clientID
        self.session = session
        self.sleep = sleep
    }

    public func start() async throws -> DeviceCode {
        let data = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": Self.scope])
        if let failure = try? JSONDecoder().decode(TokenResponse.self, from: data), let error = failure.error {
            throw GitHubError.signIn(failure.errorDescription ?? error)
        }
        do {
            return try JSONDecoder().decode(DeviceCode.self, from: data)
        } catch {
            throw GitHubError.invalidResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    /// Polls until the player approves the code, declines it, or it expires.
    public func waitForToken(_ code: DeviceCode) async throws -> String {
        var interval = max(code.interval, 1)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await sleep(interval)
            try Task.checkCancellation()
            let data = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            if let token = response.accessToken, !token.isEmpty { return token }
            switch response.error {
            case "authorization_pending"?: continue
            case "slow_down"?: interval = response.interval ?? (interval + 5)
            case "expired_token"?: throw GitHubError.signInExpired
            case "access_denied"?: throw GitHubError.signInDenied
            case let other?: throw GitHubError.signIn(response.errorDescription ?? other)
            case nil: throw GitHubError.invalidResponse("no token and no error")
            }
        }
        throw GitHubError.signInExpired
    }

    struct TokenResponse: Decodable {
        var accessToken: String?
        var error: String?
        var errorDescription: String?
        var interval: Int?

        enum CodingKeys: String, CodingKey {
            case error, interval
            case accessToken = "access_token"
            case errorDescription = "error_description"
        }
    }

    func post(_ address: String, _ form: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Distiller", forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GitHubError.http(status: http.statusCode, message: String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }
}

/// Where the GitHub token is kept between launches.
public protocol GitHubTokenStore: Sendable {
    func load() -> String?
    func save(_ token: String) throws
    func delete() throws
}

/// Keeps the token in the login keychain, readable only by Distiller.
public struct KeychainTokenStore: GitHubTokenStore {
    public var service: String
    public var account: String

    public init(service: String = "Distiller GitHub", account: String = "github-token") {
        self.service = service
        self.account = account
    }

    #if canImport(Security)
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        try? delete()
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GitHubError.signIn("the token couldn't be saved in the keychain (\(status)).")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubError.signIn("the token couldn't be removed from the keychain (\(status)).")
        }
    }
    #else
    public func load() -> String? { nil }
    public func save(_ token: String) throws { throw GitHubError.signIn("no keychain on this platform.") }
    public func delete() throws {}
    #endif
}

/// For tests and `--token` use in the CLI.
public final class MemoryTokenStore: GitHubTokenStore, @unchecked Sendable {
    private var token: String?
    private let lock = NSLock()

    public init(token: String? = nil) { self.token = token }

    public func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func save(_ token: String) throws {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    public func delete() throws {
        lock.lock()
        token = nil
        lock.unlock()
    }
}
