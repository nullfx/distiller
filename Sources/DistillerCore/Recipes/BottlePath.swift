import Foundation

/// Turns a path written in a recipe into a location inside one bottle.
///
/// Accepted forms:
/// - `cache/…` — the bottle's download cache
/// - `drive_c/…` — the prefix's C: drive
/// - `C:\…` or `C:/…` — the same C: drive, written the Windows way
///
/// Everything else, including absolute host paths, other drive letters, `~` and `..`,
/// is rejected. Every install step goes through this one check.
public enum BottlePath {
    public static func resolve(_ path: String, in bottleRoot: URL) throws -> URL {
        var text = path.replacingOccurrences(of: "\\", with: "/")
        let base: URL

        if text.count >= 2, let first = text.first, first.isLetter, text.dropFirst().first == ":" {
            guard first.lowercased() == "c" else { throw DistillerError.pathEscapesBottle(path) }
            text = String(text.dropFirst(2))
            base = bottleRoot.appendingPathComponent("prefix/drive_c", isDirectory: true)
        } else if text == "drive_c" || text.hasPrefix("drive_c/") {
            text = String(text.dropFirst("drive_c".count))
            base = bottleRoot.appendingPathComponent("prefix/drive_c", isDirectory: true)
        } else if text == "cache" || text.hasPrefix("cache/") {
            text = String(text.dropFirst("cache".count))
            base = bottleRoot.appendingPathComponent("cache", isDirectory: true)
        } else {
            throw DistillerError.pathEscapesBottle(path)
        }

        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix("~") }) else {
            throw DistillerError.pathEscapesBottle(path)
        }
        return parts.reduce(base) { url, part in url.appendingPathComponent(String(part)) }
    }

    /// True for a folder on drive C: below its root and outside `C:\windows`, such as
    /// `C:\Games\Example`. Used for steps that place a whole folder, so they can't replace
    /// the drive or Wine's own files.
    public static func isInsideDriveC(_ path: String) -> Bool {
        let text = path.replacingOccurrences(of: "\\", with: "/")
        let rest: Substring
        if text.count >= 2, text.first?.lowercased() == "c", text.dropFirst().first == ":" {
            rest = text.dropFirst(2)
        } else if text.hasPrefix("drive_c/") {
            rest = text.dropFirst("drive_c".count)
        } else {
            return false
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first else { return false }
        return first.lowercased() != "windows"
    }

    /// The Windows form of a location inside a bottle's C: drive, such as
    /// `C:\Games\Example\Game.exe`. Returns nil for anything outside `prefix/drive_c`.
    public static func windowsPath(for url: URL, in bottleRoot: URL) -> String? {
        let driveC = bottleRoot.appendingPathComponent("prefix/drive_c", isDirectory: true).standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count >= driveC.count, Array(target.prefix(driveC.count)) == driveC else { return nil }
        return windowsPath(relativeComponents: Array(target.dropFirst(driveC.count)))
    }

    /// `["Games", "Example", "Game.exe"]` becomes `C:\Games\Example\Game.exe`.
    public static func windowsPath(relativeComponents: [String]) -> String {
        "C:\\" + relativeComponents.joined(separator: "\\")
    }

    /// Joins a Windows folder and a relative path that may use either slash.
    public static func join(_ windowsFolder: String, _ relative: String) -> String {
        let base = windowsFolder.hasSuffix("\\") ? String(windowsFolder.dropLast()) : windowsFolder
        let tail = relative.replacingOccurrences(of: "/", with: "\\")
            .split(separator: "\\", omittingEmptySubsequences: true)
            .joined(separator: "\\")
        return tail.isEmpty ? base : base + "\\" + tail
    }
}
