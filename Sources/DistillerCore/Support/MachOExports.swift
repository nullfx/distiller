import Foundation

/// Reads a Mach-O file's export trie to answer one question: does it export a symbol whose
/// name starts with a given prefix? Used to check whether a Wine build's `winemac.so` exports
/// the `macdrv_*` functions that D3DMetal and DXMT look up at run time.
///
/// Handles thin 64-bit files and fat files (the x86_64 slice, else arm64). Every read is
/// bounds-checked and the walk is capped, so a damaged file just yields nil.
public enum MachOExports {
    static let maxNodes = 200_000

    /// True or false when the file could be read; nil when it isn't a readable Mach-O.
    public static func hasExport(withPrefix prefix: String, in url: URL) -> Bool? {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return nil }
        return hasExport(withPrefix: prefix, inData: data)
    }

    public static func hasExport(withPrefix prefix: String, inData data: Data) -> Bool? {
        guard let slice = thinSlice(data), let trie = exportTrie(data, sliceOffset: slice) else { return nil }
        return trieHasPrefix(data, trie: trie, prefix: Array(prefix.utf8))
    }

    // MARK: Mach-O structure

    /// Offset of the 64-bit Mach-O to read: 0 for thin files, the chosen slice for fat ones.
    static func thinSlice(_ data: Data) -> Int? {
        let reader = ByteReader(data: data)
        guard let magic = reader.u32(0) else { return nil }
        if magic == 0xFEED_FACF { return 0 }
        // Fat headers are big-endian: CAFEBABE reads as BEBAFECA little-endian.
        guard magic == 0xBEBA_FECA, let count = reader.u32(4).map({ Int($0.byteSwapped) }), count <= 16 else { return nil }
        var arm64: Int?
        for index in 0..<count {
            let entry = 8 + index * 20
            guard let cpu = reader.u32(entry)?.byteSwapped, let offset = reader.u32(entry + 8)?.byteSwapped else { return nil }
            if cpu == 0x0100_0007 { return Int(offset) }        // x86_64
            if cpu == 0x0100_000C { arm64 = Int(offset) }       // arm64
        }
        return arm64
    }

    /// File offset and size of the export trie.
    static func exportTrie(_ data: Data, sliceOffset base: Int) -> (offset: Int, size: Int)? {
        let reader = ByteReader(data: data)
        guard reader.u32(base) == 0xFEED_FACF, let commandCount = reader.u32(base + 16) else { return nil }
        var command = base + 32
        for _ in 0..<min(Int(commandCount), 512) {
            guard let kind = reader.u32(command), let size = reader.u32(command + 4), size >= 8 else { return nil }
            switch kind {
            case 0x8000_0033:   // LC_DYLD_EXPORTS_TRIE (linkedit_data_command)
                guard let offset = reader.u32(command + 8), let length = reader.u32(command + 12) else { return nil }
                return (base + Int(offset), Int(length))
            case 0x22, 0x8000_0022:   // LC_DYLD_INFO, LC_DYLD_INFO_ONLY
                guard let offset = reader.u32(command + 40), let length = reader.u32(command + 44) else { return nil }
                if length > 0 { return (base + Int(offset), Int(length)) }
            default:
                break
            }
            command += Int(size)
        }
        return nil
    }

    /// Walks the trie along `prefix`. A symbol has the prefix if the walk consumes the whole
    /// prefix and reaches a node (whose subtree is non-empty), or an edge extends past it.
    static func trieHasPrefix(_ data: Data, trie: (offset: Int, size: Int), prefix: [UInt8]) -> Bool? {
        guard trie.size > 0, trie.offset >= 0, trie.offset + trie.size <= data.count else { return nil }
        let start = data.startIndex + trie.offset
        let end = start + trie.size
        var node = start
        var remaining = prefix[...]
        var visited = 0

        func uleb(_ position: inout Int) -> Int? {
            var result = 0
            var shift = 0
            while position < end, shift < 63 {
                let byte = data[position]
                position += 1
                result |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while visited < maxNodes {
            visited += 1
            if remaining.isEmpty { return true }
            var position = node
            guard let terminalSize = uleb(&position) else { return nil }
            position += terminalSize
            guard position < end else { return nil }
            let childCount = Int(data[position])
            position += 1
            var next: Int?
            for _ in 0..<childCount {
                var edge: [UInt8] = []
                while position < end, data[position] != 0 {
                    edge.append(data[position])
                    position += 1
                    if edge.count > 4096 { return nil }
                }
                position += 1
                guard let childOffset = uleb(&position) else { return nil }
                let common = zip(edge, remaining).prefix { $0 == $1 }.count
                if common == edge.count {
                    // The whole edge matches: continue below it.
                    next = start + childOffset
                    remaining = remaining.dropFirst(edge.count)
                    break
                }
                if common == remaining.count {
                    return true   // The edge runs past the end of the prefix.
                }
            }
            guard let next, next >= start, next < end else { return false }
            node = next
        }
        return nil
    }
}

/// What a Wine build can run.
public enum WineCapabilities {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool?] = [:]

    /// Graphics layers that need the Wine build's `winemac.so` to export `macdrv_*` functions
    /// (CrossOver-source Wine does; WineHQ builds hide them).
    public static let layersNeedingMacDriverExports: Set<GraphicsBackend> = [.d3dmetal, .dxmt]

    /// True when the Wine build exports `macdrv_*`; nil when `winemac.so` can't be found or read.
    public static func exportsMacDriverFunctions(_ wine: InstalledComponent) -> Bool? {
        let candidates = ["lib/wine/x86_64-unix/winemac.so", "lib/wine/x86_64-unix/winemac.drv.so", "lib/wine/aarch64-unix/winemac.so"]
        guard let library = candidates.map({ wine.directory.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        let modified = (try? library.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(library.path)#\(modified)"
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()
        let result = MachOExports.hasExport(withPrefix: "_macdrv_", in: library)
        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }

    /// Whether `wine` can run `backend`. Unknown (unreadable) counts as yes, so a check that
    /// can't be made never blocks a player.
    public static func canRun(_ backend: GraphicsBackend, on wine: InstalledComponent) -> Bool {
        guard layersNeedingMacDriverExports.contains(backend) else { return true }
        return exportsMacDriverFunctions(wine) ?? true
    }

    public static func whyNot(_ backend: GraphicsBackend) -> String {
        "\(backend.displayName) needs a CrossOver-based Wine build. Your Wine build hides the macOS driver functions it uses, so games would crash. Use DXVK, or import a CrossOver-based Wine build in Components."
    }
}
