import Foundation
import XCTest
@testable import DistillerCore

enum Macs {
    static let m1Air = HardwareProfile(
        chip: "Apple M1", chipFamily: "M1", chipTier: "Base", performanceCores: 4, efficiencyCores: 4,
        gpuCores: 8, memoryGB: 8, macOS: "26.4", rosetta: true
    )
    static let m3Pro = HardwareProfile(
        chip: "Apple M3 Pro", chipFamily: "M3", chipTier: "Pro", performanceCores: 6, efficiencyCores: 6,
        gpuCores: 18, memoryGB: 18, macOS: "27.1", rosetta: true
    )
    static let m4NoRosetta = HardwareProfile(
        chip: "Apple M4", chipFamily: "M4", chipTier: "Base", performanceCores: 4, efficiencyCores: 6,
        gpuCores: 10, memoryGB: 16, macOS: "28.0", rosetta: false
    )
}

func fixtureURL(_ name: String, _ ext: String) throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"), "Missing fixture \(name).\(ext)")
}

func loadFixtureRecipe(_ name: String) throws -> Recipe {
    try RecipeLoader.load(from: fixtureURL(name, "yaml"))
}

/// The sample recipe with one line of YAML swapped, for testing rejections.
func sampleYAML(replacing target: String, with replacement: String) throws -> String {
    let yaml = try String(contentsOf: fixtureURL("d3dmetal", "yaml"), encoding: .utf8)
    XCTAssertTrue(yaml.contains(target), "Fixture no longer contains \(target)")
    return yaml.replacingOccurrences(of: target, with: replacement)
}


/// Installs a stand-in Wine build (an executable `bin/wine` and a `lib/` folder) so games
/// in tests can reach "ready". `family: "any"` recipes accept it.
@discardableResult
func installFakeWine(into engine: DistillerEngine, id: String = "wine-staging", version: String = "11.21") throws -> InstalledComponent {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-fake-wine-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: source) }
    try FileManager.default.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("lib/wine"), withIntermediateDirectories: true)
    try Data("wine".utf8).write(to: source.appendingPathComponent("bin/wine"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("bin/wine").path)
    return try engine.components.importDirectory(source, manifest: ComponentManifest(
        id: id, kind: .wine, version: version, displayName: "Wine \(version)", arch: .x86_64, family: "winehq"
    ))
}
