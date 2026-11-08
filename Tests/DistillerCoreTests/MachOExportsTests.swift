import Foundation
import XCTest
@testable import DistillerCore

/// Builds a minimal 64-bit Mach-O whose only load command is LC_DYLD_EXPORTS_TRIE, with a
/// trie for "_macdrv_get_view", "_macdrv_view_create" and "_wine_call":
///   root --"_"--> A
///   A --"macdrv_"--> B --"get_view"--> leaf, --"view_create"--> leaf
///   A --"wine_call"--> leaf
enum TestMachO {
    static func make(fat: Bool = false, withMacDriver: Bool = true) -> Data {
        func uleb(_ value: Int) -> [UInt8] {
            var value = value
            var bytes: [UInt8] = []
            repeat {
                var byte = UInt8(value & 0x7F)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                bytes.append(byte)
            } while value != 0
            return bytes
        }
        let leaf: [UInt8] = [2, 0, 0x10, 0]   // terminal size 2 (flags, address), no children
        // Fixed offsets keep the ULEBs one byte long.
        let rootOffset = 0, aOffset = 16, bOffset = 64, leaf1 = 112, leaf2 = 120, leaf3 = 128
        var trie = [UInt8](repeating: 0, count: 136)
        func put(_ bytes: [UInt8], at offset: Int) { trie.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        put([0, 1] + Array("_".utf8) + [0] + uleb(aOffset), at: rootOffset)
        put([0, 2] + Array((withMacDriver ? "macdrv_" : "xacdrv_").utf8) + [0] + uleb(bOffset) + Array("wine_call".utf8) + [0] + uleb(leaf3), at: aOffset)
        put([0, 2] + Array("get_view".utf8) + [0] + uleb(leaf1) + Array("view_create".utf8) + [0] + uleb(leaf2), at: bOffset)
        put(leaf, at: leaf1); put(leaf, at: leaf2); put(leaf, at: leaf3)

        var macho = Data(count: 256)
        func put32(_ value: UInt32, _ offset: Int) { withUnsafeBytes(of: value.littleEndian) { macho.replaceSubrange(offset..<offset + 4, with: $0) } }
        put32(0xFEED_FACF, 0)
        put32(0x0100_0007, 4)      // x86_64
        put32(6, 12)               // MH_DYLIB
        put32(1, 16)               // one load command
        put32(16, 20)
        put32(0x8000_0033, 32)     // LC_DYLD_EXPORTS_TRIE
        put32(16, 36)
        put32(256, 40)             // trie offset (relative to the slice)
        put32(UInt32(trie.count), 44)
        macho.append(contentsOf: trie)
        guard fat else { return macho }

        var fatData = Data(count: 4096)
        func putBE(_ value: UInt32, _ offset: Int) { withUnsafeBytes(of: value.bigEndian) { fatData.replaceSubrange(offset..<offset + 4, with: $0) } }
        putBE(0xCAFE_BABE, 0)
        putBE(2, 4)
        putBE(0x0100_000C, 8); putBE(0, 12); putBE(8192, 16); putBE(UInt32(macho.count), 20)   // arm64 slice (absent)
        putBE(0x0100_0007, 28); putBE(0, 32); putBE(4096, 36); putBE(UInt32(macho.count), 40)  // x86_64 slice
        return fatData + macho
    }
}

final class MachOExportsTests: XCTestCase {
    func testPrefixesAlongTheTrie() {
        let data = TestMachO.make()
        XCTAssertEqual(MachOExports.hasExport(withPrefix: "_macdrv_", inData: data), true)
        XCTAssertEqual(MachOExports.hasExport(withPrefix: "_mac", inData: data), true, "The prefix ends inside an edge")
        XCTAssertEqual(MachOExports.hasExport(withPrefix: "_macdrv_view_create", inData: data), true)
        XCTAssertEqual(MachOExports.hasExport(withPrefix: "_wine", inData: data), true)
        XCTAssertEqual(MachOExports.hasExport(withPrefix: "_macdrv_x", inData: data), false)
        XCTAssertEqual(MachOExports.hasExport(withPrefix: "_nope", inData: data), false)
        XCTAssertEqual(MachOExports.hasExport(withPrefix: "_macdrv_get_view_more", inData: data), false)
    }

