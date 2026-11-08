import Foundation

/// Something Distiller needs, or can use, before games will run.
public enum SetupItem: String, CaseIterable, Identifiable, Codable, Sendable {
    case rosetta, wine, winetricks, cabextract, d3dmetal, dxmt, dxvk

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rosetta: return "Rosetta"
        case .wine: return "Wine"
        case .winetricks: return "Winetricks"
        case .cabextract: return "cabextract"
        case .d3dmetal: return "D3DMetal (Game Porting Toolkit)"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK for macOS"
        }
    }

    /// The graphics layer this item installs, if it is one.
    public var graphicsBackend: GraphicsBackend? {
        switch self {
        case .d3dmetal: return .d3dmetal
        case .dxmt: return .dxmt
        case .dxvk: return .dxvk
        default: return nil
        }
    }

    public init?(graphics backend: GraphicsBackend) {
        guard let item = SetupItem.allCases.first(where: { $0.graphicsBackend == backend }) else { return nil }
        self = item
    }

    public var purpose: String {
        switch self {
        case .rosetta: return "Runs the Intel-based Wine builds on Apple silicon."
        case .wine: return "Runs Windows programs on macOS."
        case .winetricks: return "Installs Windows runtime libraries that games need, such as Visual C++."
        case .cabextract: return "Unpacks Microsoft installers for winetricks."
        case .d3dmetal: return "Apple's fast translation of Direct3D 11 and 12 to Metal. Optional, but most newer games need it."
        case .dxmt: return "An open-source translation of Direct3D 10 and 11 to Metal. Another choice when D3DMetal doesn't work for a game."
        case .dxvk: return "Translates Direct3D 10 and 11 to Vulkan, which MoltenVK runs on Metal. Works with many older games."
        }
    }

    /// Optional items don't block "ready", but the assistant still offers them.
    public var isRequired: Bool {
        switch self {
        case .rosetta, .wine: return true
        case .winetricks, .cabextract, .d3dmetal, .dxmt, .dxvk: return false
        }
    }

    /// Items the assistant can install by itself. D3DMetal can't be: Apple's license
    /// requires the player to download it.
    public var canInstallAutomatically: Bool { self != .d3dmetal }
}

public struct SetupStatus: Identifiable, Equatable, Sendable {
    public var item: SetupItem
    public var isInstalled: Bool
    /// What's installed, such as "Wine 11.17 (winehq)", or why it's missing.
    public var detail: String
    public var id: SetupItem { item }
}

public struct EnvironmentReport: Equatable, Sendable {
    public var items: [SetupStatus]

    public var isReady: Bool { items.allSatisfy { $0.isInstalled || !$0.item.isRequired } }
    public var isComplete: Bool { items.allSatisfy(\.isInstalled) }
    public var missing: [SetupItem] { items.filter { !$0.isInstalled }.map(\.item) }

    public func status(_ item: SetupItem) -> SetupStatus? { items.first { $0.item == item } }
}

/// Where the assistant downloads Wine from. Builds come from GitHub releases; the release's
/// own SHA-256 digest is checked when GitHub provides one.
public struct WineSource: Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    /// "owner/name" of the GitHub repository with the releases.
    public var repository: String
    /// Matches the asset to download. The first capture group is the version.
    public var assetPattern: String
    public var family: String
    public var arch: CPUArch
    public var summary: String

    public static let gcenxStaging = WineSource(
        id: "wine-staging",
        displayName: "Wine Staging",
        repository: "Gcenx/macOS_Wine_builds",
        assetPattern: #"^wine-staging-([0-9][0-9.]*)-osx64\.tar\.xz$"#,
        family: "winehq",
        arch: .x86_64,
        summary: "Recent Wine with extra game fixes, built for macOS by Gcenx. Recommended."
    )

    public static let gcenxDevel = WineSource(
        id: "wine-devel",
        displayName: "Wine Devel",
        repository: "Gcenx/macOS_Wine_builds",
        assetPattern: #"^wine-devel-([0-9][0-9.]*)-osx64\.tar\.xz$"#,
        family: "winehq",
        arch: .x86_64,
        summary: "The latest WineHQ development release, built for macOS by Gcenx."
    )

    public static let all = [gcenxStaging, gcenxDevel]
    public static let recommended = gcenxStaging
}

