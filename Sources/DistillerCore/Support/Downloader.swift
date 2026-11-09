import Foundation
import Security

public enum Downloader {
    /// Downloads over HTTPS, verifies the SHA-256 and only then moves the file into place.
    public static func download(_ url: URL, sha256: String, to destination: URL, session: URLSession = .shared) async throws {
        guard url.scheme?.lowercased() == "https" else {
            throw DistillerError.insecureURL(url.absoluteString)
        }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DistillerError.processFailed(command: "Download of \(url.absoluteString)", status: Int32(http.statusCode), logFile: nil)
        }
        try Checksum.verify(temporary, expected: sha256)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Downloads over HTTPS, verifies the program's Authenticode signature by `signer` (for
    /// installers that change with every update) and only then moves the file into place.
    /// `anchors` replaces the system's trusted roots (tests).
    public static func download(_ url: URL, signer: String, to destination: URL, session: URLSession = .shared, anchors: [SecCertificate]? = nil) async throws {
        guard url.scheme?.lowercased() == "https" else {
            throw DistillerError.insecureURL(url.absoluteString)
        }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DistillerError.processFailed(command: "Download of \(url.absoluteString)", status: Int32(http.statusCode), logFile: nil)
        }
        do {
            _ = try Authenticode.verify(temporary, expectedSigner: signer, anchors: anchors)
        } catch {
            throw DistillerError.invalidRecipe("\(url.lastPathComponent) can't be trusted: \(error.localizedDescription)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Downloads over HTTPS without a known checksum and returns the SHA-256 of what arrived,
    /// so it can be recorded. Only for setup downloads from fixed, well-known HTTPS sources;
    /// recipe downloads always go through `download(_:sha256:to:)`.
    @discardableResult
    public static func download(_ url: URL, to destination: URL, session: URLSession = .shared) async throws -> String {
        guard url.scheme?.lowercased() == "https" else {
            throw DistillerError.insecureURL(url.absoluteString)
        }
        var request = URLRequest(url: url)
        request.setValue("Distiller", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DistillerError.processFailed(command: "Download of \(url.absoluteString)", status: Int32(http.statusCode), logFile: nil)
        }
        let sha = try Checksum.sha256(of: temporary)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return sha
    }
}
