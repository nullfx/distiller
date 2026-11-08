import Foundation

/// Screenshots a game saved itself (with its own screenshot key) inside a bottle, such as
/// Guild Wars 2's `Documents/Guild Wars 2/Screens`. The community check collects them before
/// it deletes its test bottle, so they can be shared like the ones Distiller captures.
public enum InGameScreenshots {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "tga", "tif", "tiff"]
    static let minBytes = 10 * 1024
    static let maxBytes = 50 * 1024 * 1024
    static let maxDepth = 6

    /// Image files under the bottle's user folders (and `programFolder`, the launched program's
    /// folder, if given) modified at or after `since`, oldest first. Symbolic links aren't
    /// followed, so folders linked to the Mac (a linked game folder) aren't searched.
    public static func find(inPrefix prefix: URL, programFolder: URL? = nil, since: Date, limit: Int = CommunityMedia.maxCaptures) -> [URL] {
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        var found: [(url: URL, date: Date)] = []
        var seen: Set<String> = []
        for root in [users, programFolder].compactMap({ $0 }) {
            for (url, date) in images(under: root, since: since) where seen.insert(url.standardizedFileURL.path).inserted {
                found.append((url, date))
            }
        }
        return found.sorted { $0.date < $1.date }.prefix(limit).map(\.url)
    }

    private static func images(under root: URL, since: Date) -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return [] }
        var results: [(URL, Date)] = []
        for case let url as URL in walker {
            // The enumerator doesn't follow symbolic links; skipping only applies to folders.
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if walker.level >= maxDepth, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walker.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()),
                  let size = values?.fileSize, (minBytes...maxBytes).contains(size),
                  let date = values?.contentModificationDate, date >= since else { continue }
            results.append((url, date))
        }
        return results
    }
}
