import Foundation

/// Moving Wine and bottles between drives, and switching a copied game folder to the original.
extension DistillerEngine {
    public struct StorageMoveProgress: Sendable {
        public var message: String
    }

    /// Moves `kind`'s folders to `choice` and saves the new location in `settings.json`.
    ///
    /// The engine's paths are fixed when it is created, so make a new `DistillerEngine` after
    /// this returns. Nothing may be running from the old location while it moves.
    @discardableResult
    public static func moveStorage(
        _ kind: StorageKind,
        to choice: URL,
        paths: DistillerPaths,
        progress: @escaping @Sendable (StorageMoveProgress) -> Void = { _ in }
    ) async throws -> StorageSettings {
        let fileManager = FileManager.default
        let destination = StorageSettings.storageFolder(forChoice: choice)
        guard let volume = StorageVolume(containing: destination) else {
            throw DistillerError.storageUnavailable("\(destination.path) isn't on a connected drive.")
        }
        if !volume.problems.isEmpty {
            throw DistillerError.storageNotUsable(volume.problems.joined(separator: " "))
        }
        try paths.requireAvailable(kind)

        let source = paths.location(of: kind)
        var settings = StorageSettings.load(fromSupportFolder: paths.root)   // fresh: other switches may have changed since the engine started
        let samePlace = source.standardizedFileURL.resolvingSymlinksInPath().path
            == destination.standardizedFileURL.resolvingSymlinksInPath().path
        if !samePlace {
            let moves = kind.folderNames.map { (source.appendingPathComponent($0), destination.appendingPathComponent($0)) }
            for (_, target) in moves where fileManager.fileExists(atPath: target.path) && !isEmptyDirectory(target) {
                throw DistillerError.storageNotUsable(
                    "\(target.path) already exists and isn't empty. Choose another folder, or move that folder away first."
                )
            }
            let sourceVolume = StorageVolume(containing: source)
            let sameVolume = sourceVolume?.root.path == volume.root.path
            if !sameVolume {
                let needed = moves.reduce(Int64(0)) { $0 + allocatedSize(of: $1.0) }
                if let available = volume.availableBytes, needed > available {
                    let size = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                    throw DistillerError.storageNotUsable("Moving needs \(size), but only \(volume.availableDescription).")
                }
            }

            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for (from, to) in moves {
                guard fileManager.fileExists(atPath: from.path) else { continue }
                if fileManager.fileExists(atPath: to.path) { try fileManager.removeItem(at: to) }
                if sameVolume {
                    progress(StorageMoveProgress(message: "Moving \(from.lastPathComponent)…"))
                    try fileManager.moveItem(at: from, to: to)
                } else {
                    let size = ByteCountFormatter.string(fromByteCount: allocatedSize(of: from), countStyle: .file)
                    progress(StorageMoveProgress(message: "Copying \(from.lastPathComponent) (\(size)) to \(volume.name)…"))
                    let partial = to.deletingLastPathComponent().appendingPathComponent(".\(to.lastPathComponent).partial")
                    if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
                    // copyItem keeps symlinks as symlinks, which Wine prefixes rely on.
                    try fileManager.copyItem(at: from, to: partial)
                    try fileManager.moveItem(at: partial, to: to)
                    progress(StorageMoveProgress(message: "Removing the old \(from.lastPathComponent)…"))
                    try fileManager.removeItem(at: from)
                }
            }
        }

        let isDefault = destination.standardizedFileURL.path == paths.root.standardizedFileURL.path
        switch kind {
        case .wine: settings.wineLocation = isDefault ? nil : destination.path
        case .bottles: settings.bottlesLocation = isDefault ? nil : destination.path
        }
        settings.locationsConfirmed = true
        try settings.save(toSupportFolder: paths.root)
        return settings
    }

