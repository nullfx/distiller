import Darwin
import Foundation

/// Copy-on-write copies. On APFS a clone shares disk blocks with its source until
/// either side changes, so cloning a 1 GB Wine prefix takes moments and almost no space.
public enum APFSClone {
    /// `CLONE_NOFOLLOW` from <sys/clonefile.h>: clone symlinks as symlinks.
    private static let cloneNoFollow: UInt32 = 0x0001

    /// Clones a file or a whole directory tree. Falls back to a normal copy on
    /// volumes that don't support cloning (for example, an external HFS+ drive).
    public static func cloneItem(at source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let status = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in
                clonefile(src!, dst!, cloneNoFollow)
            }
        }
        if status != 0 {
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    /// Clones `source` over `destination`, replacing whatever is there.
    /// Nothing to do when `source` already is `destination` (a file picked from the bottle's
    /// own folder): removing the destination first would delete the source.
    public static func replaceItem(at destination: URL, withCloneOf source: URL) throws {
        if isSameFile(source, destination) { return }
        if FileManager.default.fileExists(atPath: destination.path) || isSymlink(destination) {
            try FileManager.default.removeItem(at: destination)
        }
        try cloneItem(at: source, to: destination)
    }

    /// Whether two paths name the same file (same volume and inode), through links too.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        var first = stat(), second = stat()
        guard stat(a.path, &first) == 0, stat(b.path, &second) == 0 else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    public static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

extension URL {
    /// The path with every symlink along it followed, including a last link whose target is
    /// missing (unlike `resolvingSymlinksInPath()`, which stops there). That's what shows a
    /// game folder linked from a drive that isn't connected.
    public var followingSymlinks: URL {
        var result = URL(fileURLWithPath: "/")
        for component in standardizedFileURL.pathComponents.dropFirst() {
            result.appendPathComponent(component)
            var hops = 0
            while hops < 32, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: result.path) {
                result = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target)
                    : result.deletingLastPathComponent().appendingPathComponent(target)
                result = result.standardizedFileURL
                hops += 1
            }
        }
        return result
    }
}
