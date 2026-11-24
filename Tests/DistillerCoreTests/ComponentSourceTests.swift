import CryptoKit
import Foundation
import XCTest
@testable import DistillerCore

/// Serves release listings (JSON) and downloads (bytes) by path.
final class FakeSourceServer: URLProtocol {
    nonisolated(unsafe) static var responses: [String: Data] = [:]

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeSourceServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.responses[request.url?.path ?? ""]
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Recipes name Wine builds by tag; a tag Distiller doesn't know can be described as a source,
/// installed from its publisher's GitHub release (checked against GitHub's checksum), completed
/// with another build's libraries, and checked.
final class ComponentSourceTests: XCTestCase {
    var root: URL!
    var engine: DistillerEngine!

    let sourceYAML = #"""
    schema: 1
    tag: sikarugir
    kind: wine
    name: Sikarugir Wine
    publisher: Sikarugir
    homepage: https://github.com/Sikarugir-App/Engines
    license: LGPL-2.1-or-later
    get:
      github_release:
        repository: Sikarugir-App/Engines
        asset: '^WS12WineSikarugir([0-9][0-9._]*)\.tar\.xz$'
    provides:
      family: sikarugir
      arch: x86_64
    libraries_from: wine-staging
    """#

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-sources-\(UUID().uuidString)")
        engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
        FakeSourceServer.responses = [:]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReadsAndChecksASource() throws {
        let source = try ComponentSource.decode(yaml: sourceYAML)
        XCTAssertEqual(source.tag, "sikarugir")
        XCTAssertEqual(source.family, "sikarugir")
        XCTAssertEqual(source.librariesFrom, "wine-staging")
        XCTAssertEqual(source.repositoryPath, "components/wine/sikarugir.yaml")
        XCTAssertEqual(source.version(of: "WS12WineSikarugir10.0_8.tar.xz"), "10.0_8")
        XCTAssertNil(source.version(of: "Template-1.0.27.tar.xz"))
        XCTAssertEqual(try ComponentSource.decode(yaml: source.encoded()), source, "Round trip")

        func problems(_ change: (inout ComponentSource) -> Void) -> [String] {
            var copy = source
            change(&copy)
            return copy.problems
        }
        XCTAssertTrue(source.problems.isEmpty)
        XCTAssertFalse(problems { $0.tag = "Sikarugir Wine" }.isEmpty)
        XCTAssertFalse(problems { $0.homepage = "http://example.com" }.isEmpty)
        XCTAssertFalse(problems { $0.license = "" }.isEmpty)
        XCTAssertFalse(problems { $0.get.githubRelease.repository = "https://github.com/x/y" }.isEmpty)
        XCTAssertFalse(problems { $0.get.githubRelease.asset = #"^engine\.tar\.xz$"# }.isEmpty, "No version group")
        XCTAssertFalse(problems { $0.get.githubRelease.asset = "(" }.isEmpty)
        XCTAssertFalse(problems { $0.librariesFrom = "sikarugir" }.isEmpty)
        XCTAssertFalse(problems { $0.kind = .graphics }.isEmpty, "A graphics layer names its backend")
        XCTAssertThrowsError(try ComponentSource.decode(yaml: sourceYAML.replacingOccurrences(of: "tag: sikarugir", with: "tag: A")))
    }

    func testMakesAPatternFromAFileName() throws {
        let cases: [(String, String, String)] = [
            ("WS12WineSikarugir10.0_8.tar.xz", #"^WS12WineSikarugir([0-9][0-9._]*)\.tar\.xz$"#, "10.0_8"),
            ("wine-staging-11.21-osx64.tar.xz", #"^wine-staging-([0-9][0-9._]*)-osx64\.tar\.xz$"#, "11.21"),
            ("dxmt-v0.80-builtin.tar.gz", #"^dxmt-v([0-9][0-9._]*)-builtin\.tar\.gz$"#, "0.80"),
            ("engine64.zip", #"^engine([0-9][0-9._]*)\.zip$"#, "64"),
        ]
        for (file, pattern, version) in cases {
            XCTAssertEqual(ComponentSource.pattern(forFileName: file), pattern, file)
            var source = try ComponentSource.decode(yaml: sourceYAML)
            source.get.githubRelease.asset = ComponentSource.pattern(forFileName: file)
            XCTAssertEqual(source.version(of: file), version, file)
            XCTAssertTrue(source.problems.isEmpty, file)
        }
        // A newer file matches the same pattern; a different file doesn't.
        var source = try ComponentSource.decode(yaml: sourceYAML)
        source.get.githubRelease.asset = ComponentSource.pattern(forFileName: "WS12WineSikarugir10.0_8.tar.xz")
        XCTAssertEqual(source.version(of: "WS12WineSikarugir11.0_1.tar.xz"), "11.0_1")
        XCTAssertNil(source.version(of: "WS11WineSikarugir11.0_1.tar.xz"))
    }

    func testDistillersOwnSourcesAreBuiltIn() {
        let tags = ComponentSources.builtIn.map(\.tag)
        XCTAssertEqual(tags, ["wine-staging", "wine-devel", "dxmt", "dxvk-macos"])
        XCTAssertTrue(ComponentSources.builtIn.allSatisfy { $0.problems.isEmpty }, "\(ComponentSources.builtIn.map(\.problems))")
        XCTAssertEqual(ComponentSources(local: []).wineSource(family: "winehq")?.tag, "wine-staging")
    }

    func testFindsWhatARecipeIsMissing() throws {
        let recipe = Recipe(id: "steam", game: GameInfo(title: "Steam", slug: "steam"),
                            stack: StackSpec(runner: RunnerRequirement(family: "sikarugir"), graphics: .wined3d),
                            launch: LaunchSpec(exe: SteamLibrary.clientPath))
        XCTAssertEqual(engine.missingComponents(for: recipe).map(\.tag), ["sikarugir"])
        XCTAssertNil(engine.missingComponents(for: recipe).first?.source, "Nothing known yet")

        let source = try ComponentSource.decode(yaml: sourceYAML)
        try engine.saveSource(source)
        XCTAssertEqual(engine.missingComponents(for: recipe).first?.source, source, "The player's source can install it")
        XCTAssertThrowsError(try engine.saveSource(ComponentSources.builtIn[0]), "Distiller's own sources can't be replaced")

        // Distiller's own families are installed by the setup assistant, not this flow.
        var winehq = recipe
        winehq.stack.runner.family = "winehq"
        XCTAssertTrue(engine.missingComponents(for: winehq).isEmpty)

        try addWine(id: "sikarugir", version: "10.0_8", family: "sikarugir")
        XCTAssertTrue(engine.missingComponents(for: recipe).isEmpty, "Installed")
    }

    func testReadsTheLibrariesAProgramLoads() throws {
        let file = root.appendingPathComponent("ntdll.so")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.machO(loading: ["@rpath/libglib-2.0.0.dylib", "/usr/lib/libSystem.B.dylib"]).write(to: file)
        XCTAssertEqual(MachODependencies.libraries(of: file), ["@rpath/libglib-2.0.0.dylib", "/usr/lib/libSystem.B.dylib"])
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("script"))
        XCTAssertNil(MachODependencies.libraries(of: root.appendingPathComponent("script")))
        var truncated = Self.machO(loading: ["@rpath/libx.dylib"])
        truncated.removeLast(10)
        try truncated.write(to: file)
        XCTAssertNil(MachODependencies.libraries(of: file), "A command running past the end")
    }

    func testInstallsASourceWithAnotherBuildsLibraries() async throws {
        let staging = try addWine(id: "wine-staging", version: "11.21", family: "winehq")
        let stagingLib = staging.directory.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: stagingLib.appendingPathComponent("GStreamer.framework/Versions/1.0/lib"), withIntermediateDirectories: true)
        try Self.machO(loading: []).write(to: stagingLib.appendingPathComponent("libinotify.0.dylib"))
        try FileManager.default.createSymbolicLink(atPath: stagingLib.appendingPathComponent("libinotify.dylib").path, withDestinationPath: "libinotify.0.dylib")
        try Self.machO(loading: []).write(to: stagingLib.appendingPathComponent("GStreamer.framework/Versions/1.0/lib/libglib-2.0.0.dylib"))

        let archive = try makeEngineArchive(needs: ["@rpath/libinotify.0.dylib", "@rpath/libglib-2.0.0.dylib"])
        try serve(archive, named: "WS12WineSikarugir10.0_8.tar.xz", olderVersion: true)

        let setup = EnvironmentSetup(engine: engine, session: FakeSourceServer.session())
        let source = try ComponentSource.decode(yaml: sourceYAML)
        let newest = try await setup.newestFile(for: source)
        XCTAssertEqual(newest.name, "WS12WineSikarugir10.0_8.tar.xz", "Newest by version, not listing order")
        let result = try await setup.install(source)
        XCTAssertEqual(result.component.manifest.id, "sikarugir")
        XCTAssertEqual(result.component.manifest.version, "10.0_8")
        XCTAssertEqual(result.component.manifest.family, "sikarugir")
        XCTAssertEqual(result.component.manifest.librariesFrom, "wine-staging@11.21")
        XCTAssertEqual(result.librariesAdded, 3, "Both libraries and the link")
        XCTAssertFalse(result.containsD3DMetal)
        let unix = result.component.directory.appendingPathComponent("lib/wine/x86_64-unix")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unix.appendingPathComponent("libglib-2.0.0.dylib").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: unix.appendingPathComponent("libinotify.dylib").path), "libinotify.0.dylib")
        XCTAssertTrue(engine.missingComponents(for: steamRecipe()).isEmpty)
    }

    func testListsTheMostRecentlyUploadedFilesFirst() async throws {
        // Some projects keep every build in one release, oldest first.
        FakeSourceServer.responses["/repos/Sikarugir-App/Engines/releases"] = Data(#"""
        [{"tag_name":"v1.0","draft":false,"prerelease":false,"assets":[
          {"name":"WS11WineCX19.0.2.tar.xz","browser_download_url":"https://example.com/a","updated_at":"2024-10-03T10:00:00Z"},
          {"name":"WS12WineSikarugir10.0_8.tar.xz","browser_download_url":"https://example.com/b","digest":"sha256:ab","updated_at":"2026-10-01T09:00:00Z"},
          {"name":"WS12WineSikarugir11.0_1.tar.xz","browser_download_url":"https://example.com/c","digest":"sha256:cd","updated_at":"2026-10-01T09:00:00Z"},
          {"name":"insecure.tar.xz","browser_download_url":"http://example.com/d","updated_at":"2026-11-01T09:00:00Z"}
        ]},
         {"tag_name":"draft","draft":true,"prerelease":false,"assets":[{"name":"x.tar.xz","browser_download_url":"https://example.com/x"}]}]
        """#.utf8)
        let files = try await EnvironmentSetup(engine: engine, session: FakeSourceServer.session()).releaseFiles(repository: "Sikarugir-App/Engines")
        XCTAssertEqual(files.map(\.name), ["WS12WineSikarugir10.0_8.tar.xz", "WS12WineSikarugir11.0_1.tar.xz", "WS11WineCX19.0.2.tar.xz"],
                       "Newest uploads first (ties keep GitHub's order); no http files or drafts")
        XCTAssertEqual(files.first?.sha256, "ab")
        XCTAssertNil(files.last?.sha256)
    }

    func testRefusesIncompleteOrUncheckableBuilds() async throws {
        try addWine(id: "wine-staging", version: "11.21", family: "winehq")   // without the library the engine needs
        let archive = try makeEngineArchive(needs: ["@rpath/libgstreamer-1.0.0.dylib"])
        try serve(archive, named: "WS12WineSikarugir10.0_8.tar.xz")
        let setup = EnvironmentSetup(engine: engine, session: FakeSourceServer.session())
        let source = try ComponentSource.decode(yaml: sourceYAML)
        do {
            try await setup.install(source)
            XCTFail("Installed a build that's missing a library")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("libgstreamer-1.0.0.dylib"), error.localizedDescription)
        }
        XCTAssertTrue(engine.components.installed().filter { $0.manifest.id == "sikarugir" }.isEmpty, "Removed again")

        try serve(archive, named: "WS12WineSikarugir10.0_8.tar.xz", checksum: false)
        do {
            try await setup.install(source)
            XCTFail("Installed a file without a checksum")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription)
        }
    }

    // MARK: Helpers

    func steamRecipe() -> Recipe {
        Recipe(id: "steam", game: GameInfo(title: "Steam", slug: "steam"),
               stack: StackSpec(runner: RunnerRequirement(family: "sikarugir"), graphics: .wined3d),
               launch: LaunchSpec(exe: SteamLibrary.clientPath))
    }

    @discardableResult
    func addWine(id: String, version: String, family: String) throws -> InstalledComponent {
        let manifest = ComponentManifest(id: id, kind: .wine, version: version, displayName: "\(id) \(version)", arch: .x86_64, family: family)
        let directory = engine.components.directory(for: manifest)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try engine.components.writeManifest(manifest, in: directory)
        return InstalledComponent(manifest: manifest, directory: directory)
    }

    /// A .tar.xz shaped like a Sikarugir engine: wswine.bundle with bin/wine and an ntdll.so
    /// loading `needs`.
    func makeEngineArchive(needs: [String]) throws -> Data {
        let folder = root.appendingPathComponent("archive-\(UUID().uuidString)")
        let bundle = folder.appendingPathComponent("wswine.bundle")
        let unix = bundle.appendingPathComponent("lib/wine/x86_64-unix")
        try FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let wine = bundle.appendingPathComponent("bin/wine")
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try Self.machO(loading: needs + ["@rpath/win32u.so"]).write(to: unix.appendingPathComponent("ntdll.so"))
        try Self.machO(loading: []).write(to: unix.appendingPathComponent("win32u.so"))
        let archive = folder.appendingPathComponent("engine.tar.xz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path, "-C", folder.path, "wswine.bundle"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        return try Data(contentsOf: archive)
    }

    func serve(_ archive: Data, named name: String, checksum: Bool = true, olderVersion: Bool = false) throws {
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        var assets = [#"{"name":"\#(name)","browser_download_url":"https://example.com/dl/\#(name)","size":\#(archive.count)\#(checksum ? #","digest":"sha256:\#(digest)""# : "")}"#]
        if olderVersion {
            // Listed first, but older; and a file that doesn't match the pattern.
            assets.insert(#"{"name":"WS12WineSikarugir10.0_7.tar.xz","browser_download_url":"https://example.com/dl/old.tar.xz","size":1,"digest":"sha256:00"}"#, at: 0)
            assets.append(#"{"name":"Template-1.0.27.tar.xz","browser_download_url":"https://example.com/dl/t.tar.xz","size":1}"#)
        }
        FakeSourceServer.responses["/repos/Sikarugir-App/Engines/releases"] =
            Data(#"[{"tag_name":"v1.0","draft":false,"prerelease":false,"assets":[\#(assets.joined(separator: ","))]}]"#.utf8)
        FakeSourceServer.responses["/dl/\(name)"] = archive
    }

    /// A minimal 64-bit Mach-O whose load commands load `libraries`.
    static func machO(loading libraries: [String]) -> Data {
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var commands = Data()
        for library in libraries {
            var name = Data(library.utf8) + Data([0])
            while (24 + name.count) % 8 != 0 { name.append(0) }
            commands += u32(0xC) + u32(UInt32(24 + name.count)) + u32(24) + u32(2) + u32(0x10000) + u32(0x10000) + name
        }
        let header = u32(0xFEED_FACF) + u32(0x0100_0007) + u32(3) + u32(6) + u32(UInt32(libraries.count))
            + u32(UInt32(commands.count)) + u32(0) + u32(0)
        return header + commands
    }
}
