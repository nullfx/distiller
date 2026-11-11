import Foundation

/// A copy of a bottle's prefix taken just before it moved to a newer Wine, so the move can be
/// undone: Wine updates a prefix in place and older builds can't use it afterwards. Kept in
/// `Bottles/<id>/restore/` (an APFS clone, on the same volume; it costs only what changes in
/// the live bottle afterwards), one per bottle.
public struct RestorePoint: Codable, Equatable, Sendable {
    public var createdAt: Date
    /// The Wine build ("id@version") the bottle was on, and the one it moved to.
    public var fromWine: String
    public var toWine: String
    /// When the player said the game works on the new Wine (kept only in "until I remove it").
    public var confirmedAt: Date?
    /// When Distiller asked whether the game works, so it asks once.
    public var askedAt: Date?

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case fromWine = "from_wine"
        case toWine = "to_wine"
        case confirmedAt = "confirmed_at"
        case askedAt = "asked_at"
    }

    public init(createdAt: Date, fromWine: String, toWine: String) {
        self.createdAt = createdAt
        self.fromWine = fromWine
        self.toWine = toWine
    }

    /// "Wine Staging 11.21"-style text for "id@version".
    public static func describe(_ wine: String) -> String {
        let parts = wine.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return wine }
        let name = parts[0].split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return "\(name) \(parts[1])"
    }
}

/// How long restore points are kept (`settings.json` `restore_point_days`).
public enum RestorePointRetention {
    /// Kept until the player says the game works (no time limit).
    public static let untilConfirmed = 0
    /// Kept until the player removes it, even after saying the game works.
    public static let untilRemoved = -1
    public static let defaultDays = 7
    public static let choices = [untilConfirmed, 1, 7, 30, untilRemoved]

    public static func describe(_ days: Int) -> String {
        switch days {
        case untilConfirmed: return "Until I confirm the game works"
        case untilRemoved: return "Until I remove it"
        case 1: return "Up to 1 day"
        default: return "Up to \(days) days"
        }
    }
}

extension BottleStore {
    func restoreFolder(of bottle: Bottle) -> URL {
        root(of: bottle).appendingPathComponent("restore", isDirectory: true)
    }

    /// The bottle's restore point, if it has a complete one.
    public func restorePoint(of bottle: Bottle) -> RestorePoint? {
        let folder = restoreFolder(of: bottle)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("prefix/system.reg").path),
              let data = try? Data(contentsOf: folder.appendingPathComponent("restore.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RestorePoint.self, from: data)
    }

    func saveRestorePoint(_ point: RestorePoint, of bottle: Bottle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(point).write(to: restoreFolder(of: bottle).appendingPathComponent("restore.json"), options: .atomic)
    }

    /// Clones the bottle's prefix as its restore point, replacing any older one.
    func makeRestorePoint(of bottle: Bottle, from: String, to: String, now: Date = Date()) throws -> RestorePoint {
        let folder = restoreFolder(of: bottle)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try APFSClone.cloneItem(at: prefix(of: bottle), to: folder.appendingPathComponent("prefix", isDirectory: true))
        // Whole seconds, as restore.json stores them.
        let point = RestorePoint(createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)), fromWine: from, toWine: to)
        try saveRestorePoint(point, of: bottle)
        return point
    }

    public func discardRestorePoint(of bottle: Bottle) throws {
        let folder = restoreFolder(of: bottle)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    /// Puts the restore point's prefix back in place of the current one.
    func restorePrefix(of bottle: Bottle) throws {
        let saved = restoreFolder(of: bottle).appendingPathComponent("prefix", isDirectory: true)
        let current = prefix(of: bottle)
        if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.removeItem(at: current) }
        try FileManager.default.moveItem(at: saved, to: current)
        try discardRestorePoint(of: bottle)
    }
}

extension DistillerEngine {
    /// The newer Wine a game's next run would move its bottle to, if any (not for games that
    /// stay on a Wine build).
    public func pendingWineMove(for game: Game) throws -> (from: String, to: InstalledComponent)? {
        let bottle = try bottles.bottle(id: game.bottleID)
        guard bottle.stayOn?.wine == nil else { return nil }
        let stack = try selectStack(for: resolve(game.recipe, overrides: game.overrides), bottle: bottle)
        let base = stack.wine.manifest.composedFrom?.first.flatMap(components.component(withID:)) ?? stack.wine
        let made = BottleWine(bottle.wine)
        guard VersionNumber(base.manifest.version) > VersionNumber(made.version) || base.manifest.id != made.id else { return nil }
        return (bottle.wine, base)
    }