    func testFatFilesUseTheX86Slice() {
        XCTAssertEqual(MachOExports.hasExport(withPrefix: "_macdrv_", inData: TestMachO.make(fat: true)), true)
    }

    func testDamagedFilesGiveNoAnswer() {
        XCTAssertNil(MachOExports.hasExport(withPrefix: "_macdrv_", inData: Data("not a binary".utf8)))
        let data = TestMachO.make()
        for cut in stride(from: 0, to: data.count, by: 7) {
            _ = MachOExports.hasExport(withPrefix: "_macdrv_", inData: data.prefix(cut))   // must not crash
        }
    }

    func testOnlyD3DMetalAndDXMTNeedTheExports() {
        XCTAssertEqual(WineCapabilities.layersNeedingMacDriverExports, [.d3dmetal, .dxmt])
    }
}

final class WineCapabilityTests: XCTestCase {
    private var work: URL!
    private var engine: DistillerEngine!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-wine-caps-\(UUID().uuidString)", isDirectory: true)
        engine = try DistillerEngine(paths: DistillerPaths(root: work.appendingPathComponent("home"), storage: StorageSettings()), hardware: Macs.m3Pro)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    @discardableResult
    private func addWine(_ id: String, version: String, exportsMacDriver: Bool, family: String = "winehq") throws -> InstalledComponent {
        let source = work.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("lib/wine/x86_64-unix"), withIntermediateDirectories: true)
        try Data("wine".utf8).write(to: source.appendingPathComponent("bin/wine"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("bin/wine").path)
        try TestMachO.make(withMacDriver: exportsMacDriver).write(to: source.appendingPathComponent("lib/wine/x86_64-unix/winemac.so"))
        return try engine.components.importDirectory(source, manifest: ComponentManifest(
            id: id, kind: .wine, version: version, displayName: "\(id) \(version)", arch: .x86_64, family: family
        ))
    }