/// Where the assistant downloads a graphics layer from. Both are "builtin" builds laid out
/// like Wine's own `lib/wine` (`i386-windows`, `x86_64-windows`, `x86_64-unix`), so they're
/// merged into a copy of the Wine build by `StackComposer`, like D3DMetal.
public struct GraphicsLayerSource: Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var repository: String
    /// Matches the asset to download. The first capture group is the version.
    public var assetPattern: String
    public var provides: GraphicsBackend
    public var license: String
    /// DLLs to also copy into each bottle (see `ComponentManifest.alsoInPrefix`).
    public var alsoInPrefix: [String] = []

    /// The licence of a given release. DXMT moved from MIT to LGPL after v0.80.
    public func license(forVersion version: String) -> String {
        if id == "dxmt", VersionNumber(version) <= VersionNumber("0.80") { return "MIT" }
        return license
    }

    /// DXMT, by 3Shain for CodeWeavers. MIT up to v0.80, LGPL-2.1-or-later after. Verified
    /// layout (v0.80): d3d11, dxgi, d3d10core, winemetal, nvapi64 and nvngx DLLs plus
    /// `x86_64-unix/winemetal.so`. `winemetal.dll` must also be in the bottle's system32
    /// (DXMT installation guide). Needs a Wine whose `winemac.so` exports DXMT's `macdrv_*`
    /// functions (CrossOver-source builds do; Gcenx's WineHQ builds don't).
    public static let dxmt = GraphicsLayerSource(
        id: "dxmt",
        displayName: "DXMT",
        repository: "3Shain/dxmt",
        assetPattern: #"^dxmt-v([0-9][0-9.]*)-builtin\.tar\.gz$"#,
        provides: .dxmt,
        license: "LGPL-2.1-or-later",
        alsoInPrefix: ["winemetal.dll"]
    )

    /// DXVK 1.10 with macOS patches and async shader compilation, by Gcenx. Zlib. Verified
    /// layout (1.10.3-20230507-repack): d3d11 and d3d10core for 32- and 64-bit; it uses Wine's
    /// own dxgi and the MoltenVK that ships with the Wine build.
    public static let dxvk = GraphicsLayerSource(
        id: "dxvk-macos",
        displayName: "DXVK for macOS",
        repository: "Gcenx/DXVK-macOS",
        assetPattern: #"^dxvk-macOS-async-v([0-9][0-9.]*-[0-9]+(?:-repack)?)-builtin\.tar\.gz$"#,
        provides: .dxvk,
        license: "Zlib"
    )

    public static let all = [dxmt, dxvk]

    public static func source(for backend: GraphicsBackend) -> GraphicsLayerSource? {
        all.first { $0.provides == backend }
    }
}

/// A graphics layer release found on GitHub.
public struct GraphicsLayerRelease: Hashable, Sendable {
    public var source: GraphicsLayerSource
    public var version: String
    public var assetName: String
    public var downloadURL: URL
    public var sha256: String?
    public var size: Int64?
}

/// A downloadable release found on GitHub.
public struct WineRelease: Hashable, Sendable {
    public var source: WineSource
    public var version: String
    public var assetName: String
    public var downloadURL: URL
    /// From GitHub's `digest` field ("sha256:…"), when present.
    public var sha256: String?
    public var size: Int64?
}

/// Checks what's installed and installs what's missing. Runs host commands only from this
/// fixed list (softwareupdate, brew, tar), never anything taken from a recipe.
public final class EnvironmentSetup: @unchecked Sendable {
    let engine: DistillerEngine
    let session: URLSession

    public static let gptkDownloadPage = URL(string: "https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit")!
    public static let homebrewPage = URL(string: "https://brew.sh")!

