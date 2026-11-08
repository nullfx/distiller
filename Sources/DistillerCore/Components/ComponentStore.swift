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
        installed()
            .filter { $0.manifest.kind == .wine }
            .filter { requirement.family == "any" || $0.manifest.family == requirement.family }
            .filter { component in
                guard let minimum = requirement.minVersion else { return true }
                return VersionNumber(component.manifest.version) >= VersionNumber(minimum)
            }
            .filter { component in
                guard let arch = requirement.arch else { return true }
                return component.manifest.arch == arch || component.manifest.arch == .universal
            }
            .sorted { VersionNumber($0.manifest.version) > VersionNumber($1.manifest.version) }
    }

    public func graphicsLayer(_ backend: GraphicsBackend) -> InstalledComponent? {
        installed()
            .filter { $0.manifest.kind == .graphics && $0.manifest.provides == backend }
            .max { VersionNumber($0.manifest.version) < VersionNumber($1.manifest.version) }
    }

    public func winetricks() -> InstalledComponent? {
        installed()
            .filter { $0.manifest.kind == .winetricks }
            .max { VersionNumber($0.manifest.version) < VersionNumber($1.manifest.version) }
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
