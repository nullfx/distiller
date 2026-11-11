import Foundation

/// Distiller's settings: where it keeps its large data, plus app-wide switches. Stored as
/// `settings.json` in the Distiller support folder, which the app, the CLI and `distiller mcp`
/// all read.
///
/// - `wineLocation` holds `Components/` (Wine builds, graphics layers, winetricks and the
///   composed Wine + graphics builds).
/// - `bottlesLocation` holds `Bottles/` and `Templates/`. They stay together because a new
///   bottle is an APFS clone of a template, and clones only work within one volume.
///
/// The library, logs, recipe cache and this file always stay in the support folder, so
/// Distiller can start and explain itself when an external drive isn't connected.
public struct StorageSettings: Codable, Equatable, Sendable {
    public var wineLocation: String?
    public var bottlesLocation: String?
    /// Set once the player has confirmed locations, so setup asks only on first run.
    public var locationsConfirmed: Bool?
    /// Whether `distiller mcp` serves its troubleshooting tools to AI assistants. Off until the
    /// player turns it on (Settings ▸ AI Assistant, or `distiller assistant on`).
    public var assistantEnabled: Bool?
    /// Logs older than this many days are removed (0 keeps them). Nil means the default.
    public var logRetentionDays: Int?
    /// The most the Logs folder may hold, in megabytes; the oldest go first (0 means no limit).
    /// Nil means the default.
    public var logLimitMB: Int?
    /// Whether Distiller checks for newer Wine builds, graphics layers and winetricks, and
    /// whether it installs them by itself. Nil means the default (`ask`).
    public var componentUpdates: ComponentUpdateMode?
    /// Versions the player chose as active, by component id ("wine-staging": "11.21"). A
    /// component with no choice uses its newest installed version.
    public var activeComponents: [String: String]?
    /// When Distiller last looked for component updates.
    public var lastComponentCheck: Date?
    /// How long a restore point (a bottle's copy from before it moved to a newer Wine) is kept:
    /// days, or `RestorePointRetention.untilConfirmed` / `.untilRemoved`. Nil means 7 days.
    public var restorePointDays: Int?

    enum CodingKeys: String, CodingKey {
        case wineLocation = "wine_location"
        case bottlesLocation = "bottles_location"
        case locationsConfirmed = "locations_confirmed"
        case assistantEnabled = "assistant_enabled"
        case logRetentionDays = "log_retention_days"
        case logLimitMB = "log_limit_mb"
        case componentUpdates = "component_updates"
        case activeComponents = "active_components"
        case lastComponentCheck = "last_component_check"
        case restorePointDays = "restore_point_days"
    }

    public init(wineLocation: String? = nil, bottlesLocation: String? = nil, locationsConfirmed: Bool? = nil, assistantEnabled: Bool? = nil) {
        self.wineLocation = wineLocation
        self.bottlesLocation = bottlesLocation
        self.locationsConfirmed = locationsConfirmed
        self.assistantEnabled = assistantEnabled
    }

    public var isAssistantEnabled: Bool { assistantEnabled ?? false }

    public static let defaultLogRetentionDays = 14
    public static let defaultLogLimitMB = 1024
    public var effectiveLogRetentionDays: Int { max(0, logRetentionDays ?? Self.defaultLogRetentionDays) }
    public var effectiveLogLimitMB: Int { max(0, logLimitMB ?? Self.defaultLogLimitMB) }
    public var effectiveComponentUpdates: ComponentUpdateMode { componentUpdates ?? .ask }
    public var effectiveRestorePointDays: Int { restorePointDays ?? RestorePointRetention.defaultDays }

    public static let fileName = "settings.json"

    public static func load(fromSupportFolder root: URL) -> StorageSettings {
        let file = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(StorageSettings.self, from: data) else {
            return StorageSettings()
        }
        return settings
    }

    public func save(toSupportFolder root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// The folder Distiller uses when the player chooses `folder`. A volume's root gets a
    /// `Distiller` folder, so nothing lands loose at the top of a drive.
    public static func storageFolder(forChoice folder: URL) -> URL {
        let folder = folder.standardizedFileURL
        if let volume = StorageVolume(containing: folder), volume.root.standardizedFileURL.path == folder.path {
            return folder.appendingPathComponent("Distiller", isDirectory: true)
        }
        return folder
    }
}

/// Which of Distiller's two movable locations.
public enum StorageKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case wine, bottles

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .wine: return "Wine and tools"
        case .bottles: return "Bottles"
        }
    }

    public var purpose: String {
        switch self {
        case .wine: return "Wine builds, D3DMetal and winetricks. About 2 GB per Wine build."
        case .bottles: return "Each game's Windows drive (C:), including games copied into it."
        }
    }

    /// The folders inside the location that belong to this kind.
    public var folderNames: [String] {
        switch self {
        case .wine: return ["Components"]
        case .bottles: return ["Bottles", "Templates"]
        }
    }
}

