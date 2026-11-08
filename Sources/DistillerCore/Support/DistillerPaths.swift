import Foundation

/// Every on-disk location Distiller uses.
///
/// `root` is the support folder (`~/Library/Application Support/Distiller`, or
/// `DISTILLER_HOME` when set, which keeps experiments and tests away from the real library).
/// It always holds the library, logs, recipe cache and `settings.json`. Wine builds and
/// bottles default to it too, but the player can put either on another drive
/// (`StorageSettings`).
public struct DistillerPaths: Sendable {
    public let root: URL
    public let storage: StorageSettings

    public init(root: URL? = nil, storage: StorageSettings? = nil) {
        let resolvedRoot: URL
        if let root {
            resolvedRoot = root
        } else if let override = ProcessInfo.processInfo.environment["DISTILLER_HOME"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            resolvedRoot = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            resolvedRoot = support.appendingPathComponent("Distiller", isDirectory: true)
        }
        self.root = resolvedRoot
        self.storage = storage ?? StorageSettings.load(fromSupportFolder: resolvedRoot)
    }

    /// The folder holding `kind`'s data: the chosen location, or the support folder.
    public func location(of kind: StorageKind) -> URL {
        let chosen: String?
        switch kind {
        case .wine: chosen = storage.wineLocation
        case .bottles: chosen = storage.bottlesLocation
        }
        guard let chosen, !chosen.isEmpty else { return root }
        return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath, isDirectory: true)
    }

    public var components: URL { location(of: .wine).appendingPathComponent("Components", isDirectory: true) }
    /// Wine builds with a graphics layer merged in, built on demand by `StackComposer`.
    public var composedComponents: URL { components.appendingPathComponent("_composed", isDirectory: true) }
    public var templates: URL { location(of: .bottles).appendingPathComponent("Templates", isDirectory: true) }
    public var bottles: URL { location(of: .bottles).appendingPathComponent("Bottles", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var recipeCache: URL { root.appendingPathComponent("RecipeCache", isDirectory: true) }
    public var libraryFile: URL { root.appendingPathComponent("library.json") }
    /// Game icons, kept with the library so they show while a game's drive is disconnected.
    public var icons: URL { root.appendingPathComponent("Icons", isDirectory: true) }
    /// The icon and screenshot from each game's last community check, in a folder per game.
    public var communityMedia: URL { root.appendingPathComponent("CommunityMedia", isDirectory: true) }

    /// Locations that can't be used now, such as a drive that isn't connected.
    public var unavailable: [UnavailableStorage] {
        StorageKind.allCases.compactMap { kind in
            let location = location(of: kind)
            if let volume = StorageVolume.volumeName(inVolumesPath: location),
               !FileManager.default.fileExists(atPath: "/Volumes/\(volume)") {
                return UnavailableStorage(kind: kind, location: location, volumeName: volume)
            }
            return nil
        }
    }

    /// Throws a clear message when `kind`'s location is on a drive that isn't connected.
    public func requireAvailable(_ kind: StorageKind) throws {
        if let missing = unavailable.first(where: { $0.kind == kind }) {
            throw DistillerError.storageUnavailable(missing.message)
        }
    }

    /// Creates the folders Distiller needs. Folders on a disconnected drive are skipped, so
    /// nothing is created in their place; `unavailable` reports them.
    public func ensureDirectories() throws {
        let missing = Set(unavailable.map(\.kind))
        var directories = [root, logs, recipeCache, icons]
        if !missing.contains(.wine) { directories.append(components) }
        if !missing.contains(.bottles) { directories += [templates, bottles] }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
