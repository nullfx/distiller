import Foundation

/// A Wine prefix for one game.
public struct Bottle: Codable, Identifiable, Equatable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// "id@version" of the Wine build the bottle was created with.
    public var wine: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, wine
        case createdAt = "created_at"
    }

    public init(id: String, name: String, wine: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.wine = wine
        self.createdAt = createdAt
    }
}

/// Bottles live in `Bottles/<id>/` with `bottle.json`, `prefix/` and `cache/`.
///
/// New bottles are APFS clones of a template prefix made once per Wine build, so per-game
/// isolation costs almost no disk space and creating a bottle takes seconds.
public final class BottleStore: @unchecked Sendable {
    public let paths: DistillerPaths
    static let metadataName = "bottle.json"

    public init(paths: DistillerPaths) {
        self.paths = paths
    }

    public func list() -> [Bottle] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: paths.bottles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .compactMap { try? read(in: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func bottle(id: String) throws -> Bottle {
        do {
            return try read(in: paths.bottles.appendingPathComponent(id, isDirectory: true))
        } catch {
            throw DistillerError.bottleNotFound(id)
        }
    }

    public func root(of bottle: Bottle) -> URL {
        paths.bottles.appendingPathComponent(bottle.id, isDirectory: true)
    }

    public func prefix(of bottle: Bottle) -> URL {
        root(of: bottle).appendingPathComponent("prefix", isDirectory: true)
    }

    public func cache(of bottle: Bottle) -> URL {
        root(of: bottle).appendingPathComponent("cache", isDirectory: true)
    }

    public func save(_ bottle: Bottle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bottle).write(to: root(of: bottle).appendingPathComponent(Self.metadataName), options: .atomic)
    }

    /// Moves the bottle to the Trash, so a mistaken delete can be undone in Finder.
    public func delete(_ bottle: Bottle) throws {
        try FileManager.default.trashItem(at: root(of: bottle), resultingItemURL: nil)
    }

    public func makeBottle(name: String, wine: InstalledComponent, runner: WineRunner) async throws -> Bottle {
        try paths.requireAvailable(.bottles)
        let template = try await ensureTemplate(for: wine, runner: runner)
        let bottle = Bottle(id: Self.makeID(for: name), name: name, wine: wine.id, createdAt: Date())
        let bottleRoot = self.root(of: bottle)
        try FileManager.default.createDirectory(at: bottleRoot.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try APFSClone.cloneItem(at: template, to: prefix(of: bottle))
        try save(bottle)
        return bottle
    }

    /// Returns `Templates/<wine>/prefix`, creating it with wineboot the first time.
    func ensureTemplate(for wine: InstalledComponent, runner: WineRunner) async throws -> URL {
        let folder = paths.templates.appendingPathComponent("\(wine.manifest.id)-\(wine.manifest.version)", isDirectory: true)
        let template = folder.appendingPathComponent("prefix", isDirectory: true)
        if FileManager.default.fileExists(atPath: template.appendingPathComponent("system.reg").path) {
            return template
        }
        let partial = folder.appendingPathComponent("prefix.partial", isDirectory: true)
        if FileManager.default.fileExists(atPath: partial.path) {
            try FileManager.default.removeItem(at: partial)
        }
        try await runner.initializePrefix(partial, wine: wine)
        try Self.isolateUserFolders(in: partial)
        try DriveMapper.removeDynamicDrives(in: partial)
        if FileManager.default.fileExists(atPath: template.path) {
            try FileManager.default.removeItem(at: template)
        }
        try FileManager.default.moveItem(at: partial, to: template)
        return template
    }

    /// Wine links Documents, Desktop, Downloads and similar folders to the Mac's own.
    /// Replacing those links with real folders keeps each game's files inside its bottle.
    static func isolateUserFolders(in prefix: URL) throws {
        let fileManager = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let accounts = (try? fileManager.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? []
        for account in accounts {
            let items = (try? fileManager.contentsOfDirectory(at: account, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
            for item in items where APFSClone.isSymlink(item) {
                try fileManager.removeItem(at: item)
                try fileManager.createDirectory(at: item, withIntermediateDirectories: true)
            }
        }
    }

    static func makeID(for name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "\(slug.isEmpty ? "bottle" : String(slug.prefix(40)))-\(suffix)"
    }

    func read(in directory: URL) throws -> Bottle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Bottle.self, from: Data(contentsOf: directory.appendingPathComponent(Self.metadataName)))
    }
}