/// Facts about the volume a folder is on, read from the file system.
public struct StorageVolume: Equatable, Sendable {
    public var root: URL
    public var name: String
    /// "APFS", "Mac OS Extended (Journaled)", "ExFAT" and so on.
    public var format: String
    public var isStartupDisk: Bool
    public var isInternal: Bool
    public var isCaseSensitive: Bool
    public var supportsCloning: Bool
    public var availableBytes: Int64?

    public init(
        root: URL, name: String, format: String, isStartupDisk: Bool, isInternal: Bool,
        isCaseSensitive: Bool, supportsCloning: Bool, availableBytes: Int64?
    ) {
        self.root = root
        self.name = name
        self.format = format
        self.isStartupDisk = isStartupDisk
        self.isInternal = isInternal
        self.isCaseSensitive = isCaseSensitive
        self.supportsCloning = supportsCloning
        self.availableBytes = availableBytes
    }

    /// The volume holding `url`, or the nearest existing folder above it. Nil when no part of
    /// the path exists, for example a drive that isn't connected.
    public init?(containing url: URL) {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { return nil }
            probe = parent
        }
        // A missing /Volumes/<name> leaves only /Volumes, which is on the startup disk.
        // That would hide a disconnected drive, so treat it as no volume.
        if let name = Self.volumeName(inVolumesPath: url), !FileManager.default.fileExists(atPath: "/Volumes/\(name)") {
            return nil
        }
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey,
            .volumeIsInternalKey, .volumeSupportsCaseSensitiveNamesKey, .volumeSupportsFileCloningKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? probe.resourceValues(forKeys: keys), let root = values.volume else { return nil }
        self.root = root
        self.name = values.volumeName ?? root.lastPathComponent
        self.format = values.volumeLocalizedFormatDescription ?? "Unknown format"
        self.isStartupDisk = values.volumeIsRootFileSystem ?? (root.path == "/")
        self.isInternal = values.volumeIsInternal ?? false
        self.isCaseSensitive = values.volumeSupportsCaseSensitiveNames ?? false
        self.supportsCloning = values.volumeSupportsFileCloning ?? false
        self.availableBytes = values.volumeAvailableCapacityForImportantUsage
    }

    /// "big-drive" for "/Volumes/big-drive/Games"; nil for paths outside /Volumes.
    public static func volumeName(inVolumesPath url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return parts[2]
    }

    /// Wine needs symlinks, Unix permissions and case-insensitive names. APFS and Mac OS
    /// Extended provide them; ExFAT and FAT don't (ExFAT only emulates symlinks).
    public var isMacFormat: Bool {
        let lower = format.lowercased()
        return lower.contains("apfs") || lower.contains("mac os extended") || lower.contains("hfs")
    }

    /// Reasons this volume can't hold Distiller data. Empty when it can.
    public var problems: [String] {
        var problems: [String] = []
        if !isMacFormat {
            problems.append("\(name) is formatted as \(format). Wine needs APFS or Mac OS Extended.")
        }
        if isCaseSensitive {
            problems.append("\(name) is case-sensitive. Windows programs expect file names that ignore case, so many games break on it.")
        }
        return problems
    }

    /// Advice that doesn't block using the volume.
    public var warnings: [String] {
        isMacFormat && !supportsCloning
            ? ["\(name) can't make instant copies (APFS clones), so each new bottle copies about 300 MB."]
            : []
    }

    public var availableDescription: String {
        guard let availableBytes else { return name }
        return "\(ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)) free on \(name)"
    }
}

/// A storage location that can't be used right now.
public struct UnavailableStorage: Equatable, Sendable {
    public var kind: StorageKind
    public var location: URL
    /// The drive name when the location is on a drive that isn't connected.
    public var volumeName: String?

    public var message: String {
        if let volumeName {
            return "\(kind.displayName) are on “\(volumeName)”, which isn't connected. Connect it, or choose another location in Settings."
        }
        return "\(kind.displayName) folder \(location.path) can't be found."
    }
}
