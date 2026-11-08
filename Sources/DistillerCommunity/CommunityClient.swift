import Foundation
import DistillerCore

/// Where the community recipes live. Change `default` once you've created your repository.
public struct CommunityRepository: Sendable, Equatable {
    public var owner: String
    public var name: String
    public var branch: String
    public var indexURL: URL
    /// The client ID of the GitHub OAuth app players sign in with to submit recipes.
    /// Create it under Settings → Developer settings → OAuth Apps and enable Device Flow.
    /// A client ID isn't secret; the device flow needs no client secret.
    public var oauthClientID: String

    public static let `default` = CommunityRepository(
        owner: "nullfx",
        name: "distiller-recipes",
        // OAuth app "Distiller" owned by nullfx, with Device Flow enabled. Not a secret.
        oauthClientID: "Ov23lih4DJYuMgkFhytP"
    )

    public init(owner: String, name: String, branch: String = "main", indexURL: URL? = nil, oauthClientID: String = "") {
        self.owner = owner
        self.name = name
        self.branch = branch
        self.indexURL = indexURL ?? URL(string: "https://\(owner.lowercased()).github.io/\(name)/index.json")!
        self.oauthClientID = oauthClientID
    }

    /// "owner/name".
    public var fullName: String { "\(owner)/\(name)" }

    /// False while `default` still has its placeholders, so the app can explain instead of failing.
    public var isConfiguredForSubmissions: Bool {
        !owner.hasPrefix("YOUR-") && !oauthClientID.isEmpty && !oauthClientID.hasPrefix("YOUR-")
    }

    public var webURL: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
    /// Where a picture the index lists ("media/…") is published, next to the index.
    /// Nil for anything outside `media/`.
    public func mediaURL(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("media/"), !path.split(separator: "/").contains("..") else { return nil }
        return indexURL.deletingLastPathComponent().appendingPathComponent(path)
    }

    public var rawBaseURL: URL { URL(string: "https://raw.githubusercontent.com/\(owner)/\(name)/\(branch)/")! }
}

/// Reads the community index and recipes. It never writes: reports go through a
/// pre-filled GitHub issue form that the player submits in their browser, and recipes
/// through `RecipeSubmitter`, which opens a pull request from the player's own fork.
public final class CommunityClient: @unchecked Sendable {
    public let repository: CommunityRepository
    let cacheFile: URL
    let session: URLSession

    public init(repository: CommunityRepository = .default, paths: DistillerPaths, session: URLSession = .shared) {
        self.repository = repository
        self.cacheFile = paths.recipeCache.appendingPathComponent("index.json")
        self.session = session
    }

    public func cachedIndex() -> CommunityIndex? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? JSONDecoder().decode(CommunityIndex.self, from: data)
    }

    public func refreshIndex() async throws -> CommunityIndex {
        let (data, response) = try await session.data(from: repository.indexURL)
        try Self.checkStatus(response, url: repository.indexURL)
        let index = try JSONDecoder().decode(CommunityIndex.self, from: data)
        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheFile, options: .atomic)
        return index
    }

    public func fetchRecipe(_ recipe: IndexRecipe) async throws -> Recipe {
        try RecipeLoader.decode(yaml: try await fetchRecipeText(path: recipe.path))
    }

    /// A recipe file's YAML, exactly as published. Only paths in the `recipes/` folder.
    public func fetchRecipeText(path: String) async throws -> String {
        let parts = path.split(separator: "/")
        guard parts.first == "recipes", !parts.contains(".."), path.hasSuffix(".yaml") else {
            throw DistillerError.invalidRecipe("the index lists an unexpected path, \(path).")
        }
        let url = repository.rawBaseURL.appendingPathComponent(path)
        let (data, response) = try await session.data(from: url)
        try Self.checkStatus(response, url: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// A game's detail file (`games/<slug>.json`): its recipes' content and reports.
    public func fetchDetail(for game: IndexGame) async throws -> CommunityGameDetail {
        let path = game.detail ?? "games/\(game.slug).json"
        guard path == "games/\(game.slug).json" else {
            throw DistillerError.invalidRecipe("the index lists an unexpected detail file, \(path).")
        }
        let url = repository.indexURL.deletingLastPathComponent().appendingPathComponent(path)
        let (data, response) = try await session.data(from: url)
        try Self.checkStatus(response, url: url)
        return try JSONDecoder().decode(CommunityGameDetail.self, from: data)
    }

    /// A link to the repository's report issue form with everything filled in.
    /// Field names match the `id`s in `.github/ISSUE_TEMPLATE/report.yml`.
    public func reportURL(
        gameSlug: String,
        recipeID: String,
        hardware: HardwareProfile,
        tier: PlayabilityTier,
        averageFPS: Double?,
        wineVersion: String?,
        graphicsVersion: String?,
        notes: String
    ) -> URL {
        var components = URLComponents(string: repository.webURL.absoluteString + "/issues/new")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "template", value: "report.yml"),
            URLQueryItem(name: "title", value: "Report: \(gameSlug)/\(recipeID) on \(hardware.hardwareKey)"),
            URLQueryItem(name: "game_slug", value: gameSlug),
            URLQueryItem(name: "recipe_id", value: recipeID),
            URLQueryItem(name: "tier", value: tier.rawValue),
            URLQueryItem(name: "chip", value: hardware.chip),
            URLQueryItem(name: "chip_family", value: hardware.chipFamily),
            URLQueryItem(name: "chip_tier", value: hardware.chipTier),
            URLQueryItem(name: "memory_gb", value: String(hardware.memoryGB)),
            URLQueryItem(name: "macos", value: hardware.macOS),
            URLQueryItem(name: "rosetta", value: hardware.rosetta ? "true" : "false"),
            URLQueryItem(name: "notes", value: notes),
        ]
        if let gpu = hardware.gpuCores { items.append(URLQueryItem(name: "gpu_cores", value: String(gpu))) }
        if let averageFPS { items.append(URLQueryItem(name: "fps_avg", value: String(Int(averageFPS.rounded())))) }
        if let wineVersion { items.append(URLQueryItem(name: "wine_version", value: wineVersion)) }
        if let graphicsVersion { items.append(URLQueryItem(name: "graphics_version", value: graphicsVersion)) }
        components.queryItems = items
        return components.url!
    }

    static func checkStatus(_ response: URLResponse, url: URL) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DistillerError.processFailed(command: "Fetching \(url.absoluteString)", status: Int32(http.statusCode), logFile: nil)
        }
    }
}
