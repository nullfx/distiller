import Foundation

/// The libraries a Mach-O file loads (`LC_LOAD_DYLIB` and its weak, re-export and lazy forms),
/// for checking that a Wine build has everything it needs before it's used. Bounds-checked;
/// reads the x86_64 slice of a universal file (Wine's), else arm64.
public enum MachODependencies {
    static let loadCommands: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x20]   // LOAD, WEAK, REEXPORT, LAZY_LOAD

    public static func libraries(of url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Load commands sit at the start of the slice; a universal header points to it.
        guard let head = try? handle.read(upToCount: 4096), let base = MachOExports.thinSlice(head) else { return nil }
        guard (try? handle.seek(toOffset: UInt64(base))) != nil, let header = try? handle.read(upToCount: 32),
              ByteReader(data: header).u32(0) == 0xFEED_FACF,
              let size = ByteReader(data: header).u32(20), size < 4 * 1024 * 1024,
              let commands = try? handle.read(upToCount: Int(size)) else { return nil }
        return libraries(inCommands: commands, count: Int(ByteReader(data: header).u32(16) ?? 0))
    }

    static func libraries(inCommands data: Data, count: Int) -> [String]? {
        let reader = ByteReader(data: data)
        var names: [String] = []
        var offset = 0
        for _ in 0..<min(count, 1024) {
            guard let kind = reader.u32(offset), let size = reader.u32(offset + 4), size >= 8,
                  offset + Int(size) <= data.count else { return nil }
            if loadCommands.contains(kind), let nameOffset = reader.u32(offset + 8), Int(nameOffset) < Int(size),
               let bytes = reader.bytes(offset + Int(nameOffset), count: Int(size) - Int(nameOffset)) {
                let name = bytes.prefix { $0 != 0 }
                if let text = String(data: Data(name), encoding: .utf8) { names.append(text) }
            }
            offset += Int(size)
        }
        return names
    }

    /// Libraries a Wine build loads through `@rpath` that it doesn't have: for each missing
    /// name, the files that need it. Wine's Unix side finds them next to itself
    /// (`@loader_path`), so a name counts as present when a file with that name is anywhere in
    /// the build; system libraries (absolute paths) are the Mac's.
    public static func missingRPathLibraries(in root: URL) -> [String: [String]] {
        var present = Set<String>()
        var needs: [String: Set<String>] = [:]
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [:] }
        for case let url as URL in walker {
            present.insert(url.lastPathComponent)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            let name = url.lastPathComponent
            guard name.hasSuffix(".so") || name.hasSuffix(".dylib") || url.deletingLastPathComponent().lastPathComponent == "bin" else { continue }
            for library in libraries(of: url) ?? [] where library.hasPrefix("@rpath/") {
                needs[String(library.dropFirst("@rpath/".count)).components(separatedBy: "/").last ?? library, default: []]
                    .insert(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        return needs.filter { !present.contains($0.key) }.mapValues { $0.sorted() }
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
