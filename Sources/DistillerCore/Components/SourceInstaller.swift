import Foundation

/// A downloadable file in a GitHub release.
public struct ReleaseFile: Equatable, Sendable, Identifiable {
    public var release: String
    public var name: String
    public var size: Int64?
    /// GitHub's SHA-256 for the file, when it publishes one (files uploaded since mid-2025).
    public var sha256: String?
    public var url: URL
    /// When the file was last uploaded.
    public var uploaded: Date?

    public var id: String { url.absoluteString }
}

/// What installing a source found.
public struct SourceInstallResult: Equatable, Sendable {
    public var component: InstalledComponent
    public var file: ReleaseFile
    /// The installed build whose libraries were added, and how many.
    public var librariesFrom: String?
    public var librariesAdded: Int
    public var containsD3DMetal: Bool
    /// Whether its macOS driver exports the functions D3DMetal and DXMT need (nil: unknown).
    public var exportsMacDriverFunctions: Bool?
}

extension EnvironmentSetup {
    /// The files in a repository's recent releases, most recently uploaded first (some projects
    /// keep every build in one release), skipping drafts and pre-releases and anything not
    /// served over https.
    public func releaseFiles(repository: String) async throws -> [ReleaseFile] {
        guard repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20") else {
            throw DistillerError.setupFailed("\(repository) isn't a GitHub repository name (owner/name).")
        }
        let releases = try await getJSON([GitHubRelease].self, from: url)
        let dates = ISO8601DateFormatter()
        let files = releases.filter { !$0.draft && !$0.prerelease }.flatMap { release in
            release.assets.compactMap { asset -> ReleaseFile? in
                guard let download = URL(string: asset.browserDownloadURL), download.scheme == "https" else { return nil }
                let digest = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
                return ReleaseFile(release: release.tagName, name: asset.name, size: asset.size, sha256: digest, url: download,
                                   uploaded: asset.updatedAt.flatMap(dates.date(from:)))
            }
        }
        // Stable: files uploaded at the same time keep GitHub's order.
        return files.enumerated().sorted { a, b in
            let (dateA, dateB) = (a.element.uploaded ?? .distantPast, b.element.uploaded ?? .distantPast)
            return dateA != dateB ? dateA > dateB : a.offset < b.offset
        }.map(\.element)
    }

    /// The newest file matching the source's pattern (by version).
    public func newestFile(for source: ComponentSource) async throws -> ReleaseFile {
        let files = try await releaseFiles(repository: source.get.githubRelease.repository)
        let matching = files.compactMap { file in source.version(of: file.name).map { (file, VersionNumber($0)) } }
        guard let newest = matching.max(by: { $0.1 < $1.1 })?.0 else {
            throw DistillerError.setupFailed("No file in github.com/\(source.get.githubRelease.repository)'s releases matches \(source.name)'s pattern.")
        }
        return newest
    }

    /// Downloads and installs a Wine build from a source: the file (the newest matching one
    /// unless `file` is given) must have a checksum from GitHub, which it's checked against;
    /// libraries from `librariesFrom`'s installed build are cloned next to the build's own Unix
    /// libraries (where it looks for them); then every library it loads must be there. A build
    /// that's missing libraries is removed again.
    @discardableResult
    public func install(_ source: ComponentSource, file: ReleaseFile? = nil,
                        progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SourceInstallResult {
        let problems = source.problems
        guard problems.isEmpty else { throw DistillerError.invalidRecipe(problems.joined(separator: " ")) }
        guard source.kind == .wine else {
            throw DistillerError.setupFailed("Distiller installs graphics layers from its own sources only, for now.")
        }
        try engine.paths.requireAvailable(.wine)
        progress("Finding \(source.name) on GitHub")
        let chosen: ReleaseFile
        if let file { chosen = file } else { chosen = try await newestFile(for: source) }
        guard let version = source.version(of: chosen.name) else {
            throw DistillerError.setupFailed("\(chosen.name) doesn't match \(source.name)'s pattern.")
        }
        guard let sha256 = chosen.sha256 else {
            throw DistillerError.setupFailed("GitHub doesn't publish a checksum for \(chosen.name), so Distiller can't check the download is the publisher's file. Choose a file uploaded more recently, or ask the publisher to upload it again.")
        }

        // The build that supplies missing libraries, found (or installed) before downloading.
        var donor: InstalledComponent?
        if let from = source.librariesFrom {
            donor = try await installedBuild(tag: from, progress: progress)
        }

        let staging = engine.paths.components.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appendingPathComponent(chosen.name)
        progress("Downloading \(chosen.name)")
        try await Downloader.download(chosen.url, sha256: sha256, to: archive, session: session)
        progress("Installing \(source.name) \(version)")
        var manifest = ComponentManifest(
            id: source.tag, kind: .wine, version: version, displayName: "\(source.name) \(version)",
            arch: source.provides.arch ?? .x86_64, family: source.family, license: source.license,
            source: chosen.url.absoluteString, sha256: sha256
        )
        manifest.librariesFrom = donor?.id
        var component = try await engine.components.installArchive(archive, manifest: manifest)

        do {
            var added = 0
            if let donor {
                progress("Adding libraries from \(donor.manifest.displayName)")
                added = try Self.addLibraries(from: donor.directory, to: component.directory)
            }
            progress("Checking \(source.name) \(version)")
            let missing = MachODependencies.missingRPathLibraries(in: component.directory)
            guard missing.isEmpty else {
                let names = missing.keys.sorted()
                let list = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " and \(names.count - 6) more" : "")
                let hint = source.librariesFrom == nil
                    ? " If another Wine build has them, name it under Libraries from."
                    : " \(donor?.manifest.displayName ?? "The other build") doesn't have them either."
                throw DistillerError.setupFailed("\(source.name) \(version) needs libraries it doesn't include: \(list).\(hint)")
            }
            component = InstalledComponent(manifest: try engine.components.readManifest(in: component.directory), directory: component.directory)
            return SourceInstallResult(
                component: component, file: chosen, librariesFrom: donor?.id, librariesAdded: added,
                containsD3DMetal: MachODependencies.containsD3DMetal(component.directory),
                exportsMacDriverFunctions: WineCapabilities.exportsMacDriverFunctions(component)
            )
        } catch {
            try? FileManager.default.removeItem(at: component.directory)
            throw error
        }
    }

    /// The installed (active) build with `tag`, installing it first if it's one of Distiller's
    /// own Wine sources.
    func installedBuild(tag: String, progress: @escaping @Sendable (String) -> Void) async throws -> InstalledComponent {
        let active = engine.components.activeComponents()
        let installed = engine.components.installed().filter { $0.manifest.kind == .wine && $0.manifest.id == tag && $0.manifest.composedFrom == nil }
        if let build = installed.first(where: { active.contains($0) }) ?? installed.max(by: { VersionNumber($0.manifest.version) < VersionNumber($1.manifest.version) }) {
            return build
        }
        guard let builtIn = WineSource.all.first(where: { $0.id == tag }) else {
            throw DistillerError.componentNotFound("\(tag), which has the libraries this build needs (install it first)")
        }
        progress("Installing \(builtIn.displayName) for its libraries")
        return try await installWine(try await latestRelease(of: builtIn))
    }

    /// Clones the shared libraries in `donor`'s `lib/` and its GStreamer framework's `lib/`
    /// that `target` doesn't have into the folder where `target`'s Unix-side Wine libraries are
    /// (they look for libraries next to themselves). Clones cost no space on the same volume.
    static func addLibraries(from donor: URL, to target: URL) throws -> Int {
        let fileManager = FileManager.default
        let unix = target.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        let destination = fileManager.fileExists(atPath: unix.path) ? unix : target.appendingPathComponent("lib", isDirectory: true)
        let folders = [donor.appendingPathComponent("lib"), donor.appendingPathComponent("lib/GStreamer.framework/Versions/1.0/lib")]
        var present = Set(MachODependencies.fileNames(in: target))
        var added = 0
        for folder in folders {
            let entries = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where entry.lastPathComponent.hasSuffix(".dylib") {
                let name = entry.lastPathComponent
                guard !present.contains(name) else { continue }
                try fileManager.copyItem(at: entry, to: destination.appendingPathComponent(name))
                present.insert(name)
                added += 1
            }
        }
        return added
    }
}

