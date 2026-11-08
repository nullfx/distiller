import Foundation

/// Maps Mac volumes to Windows drive letters in a prefix's `dosdevices` folder, the way
/// winecfg does: `d:` is a symlink to the volume's root.
///
/// Games the player uses in place from another drive get that drive mapped, starting at D:.
/// A game then sees its real drive, so free-space checks and paths report that drive rather
/// than C:.
///
/// Verified with Wine Staging 11.21: Wine itself adds letters for removable volumes as pairs
/// (`d:` → `/Volumes/X` plus `d::` → `/dev/rdiskN`) and re-adds them at the next free letter
/// each time it starts. Those dynamic letters are treated as free, so Distiller's mappings
/// start at D: and stay put, and Wine moves its own letters out of the way.
public enum DriveMapper {
    /// D: to Y:. C: is the bottle's own drive and Z: is the Mac's root.
    static let assignableLetters: [Character] = Array("defghijklmnopqrstuvwxy")

    public struct Mapping: Equatable, Sendable {
        public var letter: Character
        public var target: String
        /// Added by Wine for a removable volume; Wine manages and may move it.
        public var isDynamic: Bool
    }

    public static func mappings(in prefix: URL) -> [Mapping] {
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: dosdevices.path)) ?? []
        let deviceLetters = Set(names.filter { $0.count == 3 && $0.hasSuffix("::") }.compactMap(\.first))
        return names
            .filter { $0.count == 2 && $0.hasSuffix(":") }
            .compactMap { name -> Mapping? in
                guard let letter = name.first?.lowercased().first,
                      let target = try? fileManager.destinationOfSymbolicLink(atPath: dosdevices.appendingPathComponent(name).path)
                else { return nil }
                return Mapping(letter: letter, target: target, isDynamic: deviceLetters.contains(letter))
            }
            .sorted { $0.letter < $1.letter }
    }

    /// The drive letter mapped to `volumeRoot`, mapping it to the first free letter from D:
    /// if needed. A letter Wine added on its own for a removable volume counts as free.
    @discardableResult
    public static func ensureDrive(for volumeRoot: URL, in prefix: URL) throws -> Character {
        let target = volumeRoot.standardizedFileURL.path
        let current = mappings(in: prefix)
        if let existing = current.first(where: { !$0.isDynamic && normalized($0.target) == normalized(target) }) {
            return existing.letter
        }
        let taken = Set(current.filter { !$0.isDynamic }.map(\.letter))
        guard let letter = assignableLetters.first(where: { !taken.contains($0) }) else {
            throw DistillerError.noFreeDriveLetter
        }
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        for name in ["\(letter):", "\(letter)::"] {
            let item = dosdevices.appendingPathComponent(name)
            if APFSClone.isSymlink(item) || FileManager.default.fileExists(atPath: item.path) {
                try FileManager.default.removeItem(at: item)
            }
        }
        try FileManager.default.createSymbolicLink(
            atPath: dosdevices.appendingPathComponent("\(letter):").path, withDestinationPath: target
        )
        return letter
    }

    /// Maps the volume holding `folder` when it isn't the startup disk, and returns the
    /// folder's Windows path on that drive, such as `D:\GW2`. Nil for the startup disk,
    /// which Wine already reaches through Z:.
    @discardableResult
    public static func mapVolume(of folder: URL, in prefix: URL) throws -> String? {
        guard let volume = StorageVolume(containing: folder), !volume.isStartupDisk else { return nil }
        let letter = try ensureDrive(for: volume.root, in: prefix)
        return windowsPath(of: folder, onDrive: letter, volumeRoot: volume.root)
    }

    static func windowsPath(of folder: URL, onDrive letter: Character, volumeRoot: URL) -> String {
        let rootParts = volumeRoot.standardizedFileURL.pathComponents
        let parts = folder.standardizedFileURL.pathComponents.dropFirst(rootParts.count)
        return "\(letter.uppercased()):\\" + parts.joined(separator: "\\")
    }

    /// Removes the letters Wine added on its own for removable volumes. Used on new template
    /// prefixes, so bottles don't inherit whatever disk images happened to be mounted.
    public static func removeDynamicDrives(in prefix: URL) throws {
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        for mapping in mappings(in: prefix) where mapping.isDynamic {
            for name in ["\(mapping.letter):", "\(mapping.letter)::"] {
                let item = dosdevices.appendingPathComponent(name)
                if APFSClone.isSymlink(item) { try FileManager.default.removeItem(at: item) }
            }
        }
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
