import Foundation

/// A dotted version such as "24.0.7" or "11.0-rc1", compared numerically part by part.
/// Missing parts count as zero, so "11" == "11.0". Non-numeric suffixes are ignored.
public struct VersionNumber: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public let parts: [Int]

    public init(_ raw: String) {
        self.raw = raw
        self.parts = raw
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
            .map { piece in Int(piece.prefix(while: \.isNumber)) ?? 0 }
    }

    public var description: String { raw }

    private var normalized: [Int] {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        return trimmed
    }

    public static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let a = index < lhs.parts.count ? lhs.parts[index] : 0
            let b = index < rhs.parts.count ? rhs.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        lhs.normalized == rhs.normalized
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalized)
    }
}
