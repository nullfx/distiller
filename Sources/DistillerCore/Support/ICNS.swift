import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a macOS icon file (`.icns`) from one image: PNG entries at each size Finder and the
/// Dock use (16 to 1024 pixels), scaled with high-quality interpolation. The format is a list of
/// `type, length, data` entries after an `icns` header, lengths big-endian.
public enum ICNS {
    static let entries: [(type: String, size: Int)] = [
        ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
    ]

    public static func make(fromImage data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var body = Data()
        for entry in entries {
            guard let png = png(image, size: entry.size) else { return nil }
            body += Data(entry.type.utf8) + bigEndian(UInt32(8 + png.count)) + png
        }
        return Data("icns".utf8) + bigEndian(UInt32(8 + body.count)) + body
    }

    /// The entry types and their PNG data, for checking a file.
    static func read(_ data: Data) -> [(type: String, png: Data)]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, String(decoding: bytes[0..<4], as: UTF8.self) == "icns",
              Int(uint32(bytes, 4)) == bytes.count else { return nil }
        var result: [(String, Data)] = []
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = Int(uint32(bytes, offset + 4))
            guard length >= 8, offset + length <= bytes.count else { return nil }
            result.append((String(decoding: bytes[offset..<offset + 4], as: UTF8.self), Data(bytes[offset + 8..<offset + length])))
            offset += length
        }
        return result
    }

    static func png(_ image: CGImage, size: Int) -> Data? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Square, centred, keeping the image's proportions.
        let scale = CGFloat(size) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    static func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
