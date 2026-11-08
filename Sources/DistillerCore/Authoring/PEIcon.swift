import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads a Windows program's icon from its resources and rebuilds it as an `.ico` file.
///
/// A program's icon is an RT_GROUP_ICON resource (a directory of sizes) whose entries point
/// at RT_ICON resources (the images, either bitmaps or PNGs). Windows shows the first group
/// in the resource directory, so Distiller does too. As with `PEFile`, every offset is
/// bounds-checked and sizes are capped, so a damaged or hostile file yields nil.
public enum PEIcon {
    static let iconType: UInt32 = 3
    static let groupIconType: UInt32 = 14
    static let maxImageBytes = 4 * 1024 * 1024
    static let maxImages = 64

    public static func ico(fromExecutable url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return nil }
        return ico(fromExecutableData: data)
    }

    public static func ico(fromExecutableData data: Data) -> Data? {
        guard let image = PEImage(data: data), let resources = Resources(image: image) else { return nil }
        guard let group = resources.first(ofType: groupIconType).flatMap({ resources.data(of: $0) }) else { return nil }
        let reader = ByteReader(data: group)
        guard reader.u16(0) == 0, reader.u16(2) == 1, let count = reader.u16(4).map(Int.init), count > 0 else { return nil }

        var entries: [(header: Data, image: Data)] = []
        for index in 0..<min(count, maxImages) {
            let entry = 6 + index * 14
            guard let header = reader.bytes(entry, count: 12), let id = reader.u16(entry + 12),
                  let image = resources.entry(type: iconType, id: UInt32(id)).flatMap({ resources.data(of: $0) }),
                  !image.isEmpty else { continue }
            entries.append((header, image))
        }
        guard !entries.isEmpty else { return nil }

        // ICONDIR, then 16-byte ICONDIRENTRYs (the group's 14-byte entries with a file offset
        // in place of the resource ID), then the images.
        var ico = Data()
        ico.appendLittleEndian(UInt16(0))
        ico.appendLittleEndian(UInt16(1))
        ico.appendLittleEndian(UInt16(entries.count))
        var offset = 6 + 16 * entries.count
        for entry in entries {
            ico.append(entry.header.prefix(8))                  // width, height, colours, reserved, planes, bit count
            ico.appendLittleEndian(UInt32(entry.image.count))   // bytes in this image
            ico.appendLittleEndian(UInt32(offset))
            offset += entry.image.count
        }
        for entry in entries { ico.append(entry.image) }
        return ico
    }

    /// The largest image in an icon or image file, as PNG data. Reads `.ico`, `.icns`, PNG,
    /// JPEG and the other formats ImageIO knows.
    public static func png(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var best = 0
        var bestWidth = 0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if width > bestWidth {
                best = index
                bestWidth = width
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, best, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The resource tree: type → name or ID → language → data.
    struct Resources {
        let image: PEImage
        let root: Int

        struct Entry {
            var id: UInt32?
            var dataEntryOffset: Int
        }

        init?(image: PEImage) {
            guard let directory = image.directory(2), let root = image.offset(ofRVA: directory.rva) else { return nil }
            self.image = image
            self.root = root
        }

        /// (id, child offset, is a subdirectory) for each entry of the directory at `offset`.
        private func children(_ offset: Int) -> [(id: UInt32?, target: Int, isDirectory: Bool)] {
            let reader = image.reader
            guard let named = reader.u16(offset + 12), let ids = reader.u16(offset + 14) else { return [] }
            var result: [(UInt32?, Int, Bool)] = []
            for index in 0..<min(Int(named) + Int(ids), 4096) {
                let entry = offset + 16 + index * 8
                guard let name = reader.u32(entry), let target = reader.u32(entry + 4) else { break }
                let id: UInt32? = name & 0x8000_0000 == 0 ? name : nil
                result.append((id, root + Int(target & 0x7FFF_FFFF), target & 0x8000_0000 != 0))
            }
            return result
        }

        /// Resources of `type`, in directory order (named ones first, as Windows stores them).
        func all(ofType type: UInt32) -> [Entry] {
            guard let typeDirectory = children(root).first(where: { $0.id == type && $0.isDirectory }) else { return [] }
            return children(typeDirectory.target).compactMap { item -> Entry? in
                guard item.isDirectory else { return Entry(id: item.id, dataEntryOffset: item.target) }
                guard let language = children(item.target).first(where: { !$0.isDirectory }) else { return nil }
                return Entry(id: item.id, dataEntryOffset: language.target)
            }
        }

        func first(ofType type: UInt32) -> Entry? { all(ofType: type).first }

        func entry(type: UInt32, id: UInt32) -> Entry? { all(ofType: type).first { $0.id == id } }

        func data(of entry: Entry) -> Data? {
            let reader = image.reader
            guard let rva = reader.u32(entry.dataEntryOffset), let size = reader.u32(entry.dataEntryOffset + 4),
                  size > 0, Int(size) <= PEIcon.maxImageBytes,
                  let offset = image.offset(ofRVA: rva) else { return nil }
            return reader.bytes(offset, count: Int(size))
        }
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
