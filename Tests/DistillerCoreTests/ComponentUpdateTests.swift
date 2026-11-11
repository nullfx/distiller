import Foundation
import XCTest
@testable import DistillerCore

/// Serves GitHub release listings by path, for update checks.
final class FakeReleases: URLProtocol {
    nonisolated(unsafe) static var responses: [String: String] = [:]

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeReleases.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.responses[path]
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func releases(_ assets: [(tag: String, name: String)]) -> String {
        "[" + assets.map { #"{"tag_name":"\#($0.tag)","draft":false,"prerelease":false,"assets":[{"name":"\#($0.name)","browser_download_url":"https://example.com/\#($0.name)","size":1000}]}"# }
            .joined(separator: ",") + "]"
    }
}

final class ComponentUpdateTests: XCTestCase {
    var root: URL!
    var engine: DistillerEngine!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-updates-\(UUID().uuidString)")
        engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
        FakeReleases.responses = [:]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func add(_ id: String, _ version: String, kind: ComponentKind, family: String? = nil, provides: GraphicsBackend? = nil,
             source: String? = "https://example.com/download") throws -> InstalledComponent {
        let manifest = ComponentManifest(
            id: id, kind: kind, version: version, displayName: "\(id) \(version)", arch: .x86_64, family: family,
            provides: provides, placement: provides == nil ? nil : .wineLib, source: source
        )
        let directory = engine.components.directory(for: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try engine.components.writeManifest(manifest, in: directory)
        return InstalledComponent(manifest: manifest, directory: directory)
    }

    func bottle(_ wine: String) -> Bottle {
        Bottle(id: UUID().uuidString, name: "Game", wine: wine, createdAt: Date())
    }

    // MARK: Active versions

    func testTheNewestVersionIsActiveUntilThePlayerChoosesAnother() throws {
        let old = try add("wine-staging", "11.20", kind: .wine, family: "winehq")
        let new = try add("wine-staging", "11.21", kind: .wine, family: "winehq")
        XCTAssertTrue(engine.components.isActive(new))
        XCTAssertFalse(engine.components.isActive(old))
        XCTAssertEqual(engine.components.wineCandidates(for: RunnerRequirement(family: "winehq")).map(\.id), [new.id, old.id])

        try engine.components.makeActive(old)
        XCTAssertTrue(engine.components.isActive(old))
        XCTAssertEqual(engine.components.chosenActiveVersions(), ["wine-staging": "11.20"])
        // New games (and bottles that can) use the active version first.
        XCTAssertEqual(engine.components.wineCandidates(for: RunnerRequirement(family: "winehq")).map(\.id), [old.id, new.id])

        // Choosing the newest again clears the choice, so later updates become active.
        try engine.components.makeActive(new)
        XCTAssertEqual(engine.components.chosenActiveVersions(), [:])
    }

    func testGraphicsLayerAndWinetricksUseTheActiveVersion() throws {
        let old = try add("dxvk-macos", "1.10.2", kind: .graphics, provides: .dxvk)
        try add("dxvk-macos", "1.10.3", kind: .graphics, provides: .dxvk)
        XCTAssertEqual(engine.components.graphicsLayer(.dxvk)?.manifest.version, "1.10.3")
        try engine.components.makeActive(old)
        XCTAssertEqual(engine.components.graphicsLayer(.dxvk)?.manifest.version, "1.10.2")

        try add("winetricks", "20250102", kind: .winetricks)
        try add("winetricks", "20260125", kind: .winetricks)
        XCTAssertEqual(engine.components.winetricks()?.manifest.version, "20260125")
    }

    func testABottleNeverMovesBackToAnOlderActiveWine() throws {
        let old = try add("wine-staging", "11.20", kind: .wine, family: "winehq")
        let new = try add("wine-staging", "11.21", kind: .wine, family: "winehq")
        try engine.components.makeActive(old)
        let original = engine.components.installed().first { $0.id == new.id }
        let upgraded = bottle("wine-staging@11.21")
        XCTAssertFalse(DistillerEngine.wine(old, canOpen: upgraded, madeBy: original))
        XCTAssertTrue(DistillerEngine.wine(new, canOpen: upgraded, madeBy: original))
    }

    // MARK: Removing unused versions

    func testOldVersionsGoOnceNothingNeedsThem() throws {
        let oldWine = try add("wine-staging", "11.20", kind: .wine, family: "winehq")
        try add("wine-staging", "11.21", kind: .wine, family: "winehq")
        let oldLayer = try add("dxvk-macos", "1.10.2", kind: .graphics, provides: .dxvk)
        try add("dxvk-macos", "1.10.3", kind: .graphics, provides: .dxvk)
        // A bottle made with the old Wine can run on the new one.
        let removable = ComponentCleanup.removable(
            installed: engine.components.installed(), chosen: [:], bottles: [bottle("wine-staging@11.20")]
        )
        XCTAssertEqual(Set(removable.map(\.id)), [oldWine.id, oldLayer.id])
    }

    func testAWineABottleStillNeedsStays() throws {
        let old = try add("wine-staging", "11.20", kind: .wine, family: "winehq")
        let new = try add("wine-staging", "11.21", kind: .wine, family: "winehq")
        // The player made 11.20 active again, but one bottle already ran on 11.21, which only
        // 11.21 can open: 11.21 must stay even though it isn't active.
        let removable = ComponentCleanup.removable(
            installed: engine.components.installed(), chosen: ["wine-staging": "11.20"], bottles: [bottle("wine-staging@11.21")]
        )
        XCTAssertFalse(removable.contains { $0.id == new.id })
        XCTAssertFalse(removable.contains { $0.id == old.id }, "the active version always stays")
    }

    func testImportedComponentsAreNeverRemovedAutomatically() throws {
        try add("d3dmetal", "3.0", kind: .graphics, provides: .d3dmetal, source: "Imported from the player's Game Porting Toolkit download")
        try add("d3dmetal", "4.0b3", kind: .graphics, provides: .d3dmetal, source: "Imported from the player's Game Porting Toolkit download")
        XCTAssertEqual(ComponentCleanup.removable(installed: engine.components.installed(), chosen: [:], bottles: []), [])
    }

    func testRemovingTakesComposedBuildsAndTheTemplateAlong() async throws {
        let old = try add("wine-staging", "11.20", kind: .wine, family: "winehq")
        try add("wine-staging", "11.21", kind: .wine, family: "winehq")
        let composed = engine.paths.composedComponents.appendingPathComponent("wine-staging-11.20+dxvk", isDirectory: true)
        try FileManager.default.createDirectory(at: composed, withIntermediateDirectories: true)
        var manifest = old.manifest
        manifest.id = "wine-staging+dxvk-macos"
        manifest.composedFrom = [old.id, "dxvk-macos@1.10.3"]
        try engine.components.writeManifest(manifest, in: composed)
        let template = engine.paths.templates.appendingPathComponent("wine-staging-11.20/prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)

        let removed = await engine.removeUnusedComponents()
        XCTAssertEqual(removed.map(\.id), [old.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: composed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: template.deletingLastPathComponent().path))
    }

    func testAComponentInUseIsNotRemoved() {
        let directory = URL(fileURLWithPath: "/Components/_composed/wine-staging-11.20+dxvk")
        XCTAssertTrue(ComponentCleanup.isInUse(directory, commands: ["/Components/_composed/wine-staging-11.20+dxvk/bin/wineserver"]))
        XCTAssertFalse(ComponentCleanup.isInUse(directory, commands: ["/Components/_composed/wine-staging-11.20+dxvk-2/bin/wineserver"]))
    }

    // MARK: Checking

    func testFindsNewerReleasesOfInstalledComponents() async throws {
        try add("wine-staging", "11.20", kind: .wine, family: "winehq")
        try add("dxvk-macos", "1.10.3-20230507-repack", kind: .graphics, provides: .dxvk)
        try add("winetricks", "20250102", kind: .winetricks)
        FakeReleases.responses = [
            "/repos/Gcenx/macOS_Wine_builds/releases": FakeReleases.releases([("11.21", "wine-staging-11.21-osx64.tar.xz")]),
            "/repos/Gcenx/DXVK-macOS/releases": FakeReleases.releases([("v1.10.3-20230507-repack", "dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz")]),
            "/repos/Winetricks/winetricks/releases/latest": #"{"tag_name":"20260125","draft":false,"prerelease":false,"assets":[]}"#,
        ]
        let setup = EnvironmentSetup(engine: engine, session: FakeReleases.session())
        let check = await setup.checkForUpdates()
        XCTAssertEqual(check.failures, [:])
        XCTAssertEqual(check.updates.map(\.id), ["wine-staging", "winetricks"])
        XCTAssertEqual(check.updates.first?.availableVersion, "11.21")
        XCTAssertEqual(check.updates.first?.installedVersion, "11.20")
        // Components that aren't installed (Wine Devel, DXMT) aren't checked.
        XCTAssertNotNil(StorageSettings.load(fromSupportFolder: engine.paths.root).lastComponentCheck)
        XCTAssertFalse(setup.isUpdateCheckDue())
    }

    func testAHeldComponentIsShownButNotInstalledAutomatically() async throws {
        let old = try add("wine-staging", "11.19", kind: .wine, family: "winehq")
        try add("wine-staging", "11.20", kind: .wine, family: "winehq")
        try engine.components.makeActive(old)
        FakeReleases.responses = [
            "/repos/Gcenx/macOS_Wine_builds/releases": FakeReleases.releases([("11.21", "wine-staging-11.21-osx64.tar.xz")]),
        ]
        let check = await EnvironmentSetup(engine: engine, session: FakeReleases.session()).checkForUpdates()
        XCTAssertEqual(check.updates.first?.heldVersion, "11.19")
        XCTAssertEqual(EnvironmentSetup.automatic(check.updates), [])
    }

    func testASourceThatFailsDoesntStopTheOthers() async throws {
        try add("wine-staging", "11.20", kind: .wine, family: "winehq")
        try add("winetricks", "20250102", kind: .winetricks)
        FakeReleases.responses = [
            "/repos/Winetricks/winetricks/releases/latest": #"{"tag_name":"20260125","draft":false,"prerelease":false,"assets":[]}"#,
        ]
        let check = await EnvironmentSetup(engine: engine, session: FakeReleases.session()).checkForUpdates()
        XCTAssertEqual(check.updates.map(\.id), ["winetricks"])
        XCTAssertNotNil(check.failures["Wine Staging"])
    }

    func testChecksAreDueDailyUnlessTurnedOff() throws {
        let setup = EnvironmentSetup(engine: engine)
        XCTAssertTrue(setup.isUpdateCheckDue())
        var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        settings.lastComponentCheck = Date().addingTimeInterval(-2 * 60 * 60)
        try settings.save(toSupportFolder: engine.paths.root)
        XCTAssertFalse(setup.isUpdateCheckDue())
        XCTAssertTrue(setup.isUpdateCheckDue(now: Date().addingTimeInterval(23 * 60 * 60)))
        settings.componentUpdates = .off
        try settings.save(toSupportFolder: engine.paths.root)
        XCTAssertFalse(setup.isUpdateCheckDue(now: Date().addingTimeInterval(48 * 60 * 60)))
    }

    func testSettingsRoundTrip() throws {
        var settings = StorageSettings()
        XCTAssertEqual(settings.effectiveComponentUpdates, .ask)
        settings.componentUpdates = .auto
        settings.activeComponents = ["wine-staging": "11.20"]
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""component_updates":"auto""#), text)
        XCTAssertTrue(text.contains(#""active_components""#), text)
        XCTAssertEqual(try JSONDecoder().decode(StorageSettings.self, from: data), settings)
    }
}
