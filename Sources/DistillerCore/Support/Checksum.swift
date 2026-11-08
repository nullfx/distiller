import CryptoKit
import Foundation

public enum Checksum {
    /// Streams the file through SHA-256 so large archives don't load into memory.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ url: URL, expected: String) throws {
        let actual = try sha256(of: url)
        guard actual.lowercased() == expected.lowercased() else {
            throw DistillerError.checksumMismatch(expected: expected.lowercased(), actual: actual)
        }
    }
}
