import XCTest
@testable import DistillerCore

final class DistillerVersionTests: XCTestCase {
    func testReadsTheVersionBundleAppWrites() {
        let info: [String: Any] = ["CFBundleIdentifier": "com.nullfx.distiller", "CFBundleShortVersionString": "0.2.0", "DistillerVersion": "0.2.0-beta.1"]
        XCTAssertEqual(DistillerVersion.version(fromInfo: info), "0.2.0-beta.1", "The full version, with its suffix")
        XCTAssertEqual(DistillerVersion.version(fromInfo: ["CFBundleIdentifier": "com.nullfx.distiller", "CFBundleShortVersionString": "0.1.0"]), "0.1.0")
        XCTAssertNil(DistillerVersion.version(fromInfo: ["CFBundleIdentifier": "com.apple.dt.xctest.tool", "CFBundleShortVersionString": "16.0"]), "Not another app's")
        XCTAssertNil(DistillerVersion.version(fromInfo: nil))
    }

    /// VERSION is the single source of the version; release.yml and bundle-app.sh read it.
    func testVersionFileIsAVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression), "VERSION holds \(version), not major.minor.revision")
    }

    /// Scripts/next-version.sh: VERSION's major.minor with the revision after the newest release.
    func testNextReleaseVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        func next(version: String, tags: [String], major: String? = nil, minor: String? = nil) throws -> String {
            try (version + "\n").write(to: work.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
            try tags.joined(separator: "\n").write(to: work.appendingPathComponent("tags"), atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("Scripts/next-version.sh").path, "--tags-file", work.appendingPathComponent("tags").path]
                + (major.map { ["--major", $0] } ?? []) + (minor.map { ["--minor", $0] } ?? [])
            process.environment = ["VERSION_FILE": work.appendingPathComponent("VERSION").path, "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try next(version: "1.0.0", tags: []), "1.0.0", "The first release of a major.minor")
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.0.0"]), "1.0.1")
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v0.9.9", "v1.0.0", "v1.0.4", "v1.0.2"]), "1.0.5", "One past the newest, in any order")
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.0.9", "v1.0.10"]), "1.0.11", "Compared as numbers")
        XCTAssertEqual(try next(version: "1.1.0", tags: ["v1.0.5"]), "1.1.0", "A new minor starts again")
        XCTAssertEqual(try next(version: "1.0.7", tags: ["v1.0.3"]), "1.0.7", "VERSION's revision is the floor")
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.0.3-beta", "v1.0", "v1.1"]), "1.0.0", "Only v<major>.<minor>.<n> tags count")
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.0.4", "v11.0.20"]), "11.0.21", "11.0 is not 1.0")

        // The newest release carries a newer major.minor without editing VERSION.
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.0.4", "v1.1.0"]), "1.1.1")
        XCTAssertEqual(try next(version: "1.2.0", tags: ["v1.1.3"]), "1.2.0", "A newer VERSION still wins")

        // The Release run's Major and Minor fields.
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.0.0"], minor: "1"), "1.1.0")
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.0.0"], major: "2"), "2.0.0", "A new major starts the minor at 0")
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.0.0"], major: "2", minor: "3"), "2.3.0")
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.0.0"], major: "1"), "1.0.1", "The same major keeps the minor")
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.0.0", "v1.1.0"], minor: "1"), "1.1.1", "An existing major.minor continues")
        XCTAssertEqual(try next(version: "1.0.7", tags: [], minor: "0"), "1.0.7", "VERSION's revision still counts for its own major.minor")
        XCTAssertEqual(try next(version: "1.0.0", tags: ["v1.1.0"], minor: "0"), "", "Older than a release: refused")
        XCTAssertEqual(try next(version: "1.0.0", tags: [], minor: "x"), "", "Not a number: refused")
    }
}