    private func addLayer(_ backend: GraphicsBackend) throws {
        let source = work.appendingPathComponent("layer-\(backend.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("lib/wine/x86_64-windows"), withIntermediateDirectories: true)
        _ = try engine.components.importDirectory(source, manifest: ComponentManifest(
            id: backend.rawValue, kind: .graphics, version: "1.0", displayName: backend.displayName, arch: .x86_64,
            provides: backend, placement: .wineLib
        ))
    }

    /// The D3DMetal fixture, accepting any Wine build so only the graphics check decides.
    private func anyWineRecipe() throws -> Recipe {
        var recipe = try loadFixtureRecipe("d3dmetal")
        recipe.stack.runner.family = "any"
        recipe.stack.runner.minVersion = nil
        return recipe
    }

    func testWineHQBuildCantRunD3DMetalOrDXMT() throws {
        try addWine("wine-staging", version: "11.21", exportsMacDriver: false)
        for backend in [GraphicsBackend.d3dmetal, .dxmt, .dxvk] { try addLayer(backend) }

        XCTAssertEqual(engine.components.availableGraphics(), [.wined3d, .dxvk])
        XCTAssertEqual(Set(engine.components.graphicsProblems().keys), [.d3dmetal, .dxmt])

        let recipe = try anyWineRecipe()
        XCTAssertThrowsError(try engine.selectStack(for: engine.resolve(recipe))) { error in
            guard case DistillerError.graphicsNeedsOtherWine(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("CrossOver-based Wine"), message)
        }
        var dxvk = recipe
        dxvk.stack.graphics = .dxvk
        XCTAssertEqual(try engine.selectStack(for: engine.resolve(dxvk)).graphics?.manifest.provides, .dxvk)

        let inspection = GameInspector.inspect(executable: work, installedGraphics: engine.components.availableGraphics())
        XCTAssertEqual(inspection.suggestedGraphics, .dxvk, "Unknown API: the fastest layer this Wine can run")
    }

    func testCrossOverStyleBuildIsChosenForD3DMetal() throws {
        try addWine("wine-staging", version: "11.21", exportsMacDriver: false)
        try addWine("wine-crossover", version: "11.0", exportsMacDriver: true)
        try addLayer(.d3dmetal)

        XCTAssertTrue(engine.components.availableGraphics().contains(.d3dmetal))
        XCTAssertTrue(engine.components.graphicsProblems().isEmpty)
        let stack = try engine.selectStack(for: engine.resolve(try anyWineRecipe()))
        XCTAssertEqual(stack.wine.manifest.composedFrom?.first, "wine-crossover@11.0", "The older Wine that can run D3DMetal wins over the newer one that can't")
    }

    // MARK: A bottle keeps to the Wine that made it

    private func makeGame(bottleWine: String, graphics: GraphicsBackend = .dxvk) throws -> Game {
        let bottle = Bottle(id: "game-1", name: "Example", wine: bottleWine, createdAt: Date())
        try FileManager.default.createDirectory(at: engine.bottles.prefix(of: bottle), withIntermediateDirectories: true)
        try engine.bottles.save(bottle)
        var recipe = try anyWineRecipe()
        recipe.stack.graphics = graphics
        let game = Game(id: bottle.id, title: "Example", bottleID: bottle.id, recipe: recipe)
        try engine.library.upsert(game)
        // The program exists, so availability gets as far as the Wine check.
        if let exe = recipe.launch?.exe {
            let program = try BottlePath.resolve(exe, in: engine.bottles.root(of: bottle))
            try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("exe".utf8).write(to: program)
        }
        return game
    }

    func testBottleNeverRunsWithAnOlderOrDifferentWine() throws {
        try addWine("wine-staging", version: "11.10", exportsMacDriver: false)
        try addWine("wine-crossover", version: "22.1.1", exportsMacDriver: true, family: "crossover")
        try addLayer(.dxvk)
        let game = try makeGame(bottleWine: "wine-staging+d3dmetal@11.21")

        XCTAssertThrowsError(try engine.selectStack(for: game)) { error in
            guard case DistillerError.bottleNeedsItsWine(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("wine-staging 11.21"), message)
        }
        let reason = try XCTUnwrap(engine.availability(of: game).reason)
        XCTAssertTrue(reason.contains("older or different kind of Wine"), reason)
        // A brand-new bottle has no such limit.
        XCTAssertNoThrow(try engine.chooseWine(for: engine.resolve(game.recipe)))
    }

    func testNewerWineOfTheSameFamilyIsUsedAndRecorded() throws {
        try addWine("wine-staging", version: "11.21", exportsMacDriver: false)
        try addWine("wine-devel", version: "11.25", exportsMacDriver: false)
        try addWine("wine-crossover", version: "25.0", exportsMacDriver: true, family: "crossover")
        try addLayer(.dxvk)
        let game = try makeGame(bottleWine: "wine-staging+d3dmetal@11.21")

        let stack = try engine.selectStack(for: game)
        XCTAssertEqual(stack.wine.manifest.composedFrom?.first, "wine-devel@11.25", "Same family (WineHQ), newer: allowed; CrossOver isn't")
        XCTAssertEqual(try engine.bottles.bottle(id: game.bottleID).wine, "wine-staging+d3dmetal@11.21", "Not recorded unless asked")

        _ = try engine.selectStack(for: game, recordUpgrade: true)
        XCTAssertEqual(try engine.bottles.bottle(id: game.bottleID).wine, "wine-devel@11.25")
        // From now on 11.21 is too old for this bottle.
        XCTAssertEqual(BottleWine("wine-devel@11.25").version, "11.25")
    }

    func testBottleRuleComesBeforeTheGraphicsRule() throws {
        try addWine("wine-staging", version: "11.21", exportsMacDriver: false)
        try addWine("wine-crossover", version: "25.0", exportsMacDriver: true, family: "crossover")
        try addLayer(.d3dmetal)
        let game = try makeGame(bottleWine: "wine-staging@11.21", graphics: .d3dmetal)

        // CrossOver could run D3DMetal, but not this bottle; WineHQ could run the bottle, but not D3DMetal.
        XCTAssertThrowsError(try engine.selectStack(for: game)) { error in
            guard case DistillerError.graphicsNeedsOtherWine = error else { return XCTFail("\(error)") }
        }
    }

    func testBottleWineParsing() {
        XCTAssertEqual(BottleWine("wine-staging@11.21").id, "wine-staging")
        XCTAssertEqual(BottleWine("wine-staging+d3dmetal@11.21").id, "wine-staging")
        XCTAssertEqual(BottleWine("wine-staging+d3dmetal@11.21").version, "11.21")
        XCTAssertEqual(BottleWine("odd").version, "0")
    }
}