    /// Before a run that would move `game`'s bottle to a newer Wine: saves a restore point,
    /// then updates the prefix with the new Wine (`wineboot -u`) so the game starts on an
    /// updated bottle. If the update fails, the restore point is put back and the error thrown.
    @discardableResult
    public func prepareWineMove(for game: Game, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> RestorePoint? {
        guard let move = try pendingWineMove(for: game) else { return nil }
        var bottle = try bottles.bottle(id: game.bottleID)
        let target = RestorePoint.describe(move.to.id)
        progress("Saving a restore point for \(game.title)…")
        let point = try bottles.makeRestorePoint(of: bottle, from: move.from, to: move.to.id)
        progress("Updating \(game.title)'s bottle to \(target)…")
        do {
            let resolved = resolve(game.recipe, overrides: game.overrides)
            let stack = try selectStack(for: resolved, bottle: bottle)
            let env = WineEnvironment.build(prefix: bottles.prefix(of: bottle), wine: stack.wine, graphics: stack.graphics, resolved: resolved)
            try await runner.wineCommand(["wineboot", "-u"], wine: stack.wine, environment: env, logName: "wineboot-update")
            try await runner.waitForServer(wine: stack.wine, environment: env)
        } catch {
            try? bottles.restorePrefix(of: bottle)
            throw DistillerError.setupFailed("\(game.title)'s bottle couldn't be updated to \(target), so it was put back as it was: \(error.localizedDescription)")
        }
        bottle.wine = move.to.id
        try bottles.save(bottle)
        return point
    }

    /// Puts back `game`'s restore point and keeps the game on the Wine it was on.
    public func rollBack(_ game: Game) async throws {
        var bottle = try bottles.bottle(id: game.bottleID)
        guard let point = bottles.restorePoint(of: bottle) else {
            throw DistillerError.setupFailed("\(game.title) has no restore point.")
        }
        guard components.installed().contains(where: { $0.id == point.fromWine }) else {
            throw DistillerError.componentNotFound("\(RestorePoint.describe(point.fromWine)), which \(game.title)'s restore point needs")
        }
        // Stop anything still running in the bottle (a launcher left behind, say).
        if let wine = components.component(withID: bottle.wine) {
            let env = WineEnvironment.build(prefix: bottles.prefix(of: bottle), wine: wine, graphics: nil, resolved: nil)
            try? await runner.killAll(wine: wine, environment: env)
        }
        try bottles.restorePrefix(of: bottle)
        bottle.wine = point.fromWine
        var stayOn = bottle.stayOn ?? Bottle.StayOn()
        stayOn.wine = point.fromWine
        bottle.stayOn = stayOn
        try bottles.save(bottle)
    }

    /// The player says `game` works on its new Wine: the restore point goes, unless they keep
    /// restore points until they remove them.
    public func confirmWineMove(_ game: Game, now: Date = Date()) throws {
        let bottle = try bottles.bottle(id: game.bottleID)
        guard var point = bottles.restorePoint(of: bottle) else { return }
        if StorageSettings.load(fromSupportFolder: paths.root).effectiveRestorePointDays == RestorePointRetention.untilRemoved {
            point.confirmedAt = now
            try bottles.saveRestorePoint(point, of: bottle)
        } else {
            try bottles.discardRestorePoint(of: bottle)
        }
    }

    /// Records that Distiller asked whether the game works, so it asks once.
    public func markRestorePointAsked(_ game: Game, now: Date = Date()) {
        guard let bottle = try? bottles.bottle(id: game.bottleID), var point = bottles.restorePoint(of: bottle) else { return }
        point.askedAt = now
        try? bottles.saveRestorePoint(point, of: bottle)
    }

    /// Removes restore points older than the player's limit. Returns how many it removed.
    @discardableResult
    public func expireRestorePoints(now: Date = Date()) -> Int {
        let days = StorageSettings.load(fromSupportFolder: paths.root).effectiveRestorePointDays
        guard days > 0 else { return 0 }
        var removed = 0
        for bottle in bottles.list() {
            guard let point = bottles.restorePoint(of: bottle),
                  now.timeIntervalSince(point.createdAt) > Double(days) * 24 * 60 * 60 else { continue }
            if (try? bottles.discardRestorePoint(of: bottle)) != nil { removed += 1 }
        }
        return removed
    }

    /// Wine builds restore points need (so clean-up keeps them).
    func winesNeededByRestorePoints() -> Set<String> {
        Set(bottles.list().compactMap { bottles.restorePoint(of: $0)?.fromWine })
    }
}
