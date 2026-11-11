import Foundation

/// Installed components live in `Components/<kind>/<id>-<version>/`, each with a `component.json`.
public final class ComponentStore: @unchecked Sendable {
    public let paths: DistillerPaths
    public static let manifestName = "component.json"

    public init(paths: DistillerPaths) {
        self.paths = paths
    }

    public func installed() -> [InstalledComponent] {
        var result: [InstalledComponent] = []
        for kind in ComponentKind.allCases {
            let kindDirectory = paths.components.appendingPathComponent(kind.rawValue, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: kindDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for directory in entries {
                if let manifest = try? readManifest(in: directory) {
                    result.append(InstalledComponent(manifest: manifest, directory: directory))
                }
            }
        }
        return result.sorted {
            if $0.manifest.kind != $1.manifest.kind { return $0.manifest.kind.rawValue < $1.manifest.kind.rawValue }
            if $0.manifest.id != $1.manifest.id { return $0.manifest.id < $1.manifest.id }
            return VersionNumber($0.manifest.version) > VersionNumber($1.manifest.version)
        }
    }

    public func component(withID id: String) -> InstalledComponent? {
        installed().first { $0.id == id }
            ?? installed().first { $0.manifest.id == id }
            ?? composed().first { $0.id == id }
    }

    /// Wine builds that satisfy a recipe's runner requirement, newest first.
    public func wineCandidates(for requirement: RunnerRequirement) -> [InstalledComponent] {
        let matching: [InstalledComponent] = installed().filter { Self.wine($0, meets: requirement) }
        let newestFirst: [InstalledComponent] = matching.sorted {
            VersionNumber($0.manifest.version) > VersionNumber($1.manifest.version)
        }
        return newestFirst.activeFirst(activeIDs())
    }

    static func wine(_ component: InstalledComponent, meets requirement: RunnerRequirement) -> Bool {
        let manifest = component.manifest
        guard manifest.kind == .wine else { return false }
        if requirement.family != "any", manifest.family != requirement.family { return false }
        if let minimum = requirement.minVersion, VersionNumber(manifest.version) < VersionNumber(minimum) { return false }
        if let arch = requirement.arch, manifest.arch != arch, manifest.arch != .universal { return false }
        return true
    }

    /// The active version of the layer that provides `backend`.
    public func graphicsLayer(_ backend: GraphicsBackend) -> InstalledComponent? {
        installed()
            .filter { $0.manifest.kind == .graphics && $0.manifest.provides == backend }
            .sorted { VersionNumber($0.manifest.version) > VersionNumber($1.manifest.version) }
            .activeFirst(activeIDs())
            .first
    }

    /// The active winetricks.
    public func winetricks() -> InstalledComponent? {
        installed()
            .filter { $0.manifest.kind == .winetricks }
            .sorted { VersionNumber($0.manifest.version) > VersionNumber($1.manifest.version) }
            .activeFirst(activeIDs())
            .first
    }

    // MARK: Active versions

    /// The versions the player chose as active (`settings.json` `active_components`).
    public func chosenActiveVersions() -> [String: String] {
        StorageSettings.load(fromSupportFolder: paths.root).activeComponents ?? [:]
    }

    /// One version per component id: the one the player chose, or the newest installed. New
    /// games use it, and games that follow updates move to it.
    public func activeComponents() -> [InstalledComponent] {
        Self.active(in: installed(), chosen: chosenActiveVersions())
    }

    public func isActive(_ component: InstalledComponent) -> Bool {
        activeIDs().contains(component.id)
    }

    func activeIDs() -> Set<String> {
        Set(activeComponents().map(\.id))
    }

    static func active(in installed: [InstalledComponent], chosen: [String: String]) -> [InstalledComponent] {
        Dictionary(grouping: installed, by: { $0.manifest.id }).compactMap { id, versions in
            let newestFirst = versions.sorted { VersionNumber($0.manifest.version) > VersionNumber($1.manifest.version) }
            if let version = chosen[id], let match = newestFirst.first(where: { $0.manifest.version == version }) { return match }
            return newestFirst.first
        }
    }

    /// Makes `component` the active version of its id. The newest version needs no choice, so
    /// later updates become active by themselves.
    public func makeActive(_ component: InstalledComponent) throws {
        var settings = StorageSettings.load(fromSupportFolder: paths.root)
        var chosen = settings.activeComponents ?? [:]
        let newest = installed().filter { $0.manifest.id == component.manifest.id }
            .max { VersionNumber($0.manifest.version) < VersionNumber($1.manifest.version) }
        chosen[component.manifest.id] = newest?.id == component.id ? nil : component.manifest.version
        settings.activeComponents = chosen.isEmpty ? nil : chosen
        try settings.save(toSupportFolder: paths.root)
    }

    func composed() -> [InstalledComponent] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: paths.composedComponents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.compactMap { directory in
            (try? readManifest(in: directory)).map { InstalledComponent(manifest: $0, directory: directory) }
        }
    }