    public init(engine: DistillerEngine, session: URLSession = .shared) {
        self.engine = engine
        self.session = session
    }

    // MARK: Checking

    public func check() -> EnvironmentReport {
        let hardware = engine.hardware
        let components = engine.components
        var items: [SetupStatus] = []

        #if arch(arm64)
        items.append(SetupStatus(
            item: .rosetta, isInstalled: hardware.rosetta,
            detail: hardware.rosetta ? "Installed" : "Not installed"
        ))
        #else
        items.append(SetupStatus(item: .rosetta, isInstalled: true, detail: "Not needed on an Intel Mac"))
        #endif

        if let wine = components.newestWine() {
            items.append(SetupStatus(item: .wine, isInstalled: true, detail: "\(wine.manifest.displayName) (\(wine.manifest.family ?? "unknown family"))"))
        } else {
            items.append(SetupStatus(item: .wine, isInstalled: false, detail: "No Wine build installed"))
        }

        if let winetricks = components.winetricks() {
            items.append(SetupStatus(item: .winetricks, isInstalled: true, detail: "Version \(winetricks.manifest.version)"))
        } else {
            items.append(SetupStatus(item: .winetricks, isInstalled: false, detail: "Not installed"))
        }

        if let cabextract = Self.findTool("cabextract") {
            items.append(SetupStatus(item: .cabextract, isInstalled: true, detail: cabextract.path))
        } else {
            let detail = Self.findTool("brew") == nil
                ? "Not installed. Installing it needs Homebrew (brew.sh)."
                : "Not installed"
            items.append(SetupStatus(item: .cabextract, isInstalled: false, detail: detail))
        }

        let problems = components.graphicsProblems()
        func layerDetail(_ layer: InstalledComponent, _ backend: GraphicsBackend) -> String {
            problems[backend] == nil ? layer.manifest.displayName : "\(layer.manifest.displayName). Needs a CrossOver-based Wine build to run."
        }
        if let d3dmetal = components.graphicsLayer(.d3dmetal) {
            items.append(SetupStatus(item: .d3dmetal, isInstalled: true, detail: layerDetail(d3dmetal, .d3dmetal)))
        } else {
            items.append(SetupStatus(item: .d3dmetal, isInstalled: false, detail: "Not imported"))
        }

        for (item, backend) in [(SetupItem.dxmt, GraphicsBackend.dxmt), (.dxvk, .dxvk)] {
            if let layer = components.graphicsLayer(backend) {
                items.append(SetupStatus(item: item, isInstalled: true, detail: layerDetail(layer, backend)))
            } else {
                items.append(SetupStatus(item: item, isInstalled: false, detail: "Not installed"))
            }
        }
        return EnvironmentReport(items: items)
    }