    /// Records that the player has seen and accepted the storage locations.
    public static func confirmStorageLocations(paths: DistillerPaths) throws {
        var settings = StorageSettings.load(fromSupportFolder: paths.root)   // fresh: other switches may have changed since the engine started
        settings.locationsConfirmed = true
        try settings.save(toSupportFolder: paths.root)
    }

    /// What switching a game's copied folder to the original would change.
    public struct FolderComparison: Sendable {
        /// Files in the bottle's copy that the original lacks or has with another size. They
        /// are lost when the copy is removed: often saves or settings the game wrote.
        public var onlyInCopy: [String]
        /// Files the original has that the copy doesn't.
        public var onlyInOriginal: [String]
        public var copyBytes: Int64

        public var matches: Bool { onlyInCopy.isEmpty }
    }

    /// The Windows-side folder a game's `user_folder` step put in its bottle.
    public func userFolderLocation(of game: Game, stepID: String? = nil) throws -> (step: InstallStep.UserFolder, url: URL) {
        let steps = (game.recipe.install ?? []).compactMap { step -> InstallStep.UserFolder? in
            if case .userFolder(let folder) = step { return folder }
            return nil
        }
        let step: InstallStep.UserFolder?
        if let stepID {
            step = steps.first { $0.id == stepID }
        } else {
            step = steps.count == 1 ? steps.first : nil
        }
        guard let step else {
            throw DistillerError.invalidRecipe(stepID.map { "it has no user_folder step with id \($0)." }
                ?? "it needs exactly one user_folder step, or name the step to use.")
        }
        let bottle = try bottles.bottle(id: game.bottleID)
        return (step, try BottlePath.resolve(step.to, in: bottles.root(of: bottle)))
    }

    /// Compares the copy in the bottle with the original folder, file by file (path and size).
    public func compareFolderCopy(of game: Game, with original: URL, stepID: String? = nil) throws -> FolderComparison {
        let copy = try userFolderLocation(of: game, stepID: stepID).url
        let copyFiles = Self.fileSizes(in: copy)
        let originalFiles = Self.fileSizes(in: original)
        let onlyInCopy = copyFiles.filter { originalFiles[$0.key] != $0.value }.map(\.key).sorted()
        let onlyInOriginal = originalFiles.keys.filter { copyFiles[$0] == nil }.sorted()
        return FolderComparison(onlyInCopy: onlyInCopy, onlyInOriginal: onlyInOriginal, copyBytes: Self.allocatedSize(of: copy))
    }

    /// Replaces the game's copied folder with a link to `original`, mapping its drive
    /// (D:, E:, …) when it's on another volume. Deletes the copy, so call
    /// `compareFolderCopy` first. Returns the folder's Windows path, such as `D:\GW2`.
    @discardableResult
    public func useFolderInPlace(for game: Game, original: URL, stepID: String? = nil) throws -> String {
        try paths.requireAvailable(.bottles)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: original.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DistillerError.storageUnavailable("The folder \(original.path) can't be found.")
        }
        let (_, destination) = try userFolderLocation(of: game, stepID: stepID)
        let fileManager = FileManager.default
        if APFSClone.isSymlink(destination) || fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: original)
        let bottle = try bottles.bottle(id: game.bottleID)
        let windowsPath = try DriveMapper.mapVolume(of: original, in: bottles.prefix(of: bottle))
        return windowsPath ?? (BottlePath.windowsPath(for: destination, in: bottles.root(of: bottle)) ?? destination.path)
    }

    // MARK: Helpers

    /// Disk space a file or folder takes, counting each file once.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func fileSizes(in folder: URL) -> [String: Int64] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents.count
        guard let enumerator = FileManager.default.enumerator(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: Array(keys)) else {
            return [:]
        }
        var sizes: [String: Int64] = [:]
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let relative = item.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            sizes[relative] = Int64(values.fileSize ?? 0)
        }
        return sizes
    }

    private static func isEmptyDirectory(_ url: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return contents.allSatisfy { $0 == ".DS_Store" }
    }
}
