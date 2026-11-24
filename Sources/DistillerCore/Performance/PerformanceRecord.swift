import Foundation

/// The game's own settings during a recording, which only the player knows.
public struct PlaySettings: Codable, Equatable, Sendable {
    public enum Detail: String, Codable, CaseIterable, Sendable {
        case low, medium, high, ultra, custom
        public var displayName: String { rawValue.capitalized }
    }

    public enum FrameLimit: String, Codable, CaseIterable, Sendable {
        case none, vsync, cap
        public var displayName: String {
            switch self {
            case .none: return "None"
            case .vsync: return "Vsync"
            case .cap: return "Frame cap"
            }
        }
    }

    public enum Upscaling: String, Codable, CaseIterable, Sendable {
        case none, metalfx, fsr, other
        public var displayName: String {
            switch self {
            case .none: return "None"
            case .metalfx: return "MetalFX"
            case .fsr: return "FSR"
            case .other: return "Other"
            }
        }
    }

    public var detail: Detail?
    public var frameLimit: FrameLimit?
    /// The cap, when `frameLimit` is `cap`.
    public var capFPS: Int?
    /// The game's rendering resolution when it's lower than its window ("1920x1080").
    public var renderResolution: String?
    public var upscaling: Upscaling?

    enum CodingKeys: String, CodingKey {
        case detail, upscaling
        case frameLimit = "frame_limit"
        case capFPS = "cap_fps"
        case renderResolution = "render"
    }

    public init(detail: Detail? = nil, frameLimit: FrameLimit? = nil, capFPS: Int? = nil,
                renderResolution: String? = nil, upscaling: Upscaling? = nil) {
        self.detail = detail
        self.frameLimit = frameLimit
        self.capFPS = capFPS
        self.renderResolution = renderResolution
        self.upscaling = upscaling
    }

    /// "1920x1080" style, 3 to 5 digits each side, or nil.
    public static func isResolution(_ text: String) -> Bool {
        text.range(of: "^[0-9]{3,5}x[0-9]{3,5}$", options: .regularExpression) != nil
    }
}

/// Where the game was shown: its window's size in pixels and the screen's refresh rate (a game
/// held to the refresh rate by vsync can't go faster).
public struct DisplayInfo: Codable, Equatable, Sendable {
    public var refreshHz: Int?
    /// "3024x1964", in pixels.
    public var window: String?

    enum CodingKeys: String, CodingKey {
        case window
        case refreshHz = "refresh_hz"
    }

    public init(refreshHz: Int?, window: String?) {
        self.refreshHz = refreshHz
        self.window = window
    }
}

/// A recorded stretch of play, kept on this Mac (`DistillerPaths.performance`) until the
/// player reports it or removes it. Nothing here leaves the Mac by itself.
public struct PerformanceRecord: Codable, Equatable, Sendable, Identifiable {
    public var schema = 1
    public var id: String
    public var gameID: String
    public var recipeID: String
    public var gameSlug: String
    public var title: String
    public var recordedAt: Date
    public var summary: PerformanceSummary
    public var settings: PlaySettings
    public var display: DisplayInfo?
    /// "id@version" of the Wine build and graphics layer.
    public var wine: String?
    public var graphics: String?
    public var hardwareKey: String

    enum CodingKeys: String, CodingKey {
        case schema, id, title, summary, settings, display, wine, graphics
        case gameID = "game_id"
        case recipeID = "recipe_id"
        case gameSlug = "game_slug"
        case recordedAt = "recorded_at"
        case hardwareKey = "hardware_key"
    }
}

extension DistillerEngine {
    /// A record of a recording of `game`, with this Mac and the game's components filled in.
    public func performanceRecord(for game: Game, summary: PerformanceSummary, settings: PlaySettings,
                                  display: DisplayInfo?, at date: Date = Date()) -> PerformanceRecord {
        let stack = try? selectStack(for: game)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return PerformanceRecord(
            id: stamp, gameID: game.id, recipeID: game.recipe.id, gameSlug: game.recipe.game.slug,
            title: game.title, recordedAt: date, summary: summary, settings: settings, display: display,
            wine: stack.map { $0.wine.manifest.composedFrom?.first ?? $0.wine.id },
            graphics: stack?.graphics?.id, hardwareKey: hardware.hardwareKey
        )
    }

    public func savePerformanceRecord(_ record: PerformanceRecord) throws -> URL {
        let folder = paths.performance.appendingPathComponent(record.gameID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(record.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
        return url
    }

    /// A game's saved recordings, newest first.
    public func performanceRecords(for gameID: String) -> [PerformanceRecord] {
        let folder = paths.performance.appendingPathComponent(gameID, isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(PerformanceRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.recordedAt > $1.recordedAt }
    }
}
