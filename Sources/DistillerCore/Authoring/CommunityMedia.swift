import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pictures that go with a shared recipe: the game's icon (read from its program) and a
/// screenshot from the community check's test run. Both are re-encoded here, which also drops
/// any metadata, and kept within the limits `distiller-recipes/scripts/build_index.py`
/// enforces; keep the two in sync.
public enum CommunityMedia {
    /// Icons are square PNGs, 32–256 pixels a side.
    public static let iconMinPixels = 32
    public static let iconMaxPixels = 256
    public static let iconMaxBytes = 256 * 1024
    /// Screenshots are JPEGs, 320–1600 pixels wide.
    public static let screenshotMinWidth = 320
    public static let screenshotMaxWidth = 1600
    public static let screenshotMaxBytes = 600 * 1024

    /// Captures kept from one community check, and how many of them a recipe can share
    /// (the first shared one is its cover).
    public static let maxCaptures = 12
    public static let maxSharedScreenshots = 3

    public static let iconFile = "icon.png"
    /// The name of the check's nth capture (1-based) in the game's media folder.
    public static func captureFile(_ number: Int) -> String { "capture-\(number).jpg" }

    /// The largest image in an icon or image file, scaled down to at most 256 pixels, as PNG.
    /// Nil when there's no square image of at least 32 pixels.
    public static func icon(from data: Data) -> Data? {
        guard let png = PEIcon.png(fromImageData: data),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == image.height, image.width >= iconMinPixels else { return nil }
        let side = min(image.width, iconMaxPixels)
        guard let scaled = draw(image, width: side, height: side, opaque: false),
              let encoded = encode(scaled, as: .png, quality: nil),
              encoded.count <= iconMaxBytes else { return nil }
        return encoded
    }

    /// A screenshot scaled to at most 1600 pixels wide, flattened onto black (window captures
    /// can have transparent corners) and saved as a JPEG under 600 KB. Nil when it's too small.
    public static func screenshot(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width >= screenshotMinWidth, image.height >= 1 else { return nil }
        let width = min(image.width, screenshotMaxWidth)
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let scaled = draw(image, width: width, height: height, opaque: true) else { return nil }
        for quality in [0.85, 0.75, 0.65, 0.5, 0.35] {
            if let encoded = encode(scaled, as: .jpeg, quality: quality), encoded.count <= screenshotMaxBytes {
                return encoded
            }
        }
        return nil
    }

    private static func draw(_ image: CGImage, width: Int, height: Int, opaque: Bool) -> CGImage? {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if opaque {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(rect)
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
