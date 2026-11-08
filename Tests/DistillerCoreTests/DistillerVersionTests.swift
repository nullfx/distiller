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
        XCTAssertNotNil(version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$"#, options: .regularExpression), "VERSION holds \(version)")
    }
}
