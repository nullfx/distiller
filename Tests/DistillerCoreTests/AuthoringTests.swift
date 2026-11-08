import Foundation
import XCTest
@testable import DistillerCore

final class UserFolderStepTests: XCTestCase {
    let base = """
    schema: 1
    id: folder-test
    game: { title: Test, slug: test-game }
    stack: { runner: { family: any }, graphics: wined3d }
    install:
      - user_folder: { id: game-folder, prompt: Choose the game folder, to: 'C:\\Games\\Test' }
    launch: { exe: 'C:\\Games\\Test\\Test.exe' }
    """

    func testDecodesAndRoundTrips() throws {
        let recipe = try RecipeLoader.decode(yaml: base)
        guard case .userFolder(let folder)? = recipe.install?.first else { return XCTFail("Expected a user_folder step") }
        XCTAssertEqual(folder.id, "game-folder")
        XCTAssertEqual(folder.to, #"C:\Games\Test"#)
        XCTAssertEqual(try RecipeLoader.decode(yaml: RecipeLoader.encode(recipe)), recipe)
    }

    func testFolderMustGoBelowDriveCOutsideWindows() {
        for target in [#"C:\"#, #"C:\windows\system32"#, "cache/game", "drive_c", "drive_c/Windows"] {
            let yaml = base.replacingOccurrences(of: #"to: 'C:\Games\Test'"#, with: "to: '\(target)'")
            XCTAssertThrowsError(try RecipeLoader.decode(yaml: yaml), target)
        }
    }

    func testDriveCChecks() {
        XCTAssertTrue(BottlePath.isInsideDriveC(#"C:\Games\Example"#))
        XCTAssertTrue(BottlePath.isInsideDriveC("drive_c/Games"))
        XCTAssertFalse(BottlePath.isInsideDriveC(#"C:\"#))
        XCTAssertFalse(BottlePath.isInsideDriveC(#"c:/WINDOWS/x"#))
        XCTAssertFalse(BottlePath.isInsideDriveC(#"D:\Games"#))
    }

    func testWindowsPaths() {
        let root = URL(fileURLWithPath: "/tmp/bottle", isDirectory: true)
        let exe = root.appendingPathComponent("prefix/drive_c/Program Files/Example/Game.exe")
        XCTAssertEqual(BottlePath.windowsPath(for: exe, in: root), #"C:\Program Files\Example\Game.exe"#)
        XCTAssertNil(BottlePath.windowsPath(for: root.appendingPathComponent("cache/setup.exe"), in: root))
        XCTAssertEqual(BottlePath.join(#"C:\Games\Example"#, "bin/x64/Game.exe"), #"C:\Games\Example\bin\x64\Game.exe"#)
    }
}

final class RecipeDraftTests: XCTestCase {
    func testFolderDraftMakesValidRecipe() throws {
        var draft = RecipeDraft(source: .folder(URL(fileURLWithPath: "/Games/Example: Deluxe")), title: "Example: Deluxe")
        draft.launchProgram = "Binaries/Win64/Example-Win64-Shipping.exe"
        draft.winetricks = ["vcrun2022"]
        let recipe = draft.makeRecipe()
        try RecipeLoader.validate(recipe)
        XCTAssertEqual(recipe.game.slug, "example-deluxe")
        XCTAssertEqual(recipe.id, "d3dmetal")
        XCTAssertEqual(recipe.launch?.exe, #"C:\Games\Example- Deluxe\Binaries\Win64\Example-Win64-Shipping.exe"#)
        guard case .userFolder(let folder)? = recipe.install?.first else { return XCTFail("Expected user_folder") }
        XCTAssertEqual(folder.to, #"C:\Games\Example- Deluxe"#)
    }

    func testInstallerDrafts() throws {
        let exe = RecipeDraft(source: .installer(URL(fileURLWithPath: "/Downloads/setup_example.exe")), title: "Example").makeRecipe()
        try RecipeLoader.validate(exe)
        XCTAssertNil(exe.launch)
        XCTAssertEqual(exe.install?.count, 2)
        guard case .runWindows(let run)? = exe.install?.last else { return XCTFail("Expected run_windows") }
        XCTAssertEqual(run.path, "cache/setup_example.exe")

        let msi = RecipeDraft(source: .installer(URL(fileURLWithPath: "/Downloads/Example.msi")), title: "Example").makeRecipe()
        try RecipeLoader.validate(msi)
        guard case .runWindows(let msiRun)? = msi.install?.last else { return XCTFail("Expected run_windows") }
        XCTAssertEqual(msiRun.path, #"C:\windows\system32\msiexec.exe"#)
        XCTAssertEqual(msiRun.args, ["/i", #"C:\Installers\Example.msi"#])
    }

    func testManualDraftHasNoSteps() throws {
        let recipe = RecipeDraft(source: .manual, title: "Tool").makeRecipe()
        try RecipeLoader.validate(recipe)
        XCTAssertNil(recipe.install)
    }

    func testSlugs() {
        XCTAssertEqual(RecipeDraft.makeSlug("Café Racer 2: The Return!"), "cafe-racer-2-the-return")
        XCTAssertEqual(RecipeDraft.makeSlug("X"), "x-game")
        XCTAssertEqual(RecipeDraft.makeSlug("???"), "game")
        XCTAssertTrue(RecipePolicy.isValidSlug(RecipeDraft.makeSlug(String(repeating: "Long Title ", count: 20))))
    }

    func testYAMLQuotesStringsThatLookLikeNumbers() throws {
        // The repository's Python validator reads YAML 1.1; an unquoted 11.0 would be a float there.
        var draft = RecipeDraft(source: .manual, title: "Example", runner: RunnerRequirement(family: "winehq", minVersion: "11.0"))
        draft.env = ["DXVK_FRAME_RATE": "60"]
        let yaml = try RecipeLoader.encode(draft.makeRecipe())
        XCTAssertTrue(yaml.contains("'11.0'") || yaml.contains("\"11.0\""), yaml)
        XCTAssertTrue(yaml.contains("'60'") || yaml.contains("\"60\""), yaml)
    }
}

/// Builds a minimal 64-bit PE file with an import table, for tests.
enum TestPE {
    static func make(imports: [String], delayImports: [String] = [], machine: UInt16 = 0x8664) -> Data {
        var data = Data(count: 0x400)
        func put16(_ value: UInt16, _ offset: Int) { withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + 2, with: $0) } }
        func put32(_ value: UInt32, _ offset: Int) { withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + 4, with: $0) } }

        put16(0x5A4D, 0)
        put32(0x80, 0x3C)
        put32(0x0000_4550, 0x80)
        let coff = 0x84
        put16(machine, coff)
        put16(1, coff + 2)                      // one section
        put16(240, coff + 16)                   // optional header size (PE32+)
        let optional = coff + 20
        put16(0x20B, optional)
        put32(16, optional + 108)               // data directory count
        let directories = optional + 112
        let sectionTable = optional + 240

        // One section: RVA 0x1000 maps to file offset 0x200.
        let rva: UInt32 = 0x1000, raw: UInt32 = 0x200
        data.replaceSubrange(sectionTable..<sectionTable + 5, with: Array(".data".utf8))
        put32(0x200, sectionTable + 8)
        put32(rva, sectionTable + 12)
        put32(0x200, sectionTable + 16)
        put32(raw, sectionTable + 20)

        // Layout inside the section: import descriptors, delay descriptors, then names.
        var nameOffset = 0x100
        func addName(_ name: String) -> UInt32 {
            let bytes = Array(name.utf8) + [0]
            data.replaceSubrange(Int(raw) + nameOffset..<Int(raw) + nameOffset + bytes.count, with: bytes)
            defer { nameOffset += bytes.count }
            return rva + UInt32(nameOffset)
        }
        for (index, name) in imports.enumerated() {
            let entry = Int(raw) + index * 20
            put32(rva, entry)                    // OriginalFirstThunk (non-zero)
            put32(addName(name), entry + 12)
            put32(rva, entry + 16)
        }
        put32(rva, directories + 8)
        put32(UInt32((imports.count + 1) * 20), directories + 12)
        if !delayImports.isEmpty {
            let start = (imports.count + 1) * 20
            for (index, name) in delayImports.enumerated() {
                let entry = Int(raw) + start + index * 32
                put32(1, entry)
                put32(addName(name), entry + 4)
            }
            put32(rva + UInt32(start), directories + 13 * 8)
            put32(UInt32((delayImports.count + 1) * 32), directories + 13 * 8 + 4)
        }
        return data
    }
}

final class InspectorTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-inspect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testParsesImportsAndMachine() throws {
        let pe = try XCTUnwrap(PEFile.parse(TestPE.make(imports: ["KERNEL32.dll", "d3d11.dll"], delayImports: ["XINPUT1_3.dll"])))
        XCTAssertEqual(pe.machine, .x64)
        XCTAssertEqual(pe.imports, ["kernel32.dll", "d3d11.dll", "xinput1_3.dll"])
        XCTAssertNil(PEFile.parse(Data("not a program".utf8)))
        XCTAssertNil(PEFile.parse(TestPE.make(imports: []).prefix(0x90)))
    }

    func testSuggestsD3DMetalAndRuntimesForUnityGame() throws {
        let exe = folder.appendingPathComponent("Example.exe")
        try TestPE.make(imports: ["KERNEL32.dll"]).write(to: exe)
        try TestPE.make(imports: ["d3d11.dll", "MSVCP140.dll", "VCRUNTIME140.dll"]).write(to: folder.appendingPathComponent("UnityPlayer.dll"))
        let result = GameInspector.inspect(executable: exe, installedGraphics: [.d3dmetal, .wined3d])
        XCTAssertEqual(result.engine, "Unity")
        XCTAssertEqual(result.apis, [.direct3D11])
        XCTAssertEqual(result.suggestedGraphics, .d3dmetal)
        XCTAssertEqual(result.suggestedWinetricks, ["vcrun2022"])
    }

    func testOldGamesGetWineD3D() throws {
        let exe = folder.appendingPathComponent("Old.exe")
        try TestPE.make(imports: ["d3d8.dll", "d3dx9_43.dll"], machine: 0x014C).write(to: exe)
        let result = GameInspector.inspect(executable: exe, installedGraphics: [.d3dmetal, .wined3d])
        XCTAssertEqual(result.machine, .x86)
        XCTAssertEqual(result.suggestedGraphics, .wined3d)
        XCTAssertEqual(result.suggestedWindowsVersion, "win7")
        XCTAssertEqual(result.suggestedWinetricks, ["d3dx9"])
    }

    func testFallsBackWhenD3DMetalIsMissing() throws {
        let exe = folder.appendingPathComponent("New.exe")
        try TestPE.make(imports: ["d3d12.dll"]).write(to: exe)
        XCTAssertEqual(GameInspector.inspect(executable: exe, installedGraphics: [.wined3d]).suggestedGraphics, .wined3d)
    }

    func testFindsTheGameBeforeHelpers() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder.appendingPathComponent("_CommonRedist/vcredist"), withIntermediateDirectories: true)
        try Data(count: 64).write(to: folder.appendingPathComponent("_CommonRedist/vcredist/vc_redist.x64.exe"))
        try Data(count: 64).write(to: folder.appendingPathComponent("unins000.exe"))
        try Data(count: 64).write(to: folder.appendingPathComponent("Launcher.exe"))
        try Data(count: 40_000_000).write(to: folder.appendingPathComponent("Game.exe"))
        let found = ProgramFinder.find(in: folder).map(\.relativePath)
        XCTAssertEqual(found.first, "Game.exe")
        XCTAssertFalse(found.contains("unins000.exe"))
        XCTAssertFalse(found.contains { $0.contains("vc_redist") })
        XCTAssertEqual(GameInspector.redistributableHints(in: folder), [])
    }

    func testLocatesWineInsideAppBundle() throws {
        let root = folder.appendingPathComponent("Wine Staging.app/Contents/Resources/wine")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let wine = root.appendingPathComponent("bin/wine")
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        XCTAssertEqual(try WineBuildLocator.locateRoot(in: folder).standardizedFileURL, root.standardizedFileURL)
        XCTAssertThrowsError(try WineBuildLocator.locateRoot(in: folder.appendingPathComponent("Wine Staging.app/Contents/Resources/wine/lib")))
    }
}

final class EngineAuthoringTests: XCTestCase {
    func testOnlyBottleSettingsNeedReconfiguring() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try DistillerEngine(paths: DistillerPaths(root: root), hardware: Macs.m3Pro)
        let recipe = try loadFixtureRecipe("d3dmetal")

        var argsOnly = recipe
        argsOnly.launch?.args = ["-fullscreen"]
        argsOnly.env = ["MTL_HUD_ENABLED": "1"]
        XCTAssertFalse(engine.needsReconfigure(from: recipe, to: argsOnly))

        var moreVerbs = recipe
        moreVerbs.prefix?.winetricks?.append("xact")
        XCTAssertTrue(engine.needsReconfigure(from: recipe, to: moreVerbs))

        var otherWindows = recipe
        otherWindows.prefix?.windows = "win7"
        XCTAssertTrue(engine.needsReconfigure(from: recipe, to: otherWindows))
        // Switching between layers merged into Wine changes nothing in the bottle.
        var dxvk = recipe
        dxvk.stack.graphics = .dxvk
        XCTAssertFalse(engine.needsReconfigure(from: recipe, to: dxvk))

        // A layer whose DLLs are copied into the bottle does need it.
        let layer = root.appendingPathComponent("old-dxvk", isDirectory: true)
        try FileManager.default.createDirectory(at: layer.appendingPathComponent("system32"), withIntermediateDirectories: true)
        _ = try engine.components.importDirectory(layer, manifest: ComponentManifest(
            id: "dxvk-prefix", kind: .graphics, version: "2.0", displayName: "DXVK 2.0", arch: .x86_64, provides: .dxvk, placement: .prefixDLLs
        ))
        XCTAssertTrue(engine.needsReconfigure(from: recipe, to: dxvk))
    }

    func testWineSourcesMatchReleaseAssets() throws {
        func matches(_ source: WineSource, _ name: String) throws -> String? {
            let regex = try NSRegularExpression(pattern: source.assetPattern)
            guard let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let range = Range(match.range(at: 1), in: name) else { return nil }
            return String(name[range])
        }
        XCTAssertEqual(try matches(.gcenxStaging, "wine-staging-11.17-osx64.tar.xz"), "11.17")
        XCTAssertNil(try matches(.gcenxStaging, "wine-devel-11.17-osx64.tar.xz"))
        XCTAssertEqual(try matches(.gcenxDevel, "wine-devel-11.17-osx64.tar.xz"), "11.17")
    }
}