    public func directory(for manifest: ComponentManifest) -> URL {
        paths.components
            .appendingPathComponent(manifest.kind.rawValue, isDirectory: true)
            .appendingPathComponent("\(manifest.id)-\(manifest.version)", isDirectory: true)
    }

    /// Copies (clones) a folder in as a component. For Wine builds, the folder may be an
    /// app bundle such as "Wine Staging.app"; the Wine tree inside it is imported.
    @discardableResult
    public func importDirectory(_ source: URL, manifest: ComponentManifest) throws -> InstalledComponent {
        try paths.requireAvailable(.wine)
        let source = manifest.kind == .wine ? try WineBuildLocator.locateRoot(in: source) : source
        let destination = directory(for: manifest)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try APFSClone.cloneItem(at: source, to: destination)
        try writeManifest(manifest, in: destination)
        return InstalledComponent(manifest: manifest, directory: destination)
    }

    /// The newest installed Wine build of any family.
    public func newestWine() -> InstalledComponent? {
        installed()
            .filter { $0.manifest.kind == .wine }
            .max { VersionNumber($0.manifest.version) < VersionNumber($1.manifest.version) }
    }

    /// The graphics backends that can be used: WineD3D is built into Wine, the others need a layer.
    /// Layers that are installed *and* can run on at least one installed Wine build. D3DMetal
    /// and DXMT need a Wine build that exports `macdrv_*` (`WineCapabilities`).
    public func availableGraphics() -> Set<GraphicsBackend> {
        let problems = graphicsProblems()
        var result: Set<GraphicsBackend> = [.wined3d]
        for component in installed() where component.manifest.kind == .graphics {
            if let provides = component.manifest.provides, problems[provides] == nil { result.insert(provides) }
        }
        return result
    }

    /// Installed layers that no installed Wine build can run, with the reason.
    public func graphicsProblems() -> [GraphicsBackend: String] {
        let wines = installed().filter { $0.manifest.kind == .wine }
        guard !wines.isEmpty else { return [:] }
        var problems: [GraphicsBackend: String] = [:]
        for component in installed() where component.manifest.kind == .graphics {
            guard let backend = component.manifest.provides else { continue }
            if !wines.contains(where: { WineCapabilities.canRun(backend, on: $0) }) {
                problems[backend] = WineCapabilities.whyNot(backend)
            }
        }
        return problems
    }

    /// Unpacks a .tar.xz, .tar.gz or .zip archive as a component, verifying `manifest.sha256` if set.
    @discardableResult
    public func installArchive(_ archive: URL, manifest: ComponentManifest) async throws -> InstalledComponent {
        if let expected = manifest.sha256 {
            try Checksum.verify(archive, expected: expected)
        }
        let staging = paths.components.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xf", archive.path, "-C", staging.path]
        )
        guard result.status == 0 else {
            throw DistillerError.processFailed(command: "tar -xf \(archive.lastPathComponent)", status: result.status, logFile: nil)
        }

        // Most archives wrap everything in one top-level folder (for example "Wine Stable.app"
        // or "wine-11.0"). Import that folder rather than the wrapper.
        let entries = try FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        let isSingleFolder = entries.count == 1
            && (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return try importDirectory(isSingleFolder ? entries[0] : staging, manifest: manifest)
    }

    public func remove(_ component: InstalledComponent) throws {
        try FileManager.default.trashItem(at: component.directory, resultingItemURL: nil)
    }

    func readManifest(in directory: URL) throws -> ComponentManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent(Self.manifestName))
        return try JSONDecoder().decode(ComponentManifest.self, from: data)
    }

    func writeManifest(_ manifest: ComponentManifest, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(Self.manifestName), options: .atomic)
    }
}

/// Finds the folder of a Wine build that holds `bin/wine` (or `bin/wine64`) and `lib/`.
/// Builds are often wrapped in an app bundle, such as
/// `Wine Staging.app/Contents/Resources/wine/`.
public enum WineBuildLocator {
    public static func locateRoot(in folder: URL) throws -> URL {
        var queue: [(URL, Int)] = [(folder, 0)]
        let fileManager = FileManager.default
        while !queue.isEmpty {
            let (candidate, depth) = queue.removeFirst()
            if isWineRoot(candidate) { return candidate }
            guard depth < 5 else { continue }
            let children = (try? fileManager.contentsOfDirectory(
                at: candidate, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
            )) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true {
                    queue.append((child, depth + 1))
                }
            }
        }
        throw DistillerError.wineBuildNotRecognized(folder.path)
    }

    static func isWineRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let hasLoader = ["bin/wine", "bin/wine64"].contains {
            fileManager.isExecutableFile(atPath: url.appendingPathComponent($0).path)
        }
        return hasLoader && fileManager.fileExists(atPath: url.appendingPathComponent("lib").path)
    }
}

extension Array where Element == InstalledComponent {
    /// The same order, with active versions moved to the front.
    func activeFirst(_ active: Set<String>) -> [InstalledComponent] {
        filter { active.contains($0.id) } + filter { !active.contains($0.id) }
    }
}
