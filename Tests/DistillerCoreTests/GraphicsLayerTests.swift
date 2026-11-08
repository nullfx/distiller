import Foundation
import XCTest
@testable import DistillerCore

final class GraphicsLayerTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-layers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    /// Asset names from the real releases (checked 2026-11-07).
    func testAssetPatternsPickTheBuiltinBuilds() throws {
        func version(_ name: String, _ source: GraphicsLayerSource) throws -> String? {
            EnvironmentSetup.version(in: name, matching: try NSRegularExpression(pattern: source.assetPattern))
        }
        XCTAssertEqual(try version("dxmt-v0.80-builtin.tar.gz", .dxmt), "0.80")
        XCTAssertNil(try version("dxmt-v0.80.tar.gz", .dxmt))
        XCTAssertEqual(try version("dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz", .dxvk), "1.10.3-20230507-repack")
        XCTAssertNil(try version("dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz", .dxvk), "The non-builtin build goes in the prefix instead")
        XCTAssertNil(try version("dxvk-macOS-async-v1.10.3-20230402-CrossOver.tar.gz", .dxvk))
    }

    func testSetupItemsMapToBackends() {
        XCTAssertEqual(SetupItem(graphics: .dxmt), .dxmt)
        XCTAssertEqual(SetupItem(graphics: .dxvk), .dxvk)
        XCTAssertEqual(SetupItem(graphics: .d3dmetal), .d3dmetal)
        XCTAssertNil(SetupItem(graphics: .wined3d))
        XCTAssertTrue(SetupItem.dxmt.canInstallAutomatically)
        XCTAssertFalse(SetupItem.d3dmetal.canInstallAutomatically)
        XCTAssertFalse(SetupItem.dxvk.isRequired)
    }

    /// DXMT wraps its folders in `v0.80/`; DXVK in a folder named after the asset.
    func testArchiveLayoutBecomesWineLib() throws {
        let extracted = work.appendingPathComponent("extracted/dxmt/v0.80", isDirectory: true)
        for (folder, file) in [("x86_64-windows", "d3d11.dll"), ("x86_64-windows", "winemetal.dll"), ("i386-windows", "d3d11.dll"), ("x86_64-unix", "winemetal.so")] {
            try FileManager.default.createDirectory(at: extracted.appendingPathComponent(folder), withIntermediateDirectories: true)
            try Data(file.utf8).write(to: extracted.appendingPathComponent("\(folder)/\(file)"))
        }
        let component = work.appendingPathComponent("component", isDirectory: true)
        try EnvironmentSetup.arrangeWineLib(from: work.appendingPathComponent("extracted"), into: component)

        for path in ["lib/wine/x86_64-windows/d3d11.dll", "lib/wine/x86_64-windows/winemetal.dll", "lib/wine/i386-windows/d3d11.dll", "lib/wine/x86_64-unix/winemetal.so"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: component.appendingPathComponent(path).path), path)
        }

        let empty = work.appendingPathComponent("not-wine", isDirectory: true)
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("x64"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try EnvironmentSetup.arrangeWineLib(from: empty, into: work.appendingPathComponent("other")))
    }

    func testDXMTLicenceChangedAfter080() {
        XCTAssertEqual(GraphicsLayerSource.dxmt.license(forVersion: "0.80"), "MIT")
        XCTAssertEqual(GraphicsLayerSource.dxmt.license(forVersion: "0.74"), "MIT")
        XCTAssertEqual(GraphicsLayerSource.dxmt.license(forVersion: "0.81"), "LGPL-2.1-or-later")
        XCTAssertEqual(GraphicsLayerSource.dxvk.license(forVersion: "1.10.3-20230507-repack"), "Zlib")
    }

    /// DXMT's winemetal.dll goes into the bottle as well as Wine's lib (DXMT installation guide).
    func testWinemetalIsCopiedIntoTheBottle() throws {
        let layerDir = work.appendingPathComponent("dxmt", isDirectory: true)
        for arch in ["x86_64-windows", "i386-windows"] {
            try FileManager.default.createDirectory(at: layerDir.appendingPathComponent("lib/wine/\(arch)"), withIntermediateDirectories: true)
            try Data("winemetal \(arch)".utf8).write(to: layerDir.appendingPathComponent("lib/wine/\(arch)/winemetal.dll"))
            try Data("d3d11".utf8).write(to: layerDir.appendingPathComponent("lib/wine/\(arch)/d3d11.dll"))
        }
        // Installed before `also_in_prefix` existed: the DXMT default applies.
        let layer = InstalledComponent(manifest: ComponentManifest(
            id: "dxmt", kind: .graphics, version: "0.80", displayName: "DXMT 0.80", arch: .x86_64, provides: .dxmt, placement: .wineLib
        ), directory: layerDir)
        let prefix = work.appendingPathComponent("prefix", isDirectory: true)
        try GraphicsPlacer.installPrefixDLLs(layer, prefix: prefix)

        let windows = prefix.appendingPathComponent("drive_c/windows")
        XCTAssertEqual(try String(contentsOf: windows.appendingPathComponent("system32/winemetal.dll"), encoding: .utf8), "winemetal x86_64-windows")
        XCTAssertEqual(try String(contentsOf: windows.appendingPathComponent("syswow64/winemetal.dll"), encoding: .utf8), "winemetal i386-windows")
        XCTAssertFalse(FileManager.default.fileExists(atPath: windows.appendingPathComponent("system32/d3d11.dll").path), "Other DLLs stay builtin")
    }

    /// An installed layer is merged into a copy of the Wine build; the Wine build itself is untouched.
    func testLayerIsComposedIntoWine() throws {
        let store = ComponentStore(paths: DistillerPaths(root: work.appendingPathComponent("home"), storage: StorageSettings()))
        try store.paths.ensureDirectories()

        let wineSource = work.appendingPathComponent("wine-src", isDirectory: true)
        try FileManager.default.createDirectory(at: wineSource.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wineSource.appendingPathComponent("lib/wine/x86_64-windows"), withIntermediateDirectories: true)
        try Data("wine".utf8).write(to: wineSource.appendingPathComponent("bin/wine"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineSource.appendingPathComponent("bin/wine").path)
        try Data("wine's d3d11".utf8).write(to: wineSource.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"))
        let wine = try store.importDirectory(wineSource, manifest: ComponentManifest(
            id: "wine-staging", kind: .wine, version: "11.21", displayName: "Wine Staging 11.21", arch: .x86_64, family: "winehq"
        ))

        let layerSource = work.appendingPathComponent("layer-src", isDirectory: true)
        try FileManager.default.createDirectory(at: layerSource.appendingPathComponent("lib/wine/x86_64-windows"), withIntermediateDirectories: true)
        try Data("dxvk's d3d11".utf8).write(to: layerSource.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"))
        let layer = try store.importDirectory(layerSource, manifest: ComponentManifest(
            id: "dxvk-macos", kind: .graphics, version: "1.10.3-20230507-repack", displayName: "DXVK for macOS",
            arch: .x86_64, provides: .dxvk, placement: .wineLib
        ))

        let composed = try StackComposer.compose(wine: wine, graphics: layer, store: store)
        XCTAssertEqual(try String(contentsOf: composed.directory.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"), encoding: .utf8), "dxvk's d3d11")
        XCTAssertEqual(try String(contentsOf: wine.directory.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"), encoding: .utf8), "wine's d3d11")
        XCTAssertEqual(store.graphicsLayer(.dxvk)?.id, layer.id)
        XCTAssertTrue(store.availableGraphics().contains(.dxvk))
    }
}