    /// Looks in the folders Wine and winetricks are given on their PATH.
    public static func findTool(_ name: String) -> URL? {
        for folder in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: Rosetta

    /// Installs Rosetta. macOS asks for an administrator password.
    public func installRosetta() async throws {
        let script = #"do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges"#
        let log = engine.runner.logURL(named: "setup-rosetta")
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script], logFile: log)
        engine.refreshHardware()
        guard result.status == 0, engine.hardware.rosetta else {
            throw DistillerError.setupFailed(
                "Rosetta wasn't installed. You can install it in Terminal with: softwareupdate --install-rosetta (log: \(log.path))"
            )
        }
    }

    // MARK: Wine

    public func latestRelease(of source: WineSource) async throws -> WineRelease {
        let asset = try await latestAsset(repository: source.repository, pattern: source.assetPattern, name: source.displayName)
        return WineRelease(
            source: source, version: asset.version, assetName: asset.name,
            downloadURL: asset.url, sha256: asset.sha256, size: asset.size
        )
    }

    /// The newest non-prerelease asset in `repository` whose name matches `pattern`.
    func latestAsset(repository: String, pattern: String, name: String) async throws
        -> (version: String, name: String, url: URL, sha256: String?, size: Int64?)
    {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=15")!
        let releases = try await getJSON([GitHubRelease].self, from: url)
        let regex = try NSRegularExpression(pattern: pattern)
        for release in releases where !release.draft && !release.prerelease {
            for asset in release.assets {
                guard let version = Self.version(in: asset.name, matching: regex),
                      let download = URL(string: asset.browserDownloadURL),
                      download.scheme == "https" else { continue }
                let digest = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
                return (version, asset.name, download, digest, asset.size)
            }
        }
        throw DistillerError.setupFailed("No \(name) download was found on github.com/\(repository).")
    }

    static func version(in assetName: String, matching regex: NSRegularExpression) -> String? {
        let range = NSRange(assetName.startIndex..., in: assetName)
        guard let match = regex.firstMatch(in: assetName, range: range), match.numberOfRanges > 1,
              let versionRange = Range(match.range(at: 1), in: assetName) else { return nil }
        return String(assetName[versionRange])
    }

    // MARK: Graphics layers (DXMT, DXVK)

    public func latestRelease(of source: GraphicsLayerSource) async throws -> GraphicsLayerRelease {
        let asset = try await latestAsset(repository: source.repository, pattern: source.assetPattern, name: source.displayName)
        return GraphicsLayerRelease(
            source: source, version: asset.version, assetName: asset.name,
            downloadURL: asset.url, sha256: asset.sha256, size: asset.size
        )
    }

    /// Downloads a graphics layer, checks its digest, and installs it so `StackComposer` can
    /// merge it into a copy of the Wine build.
    @discardableResult
    public func installGraphicsLayer(_ release: GraphicsLayerRelease) async throws -> InstalledComponent {
        try engine.paths.requireAvailable(.wine)
        let staging = engine.paths.components.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appendingPathComponent(release.assetName)
        let sha: String
        if let expected = release.sha256 {
            try await Downloader.download(release.downloadURL, sha256: expected, to: archive, session: session)
            sha = expected
        } else {
            sha = try await Downloader.download(release.downloadURL, to: archive, session: session)
        }
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xf", archive.path, "-C", extracted.path])
        guard result.status == 0 else {
            throw DistillerError.processFailed(command: "tar -xf \(release.assetName)", status: result.status, logFile: nil)
        }
        let component = staging.appendingPathComponent("component", isDirectory: true)
        try Self.arrangeWineLib(from: extracted, into: component)
        let manifest = ComponentManifest(
            id: release.source.id,
            kind: .graphics,
            version: release.version,
            displayName: "\(release.source.displayName) \(release.version)",
            arch: .x86_64,
            provides: release.source.provides,
            placement: .wineLib,
            license: release.source.license(forVersion: release.version),
            source: release.downloadURL.absoluteString,
            sha256: sha
        )
        var withPrefixDLLs = manifest
        withPrefixDLLs.alsoInPrefix = release.source.alsoInPrefix.isEmpty ? nil : release.source.alsoInPrefix
        return try engine.components.importDirectory(component, manifest: withPrefixDLLs)
    }

    /// Installs the latest release of the layer that provides `backend`.
    @discardableResult
    public func installGraphicsLayer(_ backend: GraphicsBackend) async throws -> InstalledComponent {
        guard let source = GraphicsLayerSource.source(for: backend) else {
            throw DistillerError.setupFailed("\(backend.displayName) can't be downloaded by Distiller.")
        }
        return try await installGraphicsLayer(try await latestRelease(of: source))
    }

    /// Finds the folder holding `x86_64-windows` (and its siblings) in an extracted archive
    /// and moves those architecture folders to `<component>/lib/wine/`.
    static func arrangeWineLib(from extracted: URL, into component: URL) throws {
        let fileManager = FileManager.default
        let architectures = ["i386-windows", "x86_64-windows", "x86_64-unix", "aarch64-windows", "aarch64-unix"]
        var root: URL?
        if let enumerator = fileManager.enumerator(at: extracted, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if enumerator.level > 4 { enumerator.skipDescendants(); continue }
                if url.lastPathComponent == "x86_64-windows" {
                    root = url.deletingLastPathComponent()
                    break
                }
            }
        }
        guard let root else {
            throw DistillerError.setupFailed("The download doesn't contain an x86_64-windows folder, so it isn't a Wine builtin build.")
        }
        let destination = component.appendingPathComponent("lib/wine", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in architectures {
            let source = root.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    @discardableResult
    public func installWine(_ release: WineRelease) async throws -> InstalledComponent {
        try engine.paths.requireAvailable(.wine)
        let staging = engine.paths.components.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appendingPathComponent(release.assetName)
        let sha: String
        if let expected = release.sha256 {
            try await Downloader.download(release.downloadURL, sha256: expected, to: archive, session: session)
            sha = expected
        } else {
            sha = try await Downloader.download(release.downloadURL, to: archive, session: session)
        }
        let manifest = ComponentManifest(
            id: release.source.id,
            kind: .wine,
            version: release.version,
            displayName: "\(release.source.displayName) \(release.version)",
            arch: release.source.arch,
            family: release.source.family,
            license: "LGPL-2.1-or-later",
            source: release.downloadURL.absoluteString,
            sha256: sha
        )
        return try await engine.components.installArchive(archive, manifest: manifest)
    }

    // MARK: Winetricks

    @discardableResult
    public func installWinetricks() async throws -> InstalledComponent {
        try engine.paths.requireAvailable(.wine)
        let latest = URL(string: "https://api.github.com/repos/Winetricks/winetricks/releases/latest")!
        let release = try await getJSON(GitHubRelease.self, from: latest)
        let tag = release.tagName
        guard tag.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              let script = URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/\(tag)/src/winetricks") else {
            throw DistillerError.setupFailed("The latest winetricks release has an unexpected name, \(tag).")
        }
        let staging = engine.paths.components.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = staging.appendingPathComponent("winetricks")
        let sha = try await Downloader.download(script, to: file, session: session)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let manifest = ComponentManifest(
            id: "winetricks", kind: .winetricks, version: tag, displayName: "winetricks \(tag)", arch: .universal,
            executable: "winetricks", license: "LGPL-2.1-or-later", source: script.absoluteString, sha256: sha
        )
        return try engine.components.importDirectory(staging, manifest: manifest)
    }

    // MARK: cabextract

    /// Installs cabextract with Homebrew. Fails with guidance when Homebrew isn't installed.
    public func installCabextract() async throws {
        guard let brew = Self.findTool("brew") else {
            throw DistillerError.setupFailed("cabextract is installed with Homebrew, which isn't on this Mac. Install Homebrew from brew.sh, then try again.")
        }
        let log = engine.runner.logURL(named: "setup-cabextract")
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["NONINTERACTIVE"] = "1"
        let result = try await ProcessRunner.run(brew, arguments: ["install", "cabextract"], environment: environment, logFile: log)
        guard result.status == 0, Self.findTool("cabextract") != nil else {
            throw DistillerError.processFailed(command: "brew install cabextract", status: result.status, logFile: log.path)
        }
    }

    // MARK: D3DMetal

    /// Imports D3DMetal from the player's Game Porting Toolkit disk image, volume or folder.
    @discardableResult
    public func importGPTK(from location: URL) async throws -> InstalledComponent {
        try await GPTKImporter.importGPTK(from: location, into: engine.components)
    }

    // MARK: Helpers

    func getJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Distiller", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DistillerError.setupFailed("GitHub answered \(http.statusCode) for \(url.absoluteString). Try again in a few minutes.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// The parts of a GitHub release the assistant reads.
struct GitHubRelease: Decodable {
    var tagName: String
    var draft: Bool
    var prerelease: Bool
    var assets: [Asset]

    struct Asset: Decodable {
        var name: String
        var browserDownloadURL: String
        var size: Int64?
        var digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
    }
}
