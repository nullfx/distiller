import XCTest
import DistillerCommunity
@testable import DistillerCore

final class RecipeLoadingTests: XCTestCase {
    func testLoadsSampleRecipe() throws {
        let recipe = try loadFixtureRecipe("d3dmetal")
        XCTAssertEqual(recipe.id, "d3dmetal")
        XCTAssertEqual(recipe.game.slug, "example-dx11-game")
        XCTAssertEqual(recipe.stack.graphics, .d3dmetal)
        XCTAssertEqual(recipe.stack.runner, RunnerRequirement(family: "crossover", minVersion: "24.0"))
        XCTAssertEqual(recipe.prefix?.registry?.first?.values["CaptureDisplaysForFullscreen"], .string("y"))
        XCTAssertEqual(recipe.launch?.exe, #"C:\Games\Example DX11 Game\Game.exe"#)
        XCTAssertEqual(recipe.overlays?.count, 2)
        guard case .userFile(let file)? = recipe.install?.first else {
            return XCTFail("The first install step should be a user_file")
        }
        XCTAssertEqual(file.id, "installer")
    }

    func testLoadsEveryStepType() throws {
        let recipe = try loadFixtureRecipe("wined3d")
        let kinds = (recipe.install ?? []).map { step -> String in
            switch step {
            case .download: return "download"
            case .extract: return "extract"
            case .winetricks: return "winetricks"
            case .registry: return "registry"
            case .dllOverride: return "dll_override"
            case .copy: return "copy"
            case .runWindows: return "run_windows"
            case .userFile: return "user_file"
            case .userFolder: return "user_folder"
            case .userDownload: return "user_download"
            }
        }
        XCTAssertEqual(kinds, ["user_file", "extract", "download", "extract", "copy", "dll_override"])
    }

    func testYAMLRoundTrip() throws {
        let recipe = try loadFixtureRecipe("d3dmetal")
        let again = try RecipeLoader.decode(yaml: RecipeLoader.encode(recipe))
        XCTAssertEqual(recipe, again)
    }

    func testRejectsHostEnvironmentVariables() throws {
        for key in ["DYLD_INSERT_LIBRARIES", "WINEDLLPATH", "PATH"] {
            let yaml = try sampleYAML(replacing: "MTL_HUD_ENABLED: \"0\"", with: "\(key): \"/tmp/x\"")
            XCTAssertThrowsError(try RecipeLoader.decode(yaml: yaml)) { error in
                XCTAssertEqual(error as? DistillerError, .envKeyNotAllowed(key))
            }
        }
    }

    func testRejectsUnknownWinetricksVerb() throws {
        let yaml = try sampleYAML(replacing: "[vcrun2022, d3dcompiler_47]", with: "[vcrun2022, sandbox]")
        XCTAssertThrowsError(try RecipeLoader.decode(yaml: yaml)) { error in
            XCTAssertEqual(error as? DistillerError, .winetricksVerbNotAllowed("sandbox"))
        }
    }

    func testRejectsLaunchPathOutsideBottle() throws {
        let yaml = try sampleYAML(replacing: #"exe: 'C:\Games\Example DX11 Game\Game.exe'"#, with: "exe: '/Applications/Calculator.app'")
        XCTAssertThrowsError(try RecipeLoader.decode(yaml: yaml))
    }

    func testRejectsNewerSchema() throws {
        let yaml = try sampleYAML(replacing: "schema: 1", with: "schema: 3")
        XCTAssertThrowsError(try RecipeLoader.decode(yaml: yaml)) { error in
            XCTAssertEqual(error as? DistillerError, .unsupportedSchema(3))
        }
    }

    func testRejectsStepWithTwoKeys() {
        let yaml = """
        schema: 1
        id: two-keys
        game: { title: Test, slug: test-game }
        stack: { runner: { family: any }, graphics: wined3d }
        install:
          - copy: { from: cache/a, to: cache/b }
            winetricks: [xact]
        """
        XCTAssertThrowsError(try RecipeLoader.decode(yaml: yaml))
    }
}

final class ResolverTests: XCTestCase {
    func testM1AirGetsBothOverlays() throws {
        let resolved = RecipeResolver.resolve(try loadFixtureRecipe("d3dmetal"), for: Macs.m1Air)
        XCTAssertEqual(resolved.appliedOverlays, [0, 1])
        XCTAssertEqual(resolved.graphics, .dxmt)
        XCTAssertEqual(resolved.env["DXMT_CONFIG"], "d3d11.preferredMaxFrameRate=30;")
        XCTAssertEqual(resolved.env["MTL_HUD_ENABLED"], "0", "Overlay env merges into the recipe env")
        XCTAssertEqual(resolved.launch?.args, ["-windowed", "-textures=medium"])
        XCTAssertEqual(resolved.appliedOverlayNotes.count, 2)
    }

    func testM3ProUsesRecipeAsWritten() throws {
        let resolved = RecipeResolver.resolve(try loadFixtureRecipe("d3dmetal"), for: Macs.m3Pro)
        XCTAssertEqual(resolved.appliedOverlays, [])
        XCTAssertEqual(resolved.graphics, .d3dmetal)
        XCTAssertEqual(resolved.launch?.args, ["-windowed"])
        XCTAssertEqual(resolved.winetricks, ["vcrun2022", "d3dcompiler_47"])
        XCTAssertTrue(resolved.retina)
        XCTAssertEqual(resolved.sync, .msync)
    }

    func testMissingRosettaSelectsArmRunner() throws {
        let resolved = RecipeResolver.resolve(try loadFixtureRecipe("wined3d"), for: Macs.m4NoRosetta)
        XCTAssertEqual(resolved.runner.arch, .arm64)
        XCTAssertEqual(resolved.windowsVersion, "win7")
    }

    func testLocalOverridesWinLast() throws {
        let overrides = LocalOverrides(graphics: .wined3d, env: ["DXMT_CONFIG": "custom"], args: ["-fullscreen"])
        let resolved = RecipeResolver.resolve(try loadFixtureRecipe("d3dmetal"), for: Macs.m1Air, overrides: overrides)
        XCTAssertEqual(resolved.graphics, .wined3d)
        XCTAssertEqual(resolved.env["DXMT_CONFIG"], "custom")
        XCTAssertEqual(resolved.launch?.args, ["-fullscreen"])
    }

    func testAppendWinetricksDeduplicates() {
        let recipe = Recipe(
            id: "append-test",
            game: GameInfo(title: "T", slug: "append-game"),
            stack: StackSpec(runner: RunnerRequirement(family: "any"), graphics: .wined3d),
            prefix: PrefixSpec(winetricks: ["xact"]),
            overlays: [Overlay(when: OverlayCondition(rosetta: true), appendWinetricks: ["xact", "physx"])]
        )
        XCTAssertEqual(RecipeResolver.resolve(recipe, for: Macs.m3Pro).winetricks, ["xact", "physx"])
    }
}

final class MatchingTests: XCTestCase {
    func testComparisons() throws {
        XCTAssertTrue(try Comparison(parsing: "<16").matches(8))
        XCTAssertFalse(try Comparison(parsing: "<16").matches(16))
        XCTAssertTrue(try Comparison(parsing: ">= 24").matches(24))
        XCTAssertTrue(try Comparison(parsing: ">=27").matches(VersionNumber("27.1")))
        XCTAssertTrue(try Comparison(parsing: "27").matches(VersionNumber("27.0")))
        XCTAssertFalse(try Comparison(parsing: "<27").matches(VersionNumber("27.0.1")))
        XCTAssertThrowsError(try Comparison(parsing: "lots"))
    }

    func testChipConditions() {
        XCTAssertTrue(OverlayMatcher.matches(OverlayCondition(chip: "Apple M1*"), Macs.m1Air))
        XCTAssertFalse(OverlayMatcher.matches(OverlayCondition(chip: "Apple M1*"), Macs.m3Pro))
        XCTAssertTrue(OverlayMatcher.matches(OverlayCondition(chipFamily: ["M2", "M3"], chipTier: ["pro"]), Macs.m3Pro))
        XCTAssertFalse(OverlayMatcher.matches(OverlayCondition(chipFamily: ["M3"], gpuCores: try! Comparison(parsing: ">20")), Macs.m3Pro))
    }

    func testChipParsing() {
        XCTAssertTrue(HardwareProfile.parseChip("Apple M3 Pro") == ("M3", "Pro"))
        XCTAssertTrue(HardwareProfile.parseChip("Apple M2") == ("M2", "Base"))
        XCTAssertTrue(HardwareProfile.parseChip("Apple M4 Max") == ("M4", "Max"))
        XCTAssertTrue(HardwareProfile.parseChip("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz") == ("Intel", "Base"))
    }

    func testHardwareKeyMatchesIndexBuilder() {
        // scripts/build_index.py computes the same key; see test_hardware_key_matches_app_format.
        XCTAssertEqual(Macs.m3Pro.hardwareKey, "M3-Pro-18gpu-18gb-macos27")
        var unknownGPU = Macs.m3Pro
        unknownGPU.gpuCores = nil
        XCTAssertEqual(unknownGPU.hardwareKey, "M3-Pro-xgpu-18gb-macos27")
    }

    func testVersionNumbers() {
        XCTAssertEqual(VersionNumber("11"), VersionNumber("11.0"))
        XCTAssertGreaterThan(VersionNumber("24.0.7"), VersionNumber("24.0"))
        XCTAssertLessThan(VersionNumber("9.22"), VersionNumber("11.0"))
        XCTAssertEqual(Set([VersionNumber("11"), VersionNumber("11.0.0")]).count, 1)
    }
}

final class BottlePathTests: XCTestCase {
    let root = URL(fileURLWithPath: "/tmp/bottles/demo", isDirectory: true)

    func testAcceptedForms() throws {
        XCTAssertEqual(try BottlePath.resolve(#"C:\Games\A\a.exe"#, in: root).path, "/tmp/bottles/demo/prefix/drive_c/Games/A/a.exe")
        XCTAssertEqual(try BottlePath.resolve("c:/Games/a.exe", in: root).path, "/tmp/bottles/demo/prefix/drive_c/Games/a.exe")
        XCTAssertEqual(try BottlePath.resolve("drive_c/x.exe", in: root).path, "/tmp/bottles/demo/prefix/drive_c/x.exe")
        XCTAssertEqual(try BottlePath.resolve("cache/setup.exe", in: root).path, "/tmp/bottles/demo/cache/setup.exe")
    }

    func testRejectedForms() {
        for path in ["/etc/hosts", "../x", "cache/../../x", #"D:\x.exe"#, "Z:/x", "~/x", "prefix/system.reg", "cache/./x", "drive_c/~root"] {
            XCTAssertThrowsError(try BottlePath.resolve(path, in: root), "\(path) should be rejected")
        }
    }
}

final class WineEnvironmentTests: XCTestCase {
    func makeWine() -> InstalledComponent {
        InstalledComponent(
            manifest: ComponentManifest(
                id: "winehq", kind: .wine, version: "11.0", displayName: "Wine 11.0", arch: .x86_64,
                family: "winehq", executable: "bin/wine", env: ["WINEDEBUG": "fixme-all"]
            ),
            directory: URL(fileURLWithPath: "/opt/wine", isDirectory: true)
        )
    }

    func testLayeringAndPrefix() throws {
        var resolved = RecipeResolver.resolve(try loadFixtureRecipe("d3dmetal"), for: Macs.m3Pro)
        resolved.env["WINEPREFIX"] = "/somewhere/else"  // can't come from a valid recipe, but must still lose
        let graphics = InstalledComponent(
            manifest: ComponentManifest(
                id: "dxvk", kind: .graphics, version: "2.0", displayName: "DXVK", arch: .x86_64,
                provides: .dxvk, placement: .prefixDLLs, dllOverrides: ["d3d11": "native", "dxgi": "native"]
            ),
            directory: URL(fileURLWithPath: "/opt/dxvk")
        )
        let prefix = URL(fileURLWithPath: "/tmp/bottles/demo/prefix")
        let env = WineEnvironment.build(prefix: prefix, wine: makeWine(), graphics: graphics, resolved: resolved, host: ["HOME": "/Users/test", "DYLD_INSERT_LIBRARIES": "/evil.dylib"])

        XCTAssertEqual(env["WINEPREFIX"], prefix.path)
        XCTAssertEqual(env["WINEDEBUG"], "fixme-all", "Component env overrides Distiller's default")
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"], "Host DYLD variables must not leak into Wine")
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "d3d11=n;dxgi=n;xinput1_3=b")
        XCTAssertTrue(env["PATH"]?.hasPrefix("/opt/wine/bin:") == true)
    }

    /// MoltenVK's warnings can repeat many times a second and fill a launch log, so it reports
    /// errors only unless a recipe asks for more.
    func testMoltenVKReportsErrorsOnlyByDefault() throws {
        let prefix = URL(fileURLWithPath: "/tmp/bottles/demo/prefix")
        var resolved = RecipeResolver.resolve(try loadFixtureRecipe("d3dmetal"), for: Macs.m3Pro)
        XCTAssertEqual(WineEnvironment.build(prefix: prefix, wine: makeWine(), graphics: nil, resolved: resolved, host: [:])["MVK_CONFIG_LOG_LEVEL"], "1")
        resolved.env["MVK_CONFIG_LOG_LEVEL"] = "3"
        XCTAssertTrue(RecipePolicy.isAllowedEnvKey("MVK_CONFIG_LOG_LEVEL"))
        XCTAssertEqual(WineEnvironment.build(prefix: prefix, wine: makeWine(), graphics: nil, resolved: resolved, host: [:])["MVK_CONFIG_LOG_LEVEL"], "3", "A recipe can turn it back up")
    }

    func testDLLOverrideString() {
        let text = WineEnvironment.dllOverrideString(["nvapi": "disabled", "d3d11": "native,builtin", "dxgi": "native"])
        XCTAssertEqual(text, "d3d11=n,b;dxgi=n;nvapi=")
    }

    func testRegistryFile() {
        let text = RegistryFile.render([
            RegistryEdit(key: #"HKCU\Software\Wine\Mac Driver"#, values: ["RetinaMode": .string("y"), "Flag": .dword(26)]),
        ])
        XCTAssertTrue(text.hasPrefix("Windows Registry Editor Version 5.00"))
        XCTAssertTrue(text.contains(#"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#))
        XCTAssertTrue(text.contains(#""RetinaMode"="y""#))
        XCTAssertTrue(text.contains(#""Flag"=dword:0000001a"#))
        XCTAssertEqual(Array(RegistryFile.data([]).prefix(2)), [0xFF, 0xFE])
    }
}

final class InstallerPageTests: XCTestCase {
    func recipe(page: String?) throws -> Recipe {
        var recipe = try loadFixtureRecipe("d3dmetal")
        recipe.game.installer = PublicInstaller(url: "https://cdn.example-publisher.com/Setup.exe", page: page)
        return recipe
    }

    func testDownloadPageIsKeptAndChecked() throws {
        let withPage = try recipe(page: "https://www.example-publisher.com/download")
        XCTAssertNoThrow(try RecipeLoader.validate(withPage))
        let yaml = try RecipeLoader.encode(withPage)
        XCTAssertTrue(yaml.contains("page: https://www.example-publisher.com/download"), yaml)
        XCTAssertEqual(try RecipeLoader.decode(yaml: yaml).game.installer?.page, "https://www.example-publisher.com/download")
        XCTAssertThrowsError(try RecipeLoader.validate(try recipe(page: "http://www.example-publisher.com/download")))
        XCTAssertNoThrow(try RecipeLoader.validate(try recipe(page: nil)), "Optional")
    }

    func testCatalogueEntriesCarryThePage() throws {
        let json = #"{"slug":"real-game","title":"Real Game","recipes":[],"installer":{"url":"https://cdn.example.com/Setup.exe","page":"https://www.example.com/download"}}"#
        let game = try JSONDecoder().decode(IndexGame.self, from: Data(json.utf8))
        XCTAssertEqual(game.installer?.page, "https://www.example.com/download")
    }
}
