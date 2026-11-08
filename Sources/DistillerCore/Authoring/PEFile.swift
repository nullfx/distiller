import Foundation

/// Reads the little Distiller needs from a Windows executable: its CPU architecture and
/// the DLLs it imports. Nothing in the file is executed or trusted beyond these reads,
/// and every offset is bounds-checked, so a damaged or hostile file just yields nil.
public struct PEFile: Equatable, Sendable {
    public enum Machine: String, Codable, Sendable {
        case x86 = "i386"
        case x64 = "x86_64"
        case arm64
        case other

        init(code: UInt16) {
            switch code {
            case 0x014C: self = .x86
            case 0x8664: self = .x64
            case 0xAA64: self = .arm64
            default: self = .other
            }
        }
    }

    public var machine: Machine
    /// Imported DLL names, lowercased, including delay-loaded ones.
    public var imports: Set<String>
    /// True for .NET assemblies, which import only mscoree.dll and carry a CLR header.
    public var isDotNet: Bool

    public init(machine: Machine, imports: Set<String>, isDotNet: Bool) {
        self.machine = machine
        self.imports = imports
        self.isDotNet = isDotNet
    }

    public static func read(_ url: URL) -> PEFile? {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> PEFile? {
        guard let image = PEImage(data: data) else { return nil }
        let reader = image.reader
        let imageBase = image.imageBase
        func directory(_ index: Int) -> (rva: UInt32, size: UInt32)? { image.directory(index) }
        func offset(ofRVA rva: UInt32) -> Int? { image.offset(ofRVA: rva) }

        var imports: Set<String> = []
        if let table = directory(1), let start = offset(ofRVA: table.rva) {
            for index in 0..<4096 {
                let entry = start + index * 20
                guard let nameRVA = reader.u32(entry + 12),
                      let thunk = reader.u32(entry), let first = reader.u32(entry + 16) else { break }
                if nameRVA == 0 && thunk == 0 && first == 0 { break }
                if let nameOffset = offset(ofRVA: nameRVA), let name = reader.cString(nameOffset) {
                    imports.insert(name.lowercased())
                }
            }
        }
        if let table = directory(13), let start = offset(ofRVA: table.rva) {
            for index in 0..<4096 {
                let entry = start + index * 32
                guard let attributes = reader.u32(entry), let rawName = reader.u32(entry + 4) else { break }
                if attributes == 0 && rawName == 0 { break }
                // Old-style descriptors hold virtual addresses rather than RVAs.
                let nameRVA: UInt32
                if attributes & 1 == 1 {
                    nameRVA = rawName
                } else {
                    let address = UInt64(rawName)
                    guard address >= imageBase, address - imageBase <= UInt64(UInt32.max) else { continue }
                    nameRVA = UInt32(address - imageBase)
                }
                if let nameOffset = offset(ofRVA: nameRVA), let name = reader.cString(nameOffset) {
                    imports.insert(name.lowercased())
                }
            }
        }

        return PEFile(machine: Machine(code: image.machineCode), imports: imports, isDotNet: directory(14) != nil)
    }
}

/// The headers of a PE file: section table and data directories, with RVA-to-offset mapping.
/// Every read is bounds-checked.
struct PEImage {
    let reader: ByteReader
    let machineCode: UInt16
    let imageBase: UInt64
    private let directoriesOffset: Int
    private let directoryCount: Int
    private let sections: [(virtualAddress: UInt32, virtualSize: UInt32, rawOffset: UInt32, rawSize: UInt32)]

    init?(data: Data) {
        let reader = ByteReader(data: data)
        guard reader.u16(0) == 0x5A4D, let peOffset = reader.u32(0x3C).map(Int.init),
              reader.u32(peOffset) == 0x0000_4550 else { return nil }

        let coff = peOffset + 4
        guard let machineCode = reader.u16(coff),
              let sectionCount = reader.u16(coff + 2),
              let optionalSize = reader.u16(coff + 16) else { return nil }
        let optional = coff + 20
        guard let magic = reader.u16(optional) else { return nil }
        let isPE32Plus: Bool
        switch magic {
        case 0x10B: isPE32Plus = false
        case 0x20B: isPE32Plus = true
        default: return nil
        }
        self.reader = reader
        self.machineCode = machineCode
        self.imageBase = isPE32Plus
            ? (reader.u64(optional + 24) ?? 0)
            : UInt64(reader.u32(optional + 28) ?? 0)
        self.directoryCount = Int(reader.u32(optional + (isPE32Plus ? 108 : 92)) ?? 0)
        self.directoriesOffset = optional + (isPE32Plus ? 112 : 96)

        var sections: [(virtualAddress: UInt32, virtualSize: UInt32, rawOffset: UInt32, rawSize: UInt32)] = []
        let sectionTable = optional + Int(optionalSize)
        for index in 0..<min(Int(sectionCount), 96) {
            let base = sectionTable + index * 40
            guard let virtualSize = reader.u32(base + 8),
                  let virtualAddress = reader.u32(base + 12),
                  let rawSize = reader.u32(base + 16),
                  let rawOffset = reader.u32(base + 20) else { break }
            sections.append((virtualAddress, virtualSize, rawOffset, rawSize))
        }
        self.sections = sections
    }

    /// Data directory `index` (1 imports, 2 resources, 13 delay imports, 14 CLR).
    func directory(_ index: Int) -> (rva: UInt32, size: UInt32)? {
        guard index < directoryCount,
              let rva = reader.u32(directoriesOffset + index * 8),
              let size = reader.u32(directoriesOffset + index * 8 + 4),
              rva != 0 else { return nil }
        return (rva, size)
    }

    func offset(ofRVA rva: UInt32) -> Int? {
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            if rva >= section.virtualAddress, rva < section.virtualAddress &+ span {
                let delta = rva - section.virtualAddress
                guard delta < section.rawSize else { return nil }
                return Int(section.rawOffset) + Int(delta)
            }
        }
        return nil
    }
}

/// Bounds-checked little-endian reads.
struct ByteReader {
    let data: Data

    func u16(_ offset: Int) -> UInt16? { integer(offset, size: 2).map { UInt16(truncatingIfNeeded: $0) } }
    func u32(_ offset: Int) -> UInt32? { integer(offset, size: 4).map { UInt32(truncatingIfNeeded: $0) } }
    func u64(_ offset: Int) -> UInt64? { integer(offset, size: 8) }
    func u8(_ offset: Int) -> UInt8? { integer(offset, size: 1).map { UInt8(truncatingIfNeeded: $0) } }

    func bytes(_ offset: Int, count: Int) -> Data? {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else { return nil }
        let start = data.startIndex + offset
        return Data(data[start..<start + count])
    }

    private func integer(_ offset: Int, size: Int) -> UInt64? {
        guard offset >= 0, offset + size <= data.count else { return nil }
        var value: UInt64 = 0
        let start = data.startIndex + offset
        for index in 0..<size {
            value |= UInt64(data[start + index]) << (8 * UInt64(index))
        }
        return value
    }

    /// An ASCII name of at most 255 characters.
    func cString(_ offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var bytes: [UInt8] = []
        var index = data.startIndex + offset
        while index < data.endIndex, bytes.count < 256 {
            let byte = data[index]
            if byte == 0 { break }
            guard byte >= 0x20, byte < 0x7F else { return nil }
            bytes.append(byte)
            index += 1
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}
