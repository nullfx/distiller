import Foundation

/// The libraries a Mach-O file loads (`LC_LOAD_DYLIB` and its weak, re-export and lazy forms),
/// for checking that a Wine build has everything it needs before it's used. Bounds-checked;
/// reads the x86_64 slice of a universal file (Wine's), else arm64.
public enum MachODependencies {
    static let loadCommands: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x20]   // LOAD, WEAK, REEXPORT, LAZY_LOAD
    static let rpathCommand: UInt32 = 0x8000_001C                                    // LC_RPATH

    public static func libraries(of url: URL) -> [String]? {
        names(of: url, commands: loadCommands)
    }

    /// The file's own library search paths (`LC_RPATH`), as written (`@loader_path/…`).
    public static func searchPaths(of url: URL) -> [String]? {
        names(of: url, commands: [rpathCommand])
    }

    static func names(of url: URL, commands kinds: Set<UInt32>) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Load commands sit at the start of the slice; a universal header points to it.
        guard let head = try? handle.read(upToCount: 4096), let base = MachOExports.thinSlice(head) else { return nil }
        guard (try? handle.seek(toOffset: UInt64(base))) != nil, let header = try? handle.read(upToCount: 32),
              ByteReader(data: header).u32(0) == 0xFEED_FACF,
              let size = ByteReader(data: header).u32(20), size < 4 * 1024 * 1024,
              let commands = try? handle.read(upToCount: Int(size)) else { return nil }
        return names(inCommands: commands, count: Int(ByteReader(data: header).u32(16) ?? 0), kinds: kinds)
    }

    static func names(inCommands data: Data, count: Int, kinds: Set<UInt32>) -> [String]? {
        let reader = ByteReader(data: data)
        var names: [String] = []
        var offset = 0
        for _ in 0..<min(count, 1024) {
            guard let kind = reader.u32(offset), let size = reader.u32(offset + 4), size >= 8,
                  offset + Int(size) <= data.count else { return nil }
            if kinds.contains(kind), let nameOffset = reader.u32(offset + 8), Int(nameOffset) < Int(size),
               let bytes = reader.bytes(offset + Int(nameOffset), count: Int(size) - Int(nameOffset)) {
                let name = bytes.prefix { $0 != 0 }
                if let text = String(data: Data(name), encoding: .utf8) { names.append(text) }
            }
            offset += Int(size)
        }
        return names
    }

    /// Libraries a Wine build loads through `@rpath` that its programs can't find: for each
    /// missing name, the files that need it. A file finds `@rpath/X` in its own search paths
    /// (`@loader_path` is its folder; `@executable_path` is Wine's `bin`, where the programs
    /// that load it are) or in `fallback` (`DYLD_FALLBACK_LIBRARY_PATH`). Libraries Wine loads
    /// later inherit their loader's search paths too, so for its Unix-side libraries the
    /// folder they're in also counts. System libraries (absolute paths) are the Mac's.
    public static func missingRPathLibraries(in root: URL, fallback: [URL] = []) -> [String: [String]] {
        var needs: [String: Set<String>] = [:]
        let fileManager = FileManager.default
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        // The walk reports real paths (/private/var for /var), so trim the real root.
        let rootPath = root.resolvingSymlinksInPath().path + "/"
        func relative(_ url: URL) -> String {
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
        }
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [:] }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            let name = url.lastPathComponent
            let folder = url.deletingLastPathComponent()
            guard name.hasSuffix(".so") || name.hasSuffix(".dylib") || folder.lastPathComponent == "bin" else { continue }
            let wanted = (libraries(of: url) ?? []).filter { $0.hasPrefix("@rpath/") }
            guard !wanted.isEmpty else { continue }
            var places = (searchPaths(of: url) ?? []).map { path -> URL in
                if path.hasPrefix("@loader_path") {
                    return URL(fileURLWithPath: folder.path + path.dropFirst("@loader_path".count)).standardizedFileURL
                }
                if path.hasPrefix("@executable_path") {
                    return URL(fileURLWithPath: bin.path + path.dropFirst("@executable_path".count)).standardizedFileURL
                }
                return URL(fileURLWithPath: path)
            } + fallback
            if name.hasSuffix(".so") || name.hasSuffix(".dylib") { places.append(folder) }
            for library in wanted {
                let leaf = String(library.dropFirst("@rpath/".count))
                if places.contains(where: { fileManager.fileExists(atPath: $0.appendingPathComponent(leaf).path) }) { continue }
                needs[leaf.components(separatedBy: "/").last ?? leaf, default: []]
                    .insert(relative(url))
            }
        }
        return needs.mapValues { $0.sorted() }
    }

    /// Whether the build includes Apple's D3DMetal (its framework or shared library).
    public static func containsD3DMetal(_ root: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walker {
            let name = url.lastPathComponent.lowercased()
            if name == "d3dmetal.framework" || name.hasPrefix("libd3dshared") || name == "d3dmetal.dylib" { return true }
        }
        return false
    }
}