extension MachODependencies {
    static func fileNames(in root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { ($0 as? URL)?.lastPathComponent }
    }
}

extension ReleaseFile {
    /// Release files in the order a player chooses from: files that differ only in their
    /// version (the same `ComponentSource.pattern(forFileName:)`) together, newest version
    /// first; groups by their most recent upload. With `pattern` (the source's), the files it
    /// matches come first. Versions are only compared within a group: different builds number
    /// themselves differently.
    public static func orderedForChoosing(_ files: [ReleaseFile], pattern: String? = nil) -> [ReleaseFile] {
        let regex = pattern.flatMap { try? NSRegularExpression(pattern: $0) }
        func version(_ file: ReleaseFile, _ regex: NSRegularExpression) -> VersionNumber? {
            EnvironmentSetup.version(in: file.name, matching: regex).map(VersionNumber.init)
        }
        var groups: [String: [ReleaseFile]] = [:]
        var order: [String] = []
        for file in files {
            let key = ComponentSource.pattern(forFileName: file.name)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        let newest = { (key: String) in groups[key]!.compactMap(\.uploaded).max() ?? .distantPast }
        let sortedKeys = order.enumerated().sorted { a, b in
            let (dateA, dateB) = (newest(a.element), newest(b.element))
            return dateA != dateB ? dateA > dateB : a.offset < b.offset
        }.map(\.element)
        var ordered: [ReleaseFile] = []
        for key in sortedKeys {
            guard let groupRegex = try? NSRegularExpression(pattern: key) else { ordered += groups[key]!; continue }
            ordered += groups[key]!.sorted { (version($0, groupRegex) ?? VersionNumber("")) > (version($1, groupRegex) ?? VersionNumber("")) }
        }
        guard let regex else { return ordered }
        let matching = ordered.filter { version($0, regex) != nil }
            .sorted { (version($0, regex) ?? VersionNumber("")) > (version($1, regex) ?? VersionNumber("")) }
        return matching + ordered.filter { version($0, regex) == nil }
    }
}
